#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Bootstrap a Raspberry Pi (Raspberry Pi OS Lite, Bookworm) as a Wi-Fi/AirPrint print server
# for a USB printer supported by Gutenprint.
#
#   sudo bash /boot/firmware/bootstrap/setup.sh
#
# Layout on the FAT boot partition (/boot/firmware on the Pi):
#   bootstrap/setup.sh
#   bootstrap/secrets.env     (copy of secrets.env.example, filled in)
#
# Safe to re-run. Log: /var/log/bootstrap.log (never contains secrets).
#
# Security model: everything is reachable from the home LAN only (ufw).
#   - Printing and viewing jobs in the CUPS web UI need no password.
#   - Admin actions (cancel others' jobs, resume a stopped printer, change settings) ask for the
#     login/password of the Pi's main user (member of lpadmin), over HTTPS (self-signed cert).

set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "Run as root: sudo bash $0" >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec > >(tee -a /var/log/bootstrap.log) 2>&1
echo "=== bootstrap started $(date -Is) ==="

log()  { printf '\n== %s ==\n' "$*"; }
warn() { echo "WARNING: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------- settings
[ -f "$DIR/secrets.env" ] || die "missing $DIR/secrets.env (copy secrets.env.example and fill it in)"
# tr strips CRLF in case the file was edited on Windows
# shellcheck disable=SC1090
source <(tr -d '\r' < "$DIR/secrets.env")

: "${WIFI_COUNTRY:?WIFI_COUNTRY is required}"
: "${WIFI_SSID:?WIFI_SSID is required}"
: "${WIFI_PSK:?WIFI_PSK is required}"
WIFI_BSSID="${WIFI_BSSID:-}"

# ---------------------------------------------------------------- Wi-Fi
log "Wi-Fi"
raspi-config nonint do_wifi_country "$WIFI_COUNTRY" || warn "could not set the Wi-Fi country"
rfkill unblock wifi || true
systemctl enable --now NetworkManager
nmcli radio wifi on

IFACE="$(nmcli -t -f DEVICE,TYPE device | awk -F: '$2=="wifi" && !f {print $1; f=1}')"
[ -n "$IFACE" ] || die "no Wi-Fi interface found (dongle plugged in? check lsusb and dmesg)"
echo "Wi-Fi interface: $IFACE"

# Remove every saved Wi-Fi profile (e.g. the one Imager created) so only ours remains
while IFS=: read -r uuid ctype; do
  if [ "$ctype" = "802-11-wireless" ]; then nmcli connection delete uuid "$uuid" >/dev/null || true; fi
done < <(nmcli -t -f UUID,TYPE connection show)

# Write the profile as a root-only file: the password never shows up in the process list
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g'; }
umask 077
{
  echo "[connection]"
  echo "id=home"
  echo "uuid=$(cat /proc/sys/kernel/random/uuid)"
  echo "type=wifi"
  echo "interface-name=$IFACE"
  echo "autoconnect=true"
  echo
  echo "[wifi]"
  echo "mode=infrastructure"
  echo "ssid=$(esc "$WIFI_SSID")"
  [ -z "$WIFI_BSSID" ] || echo "bssid=$WIFI_BSSID"
  echo "powersave=2"
  echo
  echo "[wifi-security]"
  echo "key-mgmt=wpa-psk"
  echo "psk=$(esc "$WIFI_PSK")"
  echo
  echo "[ipv4]"
  echo "method=auto"
  echo
  echo "[ipv6]"
  echo "method=auto"
} > /etc/NetworkManager/system-connections/home.nmconnection
umask 022
chmod 600 /etc/NetworkManager/system-connections/home.nmconnection
nmcli connection reload
nmcli connection up home ifname "$IFACE" || true

connected=no
for _ in $(seq 1 45); do
  if nmcli -g GENERAL.STATE device show "$IFACE" | grep -q '^100'; then connected=yes; break; fi
  sleep 2
done
[ "$connected" = yes ] || die "Wi-Fi did not connect: check SSID, BSSID, password and signal"
echo "Connected: $(nmcli -g GENERAL.CONNECTION device show "$IFACE")"

# ---------------------------------------------------------------- clock
log "Clock (the Pi 1 has no RTC)"
APT_OPTS=()
synced=no
for _ in $(seq 1 60); do
  if [ "$(timedatectl show -p NTPSynchronized --value)" = yes ]; then synced=yes; break; fi
  sleep 2
done
if [ "$synced" != yes ]; then
  warn "clock not synchronised, apt will skip its date check"
  APT_OPTS=(-o Acquire::Check-Date=false)
fi

# ---------------------------------------------------------------- packages + automatic security updates
log "Packages"
export DEBIAN_FRONTEND=noninteractive

# Never install cups-browsed (UDP 631 listener, not needed for a print server)
cat > /etc/apt/preferences.d/no-cups-browsed <<'EOF'
Package: cups-browsed
Pin: release *
Pin-Priority: -1
EOF

apt-get "${APT_OPTS[@]}" update
apt-get "${APT_OPTS[@]}" install -y \
  cups avahi-daemon ghostscript printer-driver-gutenprint unattended-upgrades ufw
if dpkg -s cups-browsed >/dev/null 2>&1; then
  apt-get purge -y cups-browsed
fi

# Security updates come from the default 50unattended-upgrades; reboot at night if required
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat > /etc/apt/apt.conf.d/52unattended-upgrades-local <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer

# ---------------------------------------------------------------- CUPS
log "CUPS"
systemctl enable --now cups avahi-daemon

ADMIN_USER="$(getent passwd 1000 | cut -d: -f1 || true)"
if [ -n "$ADMIN_USER" ]; then
  usermod -aG lpadmin "$ADMIN_USER"
  if [ "$(passwd -S "$ADMIN_USER" | awk '{print $2}')" != P ]; then
    warn "$ADMIN_USER has no password: set one (passwd), it is needed for CUPS admin actions"
  fi
fi

# Web UI on, shared on the LAN (the firewall restricts it to the LAN), never --remote-any.
# Remote admin = HTTPS + password of an lpadmin user; plain viewing of printers/jobs needs none.
cupsctl --share-printers --no-remote-any --remote-admin WebInterface=yes

# Build the driver list now: on a Pi 1 it takes minutes, and the web UI's Add Printer page
# would time out on the first visit otherwise
echo "Building the printer driver list (a few minutes on a Pi 1)..."
lpinfo -m | wc -l || warn "could not build the driver list"

# ---------------------------------------------------------------- firewall (last, so nothing above is cut off)
log "Firewall (LAN only)"
LAN_CIDR="$(ip -4 route show dev "$IFACE" scope link | awk '$1 !~ /^169\.254/ && !f {print $1; f=1}')"
[ -n "$LAN_CIDR" ] || die "could not detect the LAN subnet on $IFACE"
echo "Allowing the LAN: $LAN_CIDR"

ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow from "$LAN_CIDR" to any port 631 proto tcp     # CUPS: printing + web UI
ufw allow from "$LAN_CIDR" to any port 5353 proto udp    # mDNS / AirPrint discovery
ufw allow from "$LAN_CIDR" to any port 22 proto tcp      # SSH, only matters if you enable it
ufw allow from fe80::/10 to any port 631 proto tcp       # IPv6 link-local (iOS often uses it)
ufw allow from fe80::/10 to any port 5353 proto udp
ufw --force enable

# ---------------------------------------------------------------- wrap up
rm -f "$DIR/secrets.env"
echo "secrets.env deleted (copy it back to re-run this script)"

log "Summary"
lpstat -p -d || true
echo
echo "Listening sockets (expect only CUPS 631 and Avahi 5353, plus DHCP/NTP clients):"
ss -tulpn || true
echo
echo "IP address(es): $(hostname -I)"
echo "CUPS web UI: https://$(hostname).local:631/  (or https://<ip>:631/, accept the self-signed cert)"
echo "Next: add the printer in the web UI (Administration > Add Printer), tick \"Share This Printer\""
echo "=== bootstrap finished $(date -Is) ==="
