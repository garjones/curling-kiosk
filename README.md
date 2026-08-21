# KCC Pi Kiosk — System Overview

**Raspberry Pi Kiosk Configuration for Kelowna Curling Club**

---

## Overview

The KCC Pi Kiosk system drives every television screen in the Kelowna Curling Club. Each screen is powered by a Raspberry Pi that can be configured to display one of two modes:

- **Camera Mode** — live RTSP video feeds from overhead cameras above the curling sheets
- **Kiosk Mode** — rotating advertising content displayed in a web browser

Configuration is performed by connecting to each Pi over SSH. On login, a menu-driven interface is automatically presented to the operator — no technical knowledge of Linux is required.

A browser-based monitoring and management dashboard (`kiosk-monitor.ps1`) runs on a Mac or Windows machine at the club and provides live status, camera thumbnails, and remote management of the entire Pi fleet.

---

## Repository

```
https://github.com/garjones/pi-kiosk
```

| File | Description |
|---|---|
| `kiosk.sh` | SSH configuration menu (whiptail TUI). Auto-runs on login and auto-updates from GitHub. |
| `kiosk.run.sh` | Display engine. Reads the config file on boot and launches the appropriate content. |
| `kiosk.config` | Single-line config file written by `kiosk.sh` and read by `kiosk.run.sh`. |
| `kiosk.service` | systemd service that runs `kiosk.run.sh` on boot. |
| `kiosk.env` | Central config file containing camera credentials, IPs, and kiosk advertising URLs. |
| `unclutter.service` | systemd service that hides the mouse cursor. |
| `wifi-watchdog.sh` | Cron script that reboots the Pi if the network is unreachable. |
| `deploy.sh` | Centralised deploy script for pushing updates and rebooting all Pis from a Mac/Linux machine. |
| `cameras-all.sh` | Utility script for testing all 24 camera feeds locally. |
| `kiosk-monitor.ps1` | Cross-platform PowerShell monitoring and management dashboard. |
| `pi-hosts.txt` | List of Pi IP addresses and hostnames used by `deploy.sh` and `kiosk-monitor.ps1`. |
| `tiny-test.mp4` | Local test video used in place of RTSP streams during development. |

---

## Display Modes

### Camera Mode — Two Sheets (`C`)

Displays live feeds for **two curling sheets** simultaneously. Each sheet has two cameras (Home end and Away end), producing a **2×2 video mosaic**. A thin column of sheet number labels runs down the centre, and the Pi's IP address is shown in a bar along the bottom.

```
┌──────────────┬─────┬──────────────┐
│  Sheet N     │  N  │  Sheet N     │
│  Away Camera │     │  Home Camera │
├──────────────┼─────┼──────────────┤
│  Sheet M     │  M  │  Sheet M     │
│  Away Camera │     │  Home Camera │
├──────────────┴─────┴──────────────┤
│         IP Address Bar            │
└───────────────────────────────────┘
```

### Camera Mode — Single Sheet (`S`)

Displays live feeds for **one curling sheet** only. The Home and Away cameras for that sheet are shown side by side in the bottom half of the screen. The top half is blank.

### Kiosk / Advertising Mode (`K`)

Displays a **web-based advertising carousel** using Chromium in fullscreen kiosk mode. Two advertising channels are available:

| Code | Location |
|---|---|
| `K01` | Upstairs |
| `K02` | Practice Ice (Downstairs) |

---

## Configuration File Format

The configuration is stored as a single line in `/home/kcckiosk/kiosk.config`.

```
{Rotation}{Mode}{BottomSheet}{TopSheet}
```

| Position | Length | Description | Values |
|---|---|---|---|
| 1 | 1 char | Screen orientation | `H` = Horizontal, `V` = Vertical |
| 2 | 1 char | Display mode | `C` = Club cameras, `S` = Single camera, `K` = Kiosk |
| 3–4 | 2 chars | Bottom sheet number | `01`–`12` |
| 5–6 | 2 chars | Top sheet number | `01`–`12` |

**Example:** `HC0102` → Horizontal, Club cameras, showing sheets 1 (bottom) and 2 (top).

> For Kiosk mode (`K`), only chars 3–4 are used (to select the advertising channel number).

---

## Camera Hardware

The club has **12 curling sheets**, each covered by two [Axis IP cameras](https://www.axis.com):

- **Home camera** — pointed at the home end of the sheet
- **Away camera** — pointed at the away end of the sheet

Cameras stream via **RTSP** and are accessed using:

```
rtsp://root:<password>@<camera-ip>/axis-media/media.amp
```

Cameras are distributed across two internal subnets:

| Subnet | Usage |
|---|---|
| `10.100.1.x` | Primary camera network |
| `10.200.30.x` | Secondary camera network |

---

## System Services

Two systemd services run on each Pi:

| Service | Unit File | Purpose |
|---|---|---|
| `kiosk` | `kiosk.service` | Launches `kiosk.run.sh` on boot to display content |
| `unclutter` | `unclutter.service` | Hides the mouse cursor after a short idle period |

A **daily cron job** reboots each Pi automatically at 7:00 AM to ensure a clean state each day:

```cron
0 7 * * * /sbin/shutdown -r now
```

A **Wi-Fi watchdog** runs every 15 minutes and reboots the Pi if the network is unreachable:

```cron
*/15 * * * * /bin/bash /home/kcckiosk/wifi-watchdog.sh
```

---

## SSH Configuration Access

Each Pi can be configured by connecting via SSH:

```
Host:     10.200.30.xxx
User:     kcckiosk
Password: ********
```

On login, the configuration menu launches automatically. No shell commands are needed — simply navigate the menus to select the desired display mode, confirm, and the Pi will reboot and begin displaying the new content.

---

## Configuration Menu Options

| Option | Description |
|---|---|
| **Club Cameras** | Select a pre-defined pair of adjacent sheets (1&2, 3&4, etc.) |
| **Single Camera** | Display one sheet only |
| **Custom Cameras** | Manually enter any two sheet numbers |
| **Kiosk** | Select an advertising display channel |
| **Screen Rotation** | Set screen orientation to Horizontal or Vertical |
| **Software Update** | Run `apt update` / `apt upgrade` |
| **Raspberry Config** | Open `raspi-config` for system-level settings |
| **Install Kiosk** | Install/re-install the kiosk services |
| **Reboot** | Reboot the Pi immediately |

---

## Auto-Update

Each time the configuration menu is opened (i.e. on every SSH login), `kiosk.sh` automatically downloads the latest versions of `kiosk.run.sh`, `kiosk.service`, `kiosk.env`, `wifi-watchdog.sh`, and `unclutter.service` from GitHub before presenting the menu. This ensures all Pis are always running the current software without manual intervention.

---

## Monitoring & Management Dashboard

`kiosk-monitor.ps1` is a cross-platform PowerShell script that runs on a Mac or Windows machine at the club. It polls all Pis and cameras every 30 seconds and generates a self-contained `kiosk-monitor.html` dashboard that opens automatically in the browser.

### Features

- **Pi fleet status** — live ping, SSH, and kiosk service status per Pi with colour-coded cards
- **Current config display** — shows what each Pi is displaying (e.g. `Horizontal · Cameras · Sheets 1 & 2`)
- **Uptime display** — shows how long each Pi has been running
- **Screen resolution display** — shows the current screen resolution of each Pi
- **Last seen timestamp** — shows when a Pi or camera was last reachable when currently offline
- **Camera thumbnail grid** — live JPEG snapshots from all 24 cameras in a 2-row × 12-column grid (Away and Home rows)
- **Dark/light mode toggle** — switch between dark and light themes, preference saved across reloads
- **Live refresh countdown** — header shows time until next refresh; pauses automatically when a panel is open
- **Remote configuration** — click any Pi card to open a slide-in panel and change its display mode
- **Rename Pi** — click the edit icon next to the Pi name in the panel to rename it and reboot
- **Software update** — push latest files from GitHub to a Pi and reboot
- **System update** — run `apt update && apt upgrade` on a Pi with live streamed output
- **Install Kiosk** — reinstall kiosk services, cron entries, and autorun on a Pi with live output
- **Global actions toolbar** — Reboot All, Software Update All, System Update All across the entire fleet
- **Camera viewer** — launch all 24 live RTSP streams in a 2×12 ffplay overlay

### Requirements

| Tool | Platform | Notes |
|---|---|---|
| PowerShell 7+ | Both | `brew install --cask powershell` on macOS |
| `ssh` | Both | Built-in on macOS/Linux and Windows 10/11 |
| `sshpass` | macOS/Linux | `brew install sshpass` |
| `curl` | Both | Built-in on macOS/Linux and Windows 10/11 |
| `ffplay` | Both | `brew install ffmpeg` — required for Camera Viewer only |

### Running the monitor

**macOS:**
```bash
pwsh kiosk-monitor.ps1
```

**Windows:**
```powershell
.\kiosk-monitor.ps1
```

The dashboard opens automatically in the browser after the first poll completes.

---

## Development & Testing

The display script (`kiosk.run.sh`) detects whether it is running on a Raspberry Pi or a macOS/Linux dev machine:

- **On Pi:** Uses live RTSP camera streams and `kmsprint` to detect screen resolution
- **On Mac/Dev:** Substitutes `tiny-test.mp4` for all camera feeds and assumes a 1920×1080 resolution, opening streams in Google Chrome instead of Chromium

---

*© Gareth Jones — gareth@gareth.com*
