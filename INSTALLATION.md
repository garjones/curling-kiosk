# KCC Pi Kiosk — Installation Guide

**Setting up a new Raspberry Pi Kiosk for the Kelowna Curling Club**

---

## Requirements

### Hardware

- Raspberry Pi 4 (or later)
- MicroSD card (16 GB minimum, 32 GB recommended)
- Power supply (USB-C, 5V/3A)
- HDMI cable and television/display
- Network connection (Wi-Fi or Ethernet)
- A computer to write the SD card image

### Software

- [Raspberry Pi Imager](https://www.raspberrypi.com/software/) installed on your computer

---

## Step 1 — Flash the SD Card

1. Insert the MicroSD card into your computer.
2. Open **Raspberry Pi Imager**.
3. Click **Choose Device** and select your Pi model.
4. Click **Choose OS** and select:
   ```
   Raspberry Pi OS (other) → Raspberry Pi OS Full (64-bit)
   ```
   > ⚠️ You must use the **Full** desktop image, not Lite. The kiosk requires a desktop environment.

5. Click **Choose Storage** and select your MicroSD card.
6. Click **Next**, then click **Edit Settings** when prompted to apply OS customisation.

---

## Step 2 — Apply OS Settings in Imager

In the **General** tab:

| Setting | Value |
|---|---|
| Hostname | A unique name for this Pi (e.g. `kiosk-tv01`) |
| Username | `kcckiosk` |
| Password | `********` |
| Wi-Fi SSID | *(enter the club's Wi-Fi network name)* |
| Wi-Fi Password | *(enter the club's Wi-Fi password)* |
| Wi-Fi Country | `CA` |
| Timezone | `America/Vancouver` |

In the **Services** tab:

| Setting | Value |
|---|---|
| Enable SSH | ✅ Enabled |
| Authentication | Use password authentication |

Click **Save**, then **Yes** to apply settings, then **Yes** to confirm writing the card.

> ⚠️ This will erase everything on the SD card.

Wait for the write and verification to complete before removing the card.

---

## Step 3 — First Boot

1. Insert the MicroSD card into the Raspberry Pi.
2. Connect the HDMI cable to the television.
3. Connect power to the Pi.
4. Wait approximately **2–3 minutes** for the Pi to complete its first boot and connect to the network.

> The desktop will appear on screen once the Pi has booted. Auto-login is enabled, so no keyboard or mouse is needed at this stage.

---

## Step 4 — Find the Pi's IP Address

You'll need the Pi's IP address to connect via SSH. A few ways to find it:

**Option A — Check your router's device list**
Log in to the club's router/access point admin page and look for a device matching the hostname you set (e.g. `kiosk-tv01`).

**Option B — Use a network scanner**
Use a tool like [Angry IP Scanner](https://angryip.org/) or the `nmap` command on another machine:
```bash
nmap -sn 10.200.30.0/24
```

**Option C — Attach a keyboard temporarily**
Connect a USB keyboard, open a terminal on the Pi, and run:
```bash
hostname -I
```

---

## Step 5 — Connect via SSH and Install

From any computer on the same network, open a terminal and connect:

```bash
ssh kcckiosk@<pi-ip-address>
```

When prompted, enter the password:
```
********
```

> On first connection you'll be asked to confirm the host fingerprint — type `yes` and press Enter.

Once connected, run the kiosk installer:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/garjones/pi-kiosk/main/kiosk.sh)"
```

This will:

1. Download the latest kiosk scripts from GitHub
2. Present the **Kiosk Management Menu**

---

## Step 6 — Install the Kiosk Service

In the Kiosk Management Menu, select:

```
P7 → Install Kiosk
```

This performs the following actions automatically:

- Installs the `unclutter` service (hides the mouse cursor)
- Installs the `kiosk` systemd service (starts display on boot)
- Adds a daily 7:00 AM reboot to cron
- Disables the default desktop autostart
- Configures the menu to auto-launch on every SSH login

---

## Step 7 — Update System Packages

Still in the menu, select:

```
P5 → Software Update
```

This runs `apt update` and `apt upgrade` to ensure the Pi is fully up to date. This may take several minutes on the first run.

---

## Step 8 — Configure the Display

Select the appropriate display mode for this screen's location:

### Club Cameras (most common)

```
P1 → Club Cameras
```

Choose the pair of sheets this screen should display:

| Option | Sheets Shown |
|---|---|
| C0102 | Sheets 1 & 2 |
| C0304 | Sheets 3 & 4 |
| C0506 | Sheets 5 & 6 |
| C0708 | Sheets 7 & 8 |
| C0910 | Sheets 9 & 10 |
| C1112 | Sheets 11 & 12 |

### Single Sheet

```
P2 → Single Camera
```

Select the individual sheet number to display.

### Advertising / Kiosk

```
P4 → Kiosk
```

| Option | Location |
|---|---|
| K01 | Upstairs advertising display |
| K02 | Practice Ice (Downstairs) |

### Custom Camera Pair

```
P3 → Custom Cameras
```

Enter any two sheet numbers manually (e.g. sheet 3 as bottom, sheet 7 as top).

---

## Step 9 — Confirm and Reboot

After selecting a display mode, you'll be asked:

```
Are you sure?  [ Yes ]  [ No ]
```

Select **Yes**. The Pi will:

1. Write the new configuration to `/home/kcckiosk/kiosk.config`
2. Reboot automatically

After rebooting (approximately 30–60 seconds), the screen will begin displaying the configured content.

---

## Reconfiguring an Existing Pi

To change what a Pi is displaying at any time:

```bash
ssh kcckiosk@<pi-ip-address>
# Password: ********
```

The configuration menu will launch automatically. Select the new display mode, confirm, and the Pi will reboot with the new settings.

---

## Running the Status Monitor

`kiosk-monitor.ps1` is a PowerShell script that polls all Pis and cameras and generates a live status dashboard (`kiosk-monitor.html`).

### On Windows

PowerShell is built into Windows 10 and 11 — no installation required. Right-click `kiosk-monitor.ps1` and select **Run with PowerShell**, or run it from a terminal:

```powershell
.\kiosk-monitor.ps1
```

### On macOS

PowerShell is not installed by default on macOS and must be installed separately. The recommended method is via Homebrew:

```bash
brew install --cask powershell
```

Once installed, run the monitor from Terminal:

```bash
pwsh kiosk-monitor.ps1
```

> If you don't have Homebrew, install it first from [https://brew.sh](https://brew.sh), or download PowerShell directly from [https://github.com/PowerShell/PowerShell/releases](https://github.com/PowerShell/PowerShell/releases).

---

## Troubleshooting

### Screen shows "whatismyipaddress.com"

The `kiosk.config` file is missing, empty, or contains an unrecognised value. SSH in, select a display mode from the menu, and confirm.

### Screen is blank or shows the desktop

The kiosk service may not be installed or enabled. SSH in and run **P7 → Install Kiosk** from the menu, then reboot.

### Camera feeds show a black screen or don't load

- Verify the Pi has network connectivity: `ping 10.100.1.1`
- Confirm the camera IP addresses are reachable from the Pi's subnet
- Check that `ffplay` is installed: `which ffplay` (install with `sudo apt install ffmpeg`)

### SSH connection refused

- Confirm SSH was enabled in Imager settings (Step 2)
- Try rebooting the Pi by briefly disconnecting power
- Confirm you're on the same network as the Pi

### Menu doesn't appear on SSH login

The `.bashrc` autorun entry may be missing. SSH in and manually run:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/garjones/pi-kiosk/main/kiosk.sh)"
```

Then select **P7 → Install Kiosk** to restore the autorun.

---

## Network Reference

| Resource | Details |
|---|---|
| Pi SSH user | `kcckiosk` |
| Pi SSH password | `********` |
| Pi IP range | `10.200.30.xxx` |
| Camera subnet A | `10.100.1.x` |
| Camera subnet B | `10.200.30.x` |
| Camera username | `root` |
| Camera password | *(in `kiosk.env`)* |
| Source code | `https://github.com/garjones/pi-kiosk` |

---

*© Gareth Jones — gareth@gareth.com*
