# Changelog

All notable changes to the kiosk are documented here. v10.x and earlier
were the Kelowna Curling Club system (`curling-pi-kiosk`); v11 is the
club-agnostic rebuild.

---

## [v11.0] — in development, not yet on a real Pi

### Changed
- Everything specific to one club (club name, number of sheets, camera
  URLs, web pages, reboot time, watchdog host) now comes from the club's
  `club.conf`. Nothing club-specific is left in the code.
- The camera login is kept in a separate `secrets.env`, which is
  committed only as age ciphertext in the club's private site repo and
  decrypted on the Pi with the club machine key. Passwords are
  URL-encoded into the camera URLs.
- Installing is one line over SSH (`bootstrap.sh`) from this public
  repo. Updates are `kiosk-update` or menu → Software update. v10 fetched
  loose files, including `kiosk.env` with the passwords, from GitHub on
  every login.
- Runs as the Pi's own login user rather than a fixed `kcckiosk` account.
- The display choice is kept in `/etc/kiosk/display.conf` as named
  settings rather than a coded line like `HC0102`.
- The watchdog logs only failures.
- A Pi with no usable configuration shows a local setup screen that
  explains the problem.

### Fixed
- "Any two sheets" for single-digit sheets wrote a config line the
  engine could not read.
- Choosing a new display reset a vertical screen to horizontal.

### Migration
- `kiosk-deploy` converts a v10 Pi in place and keeps its display
  choice. The v10 `kiosk-monitor.ps1` still works, because `kiosk-run`
  honours a newer `~/kiosk.config`.

---

## [v10.3]

### Added (kiosk-monitor.ps1 v5.4)
- Resolution control in the per-Pi config panel — a dropdown populated dynamically
  from the modes the connected TV actually advertises (via `wlr-randr`), filtered to
  known-standard resolutions: 4K (3840×2160), 1440p (2560×1440), 1080p (1920×1080),
  1680×1050, 1600×900, 1366×768, 1280×1024, and 720p (1280×720)
- Current resolution pre-selected in the dropdown, sourced from the Pi card poll data
- **Apply** button sets the resolution immediately via `wlr-randr` (no reboot required)
  and restarts `kiosk.service` so the display layout recalculates at the new resolution
- `/get-resolutions` HTTP endpoint SSHes into the Pi, runs `wlr-randr`, and returns
  the subset of supported modes that match the known-standard list
- `/set-resolution` HTTP endpoint SSHes into the Pi, auto-detects the active HDMI
  output name via `wlr-randr`, applies the selected mode, and restarts `kiosk.service`

### Known Limitations
- Resolution changes require `wlr-randr` to be installed on the Pi (present by default
  on Raspberry Pi OS Debian 13 Trixie with labwc)
- `WAYLAND_DISPLAY=wayland-0` is assumed — correct for the standard labwc session on
  this fleet but may differ on other Pi OS configurations

---

## [v10.2]

### Added (kiosk-monitor.ps1 v5.2)
- Camera Viewer now uses ffmpeg piped to ffplay to work around ffplay 8.1 dropping
  multi-input support
- `/viewer-status` HTTP endpoint returns whether the camera viewer process is running
- Camera Viewer toolbar button toggles between launch and close states

### Changed
- Bulk action handlers (Reboot All, Software Update All, System Update All) rewritten
  as inline `foreach` loops directly in HTTP handlers — fixes variable scoping issues
  in runspaces that caused silent failures
- `Load-Hosts` now called on every poll cycle so fleet changes take effect without
  restarting the script
- JavaScript template literals replaced with string concatenation throughout the
  HTTP-served HTML to avoid PowerShell consuming backtick characters

---

## [v10.1]

### Added (kiosk-monitor.ps1 v5.1)
- Edit Pi Hosts button in the toolbar — opens a slide-in panel showing the raw
  `pi-hosts.txt` content in an editable textarea. Save writes the file atomically
  and reloads the dashboard; changes take effect on the next poll cycle
- `/save-hosts` HTTP endpoint on `localhost:8080` handles the file write from the browser

---

## [v10.0]

### Added (kiosk-monitor.ps1 v5.0)
- Pi cards now show uptime (via `uptime -p`) when reachable
- Pi cards now show current screen resolution (via `kmsprint`) when reachable
- Dark/light mode toggle in the dashboard header — preference saved across page reloads via localStorage
- Live countdown timer in the header — counts down to next refresh, shows `Refresh paused` in amber when paused
- Page refresh auto-pauses when the config panel or progress modal is open, resumes on close
- Rename Pi — click the ✏️ icon next to the Pi name in the config panel to rename inline; confirms with ✓, cancels with Escape or ✗, reboots on confirm
- Install Kiosk action in the config panel — reinstalls kiosk services, cron entries, and `.bashrc` autorun with live streamed output

### Changed
- `kiosk-monitor2.ps1` renamed to `kiosk-monitor.ps1`
- `README.md` — corrected all filename references, expanded dashboard feature list to reflect current capabilities
- `CHANGELOG.md` — updated to reflect v10.0 changes

---

## [v9.9]

### Changed
- `kiosk-monitor2.ps1` renamed to `kiosk-monitor.ps1` now that the previous version has been removed
- `README.md`, `CHANGELOG.md`, `INSTALLATION.md` updated to reflect the rename

---

## [v9.8]

### Added
- `kiosk-monitor2.ps1` — new cross-platform PowerShell monitoring and management dashboard (v4.6), superseding `kiosk-monitor.ps1` and `kiosk-manager.ps1`. Features:
  - 2-row × 12-column camera grid with live JPEG snapshots fetched via curl with digest auth, displayed as thumbnails rotated 90° clockwise
  - Pi fleet cards showing ping, SSH, kiosk service status, decoded current config (e.g. `Horizontal · Cameras · Sheets 1 & 2`), and last seen timestamp when offline
  - Clickable Pi cards open a slide-in config panel for changing rotation, mode, and sheet assignment, with live config code preview
  - Per-Pi actions in the config panel: Software Update (GitHub files + reboot), System Update (apt with live streamed output), Reboot
  - Global toolbar actions: Reboot All, Software Update All (parallel), System Update All (sequential with streamed output)
  - Camera Viewer button launches all 24 RTSP streams in a 2×12 ffplay xstack overlay; Close Viewer button kills all streams
  - HTTP listener on `localhost:8080` handles all browser-to-script actions
  - Parallel polling — all 13 Pis and 26 cameras polled concurrently; dashboard written twice per cycle (Pis first, cameras second)
  - Cross-platform: uses native `ssh`/`sshpass` instead of `plink.exe`; cross-platform ping; curl-based snapshot fetch
  - Auto-opens browser after first poll completes

### Removed
- `kiosk-monitor.ps1` — superseded by `kiosk-monitor2.ps1`
- `kiosk-monitor.html` — superseded by self-contained HTML written by `kiosk-monitor2.ps1`
- `kiosk-manager.ps1` — all functionality now covered by `kiosk-monitor2.ps1`

### Changed
- `README.md` — updated repository file table, added Monitoring & Management Dashboard section, removed references to deleted files
- `INSTALLATION.md` — added Running the Status Monitor section with PowerShell install instructions for macOS
- `CHANGELOG.md` — updated to reflect v9.8 changes

---

## [v9.7]

### Added
- `do_menu_rotation()` wired into the main menu as **P5 — Screen Rotation**, allowing operators to set Horizontal or Vertical orientation before selecting a display mode. Previous P5–P9 items shifted to P6–P10

### Changed
- `do_video()` in `kiosk.run.sh` — added `$6` rotation parameter. When screen rotation is set to Vertical (`V`), a `-vf transpose=2` filter is applied to all camera feeds (90° counter-clockwise), matching the existing rotation behaviour of labels and the IP bar
- `kiosk.sh` updated to version 9.7
- `kiosk.run.sh` updated to version 9.7

---

## [v9.6]

### Added
- `kiosk-monitor.ps1` — background PowerShell script that polls all 13 Pis and 24 cameras every 30 seconds and writes a self-contained `kiosk-monitor.html` file. Checks ping, SSH port availability, and `kiosk.service` status per Pi (via `plink.exe`); checks RTSP port 554 reachability per camera
- `kiosk-monitor.html` — self-contained always-on browser dashboard written by `kiosk-monitor.ps1` on every poll cycle. Displays a summary bar (Pis online, kiosk services active, cameras reachable), a Pi fleet grid with colour-coded ping/SSH/service status per Pi, and a camera grid showing Home and Away status for all 12 sheets. Uses `<meta http-equiv="refresh">` to auto-reload every 30 seconds — no server required, opens directly in any browser

---

## [v9.5]

### Added
- `kiosk-manager.ps1` — new Windows PowerShell management tool for the club laptop. Provides a GUI dashboard covering fleet monitoring (ping + SSH port check per Pi), software updates (push latest files from GitHub to all Pis), remote display configuration (set rotation, mode, and sheet assignment on any Pi without SSHing in individually), remote reboot, and a 24-camera viewer via ffplay/xstack. Reads Pi fleet from `pi-hosts.txt` and camera IPs/credentials from `kiosk.env`. Requires `plink.exe` (PuTTY) for SSH and `ffplay.exe` (FFmpeg) for the camera viewer

### Changed
- `pi-hosts.txt` — updated with live Pi IP addresses (`10.200.30.11`–`10.200.30.23`) and correct hostnames (`kcc-pi-01`–`kcc-pi-13`), replacing the previous placeholder entries. 13 Pis in total

---

## [v9.4]

### Changed
- `do_label()` in `kiosk.run.sh` — wrapped in a subshell loop with a 5 second retry delay so sheet number labels restart automatically if the ffplay process exits
- `do_labelip()` in `kiosk.run.sh` — same automatic restart behaviour applied to the bottom IP/hostname bar

---

## [v9.3]

### Changed
- `kiosk.env` — added `URL_CAM_HOME` and `URL_CAM_AWAY` arrays, built inline from `CAM_USER`, `CAM_PASS`, and the `CAM_HOME`/`CAM_AWAY` IP arrays. RTSP URL construction now lives in one place
- `kiosk.run.sh` — removed `URL_CAM_HOME`, `URL_CAM_AWAY`, and `URL_KIOSK` array definitions; all three are now sourced directly from `kiosk.env`. A dev override block replaces RTSP URLs with `tiny-test.mp4` after sourcing when not running on a Pi. Updated to version 9
- `cameras-all.sh` — removed inline URL construction; `URL_CAM_HOME` and `URL_CAM_AWAY` are now sourced from `kiosk.env`. Updated to version 3

---

## [v9.2]

### Added
- `wifi-watchdog.sh` — new script that pings `1.1.1.1` every 15 minutes and reboots the Pi if the network is unreachable. Results are logged to `/var/log/wifi-watchdog.log` with timestamps
- `deploy.sh` — new centralised deploy script run from a Mac/Linux machine. Reads Pi hostnames and IPs from `pi-hosts.txt` and can perform Auto Update, Install, Reboot, or Update & Install across all Pis in a single operation
- `pi-hosts.txt` — new file listing all Pi IP addresses and hostnames. Used by `deploy.sh`
- `CAMERAS.md` — new reference document mapping all 12 sheets to their Home and Away camera IPs, TV screen assignments, subnet breakdown, and a camera troubleshooting guide
- `do_install()` in `kiosk.sh` now adds the Wi-Fi watchdog to cron (`*/15 * * * *`) alongside the existing daily 7:00 AM reboot entry
- `do_auto_update()` in `kiosk.sh` now downloads `wifi-watchdog.sh` from GitHub on every SSH login

### Changed
- `kiosk.service` — `Restart=on-abort` changed to `Restart=on-failure` so the display recovers from crashes, non-zero exit codes, and timeouts, not just abort signals. `RestartSec=5` added to prevent rapid restart loops
- `do_video()` in `kiosk.run.sh` — wrapped in a subshell loop with a 5 second retry delay so individual RTSP streams reconnect automatically if they drop, without requiring a full service restart
- `do_labelip()` in `kiosk.run.sh` — bottom bar now displays hostname alongside IP address (e.g. `10.200.30.101 - kiosk-tv01`)
- `kiosk.run.sh` updated to version 9
- `cameras-all.sh` updated to version 3

---

## [v9.1]

### Added
- `kiosk.env` — new centralised config file committed to GitHub containing camera credentials (`CAM_USER`, `CAM_PASS`), home camera IPs (`CAM_HOME[]`), away camera IPs (`CAM_AWAY[]`), and kiosk advertising URLs (`URL_KIOSK[]`)
- `kiosk.run.sh` now sources `kiosk.env` at startup and builds RTSP URLs dynamically using credentials and IPs from that file
- `kiosk.run.sh` falls back to `whatismyipaddress.com` error screen if `kiosk.env` is missing on boot

### Changed
- `do_auto_update()` in `kiosk.sh` now downloads `kiosk.env` from GitHub alongside `kiosk.run.sh`, `kiosk.service`, and `unclutter.service` — ensuring all Pis receive config changes automatically on the next SSH login
- Camera credentials and IPs removed from `kiosk.run.sh` — now sourced entirely from `kiosk.env`
- Kiosk advertising URLs removed from `kiosk.run.sh` — now sourced entirely from `kiosk.env`
- `kiosk.run.sh` updated to version 8
- `cameras-all.sh` updated to version 2, use kiosk.env
- `INSTALLATION.md` updated to redact SSH password

---

## [v9.0]

### Added
- Single Sheet camera mode (`S`) — displays Home and Away cameras for one sheet only, with blank panels in the top half of the screen
- Sheet number label rendered in the centre column between camera feeds
- IP address bar displayed along the bottom of the screen (using `do_labelip`)
- Screen rotation support — Horizontal (`H`) and Vertical (`V`) modes, applying `transpose` filter to labels when vertical
- `do_labelip` function renders "Kelowna Curling Club" alongside the Pi's IP address
- Dev/Mac mode — substitutes `tiny-test.mp4` for all RTSP streams and uses Google Chrome instead of Chromium when not running on a Pi
- Fallback error mode — displays `whatismyipaddress.com` when config is unrecognised
- `cameras-all.sh` script to test all 24 cameras

### Changed
- Config file format extended to 6-character code: `{Rotation}{Mode}{Sheet1}{Sheet2}` (e.g. `HC0102`)
- `do_label` and `do_labelip` now accept a rotation parameter passed through from the config
- `kiosk.sh` menu title updated to `v8.3`
- `kiosk.run.sh` updated to version 7

---

## [v8.0]

### Added
- Kiosk / advertising mode (`K`) — launches Chromium in fullscreen kiosk mode pointing at the club's advertising display URLs
- Two kiosk channels: Upstairs (`K01`) and Practice Ice Downstairs (`K02`)
- `do_kiosk` function handles Chromium launch with `--noerrdialogs --disable-infobars --kiosk` flags
- Chromium crash recovery — on startup, `Preferences` file is patched to clear `exited_cleanly:false` and `exit_type:Crashed` flags

### Changed
- Config mode character expanded to support `K` in addition to `C`

---

## [v7.0]

### Added
- Club Cameras mode (`C`) — displays a 2×2 mosaic of Home and Away camera feeds for two curling sheets simultaneously
- Pre-defined sheet pairs in menu: 1&2, 3&4, 5&6, 7&8, 9&10, 11&12
- Custom Cameras option — operator can manually enter any two sheet numbers
- `do_video` function launches `ffplay` RTSP streams positioned and sized to fill screen quadrants
- `do_label` function draws sheet number labels in the centre column using `ffplay` and `ffmpeg` `drawtext` filter
- Screen resolution auto-detected on Pi using `kmsprint`
- Layout calculations for video width, height, position derived from screen resolution at runtime

### Changed
- Usable screen height reduced by label bar height to accommodate bottom IP bar

---

## [v6.0]

### Added
- `do_auto_update` — on every SSH login, latest `kiosk.run.sh`, `kiosk.service`, and `unclutter.service` are downloaded from GitHub before the menu is shown
- `do_install` function — installs `kiosk.service` and `unclutter.service` as systemd services, adds daily 7:00 AM reboot to cron, disables default desktop autostart, and configures menu to auto-launch on SSH login via `.bashrc`
- `unclutter.service` — hides mouse cursor after idle period
- `kiosk.service` — systemd service to launch `kiosk.run.sh` on boot
- Software Update menu option (`P5`) — runs `apt autoremove`, `apt update`, `apt upgrade`, and installs `unclutter`
- Raspberry Pi Config menu option (`P6`) — opens `raspi-config`
- Reboot menu option (`P8`)

---

## [v5.0]

### Added
- Single Camera menu (`P2`) — lists all 12 sheets individually for single-sheet display
- `do_write_config` — prompts for confirmation, writes config to `/home/kcckiosk/kiosk.config`, syncs filesystem, and reboots
- Config written as a single line and read back by `kiosk.run.sh` on next boot

---

## [v4.0]

### Added
- `whiptail`-based TUI menu system for SSH configuration
- Main menu with named options and Cancel/Quit handling
- Club Cameras menu (`P1`) with pre-defined sheet pair options
- `do_menu_custom_cameras` — freeform input for bottom and top sheet numbers

---

## [v3.0]

### Added
- RTSP camera URL arrays defined for all 12 Home and Away cameras
- Cameras distributed across two subnets: `10.100.1.x` and `10.200.30.x`
- Axis camera streams accessed via `rtsp://root:<password>@<ip>/axis-media/media.amp`

---

## [v2.0]

### Added
- Initial `kiosk.run.sh` display script
- Basic `ffplay` invocation to display a single video stream fullscreen

---

## [v1.0] — Initial Release

### Added
- Initial project structure
- `kiosk.sh` configuration script skeleton
- README with prerequisites and one-liner install command
- `.gitignore`

---

*© Gareth Jones — gareth@gareth.com*
