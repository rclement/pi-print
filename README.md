# Pi Print

> Using a Raspberry Pi as a WiFi printer proxy box for old USB-only printers

Old printers are not reachable over WiFi networks thus cannot be used with mobile devices without USB connectivity (smartphones, tablets). Hence this project to turn old USB printers into AirPrint-compatible printers over a local network.

## Setup

1. Copy `secrets.env.example` into `secrets.env` and fill the variables
2. Flash a Raspberry Pi OS Lite (Bookworm or later) onto an SD Card, with a username and password set
3. Open the SD Card `bootfs` volume
4. Add the following files to the `bootfs` volume:
```
bootfs
|__/bootstrap
   |__ setup.sh
   |__ secrets.env
```
5. Plug the WiFi dongle into the Raspberry Pi, start it with the SD Card, log-in and run the script:
```bash
sudo bash /boot/firmware/bootstrap/setup.sh
```
6. Plug the printer in and add it from the CUPS web interface at `https://<hostname>.local:631/` (Administration > Add Printer), logging in with the Raspberry Pi user. Tick "Share This Printer" and pick the Gutenprint driver for your model

## Usage

- Print from iOS / macOS: the printer shows up as an AirPrint printer
- Print from Android: add it manually with the URL `ipp://<hostname>.local:631/printers/<printer name>`
- Print from a computer (the printer URL is `ipp://<hostname>.local:631/printers/<printer name>`, replace `<hostname>.local` with the Raspberry Pi IP address if the name is not resolved):
  - macOS: System Settings > Printers & Scanners > Add Printer, pick the printer (AirPrint). If it is not listed, use the IP tab with protocol IPP and the `/printers/<printer name>` queue
  - Linux: the printer is usually discovered in the system printer settings. Otherwise add it by URL there, or run `sudo lpadmin -p <printer name> -E -v <printer URL> -m everywhere`
  - Windows: Settings > Bluetooth & devices > Printers & scanners > Add device. If it is not listed, "Add manually" > "Select a shared printer by name" and enter `http://<hostname>.local:631/printers/<printer name>`
- Check jobs: open `https://<hostname>.local:631/` from the local network. No password to view jobs, the Raspberry Pi user password is asked for admin actions
