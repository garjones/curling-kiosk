# Installing a kiosk Pi

Everything happens over SSH, and all the software comes from the public
curling-kiosk repo on GitHub.

## You need

- A Raspberry Pi 4 or later, a 16 GB or larger microSD card, a power
  supply, and an HDMI cable to the TV
- The network the cameras are on (Wi-Fi or Ethernet)
- The name of the club's **site repo** on GitHub, for example
  `yourname/curling-yourclub`
- The **club machine key** from the club's password manager (the whole
  `-----BEGIN ... -----END` block)
- Once only, per club: the machine key's public half added as a
  read-only **deploy key** on the site repo

## 1. Flash the card

In Raspberry Pi Imager:

- Choose **Raspberry Pi OS (64-bit) with desktop**. The desktop image is
  needed because the web-page mode uses Chromium.
- Under Edit settings:
  - Set a hostname, a username and a password, the Wi-Fi details if you
    use Wi-Fi, and the time zone.
  - On the Services tab, turn SSH on.

The username you choose here is the account that runs the display.

## 2. Boot and find the Pi

1. Put the card in, connect the TV and power, and wait 2 to 3 minutes.
2. Find the Pi's address in the router's device list, or with
   `nmap -sn <your-subnet>`.

## 3. Install

```sh
ssh <username>@<pi-address>

curl -fsSL https://raw.githubusercontent.com/garjones/curling-kiosk/main/bootstrap.sh \
  | sudo bash -s -- --club <owner>/<site-repo>
```

When it asks, paste the machine key and press Enter. The installer
then:

1. Installs its packages (git, age, ffmpeg, unclutter, whiptail)
2. Clones the software to `/opt/curling-kiosk`
3. Clones the site repo to `/opt/curling-club` and decrypts the camera
   login
4. Installs the service, the daily reboot, the network watchdog and
   the menu

If `club.conf` has a mistake, the installer stops and lists what is
wrong. Fix it in the site repo, push, and run the same line again.

```sh
sudo reboot
```

After the reboot, the TV shows **"This screen has not been set up
yet"** with the Pi's address.

## 4. Choose what the screen shows

SSH in again and the menu opens:

| Menu item | Shows |
|---|---|
| Two sheets (cameras) | A pair of sheets, lower number at the bottom |
| One sheet (cameras) | One sheet |
| Any two sheets | Any two sheets you type in |
| Web page | One of the club's pages |
| Screen rotation | Set this first on a portrait-mounted TV |
| Software update | Latest software and club settings, then a reboot |

Confirm with Yes and the Pi reboots into that display.

## Converting a v10 Pi (curling-pi-kiosk)

Run the same install line on the existing Pi. It keeps showing what it
showed before: its `~/kiosk.config` becomes `display.conf`. The old
service, cron jobs and login hook are replaced. The old files in the
home directory are left in place and are no longer used.

## First test on a single Pi

Before rolling out to the rest of the fleet, check each item on one Pi
and the real TV:

- [ ] The install line completes and the setup screen appears after the
      reboot.
- [ ] **Two sheets.** Four tiles, the away end on the left, the lower
      sheet at the bottom, and the right number in each centre label.
- [ ] Unplug one camera's network cable. That tile comes back by itself
      within about 10 seconds of plugging it back in.
- [ ] **One sheet**, **Any two sheets** and **Web page** each show what
      was chosen.
- [ ] **Screen rotation → Vertical**, then pick a display. The labels
      turn, and choosing another display keeps it vertical.
- [ ] The status bar shows the club name, the time and the Pi's
      address.
- [ ] **Software update** runs and the Pi reboots into the same
      display.
- [ ] `ps aux | grep ffplay` shows the camera URLs. This is expected
      (see README "Known gaps"). Nothing else should reveal the
      password: `ls -l /etc/kiosk` shows `secrets.env` as `-rw-r-----`
      and `machine.key` as `-rw-------`.
- [ ] After `sudo systemctl restart kiosk` the screen comes back.
- [ ] The next morning, the daily reboot happened
      (`last reboot | head`).

## Troubleshooting

| Symptom | Check |
|---|---|
| The setup screen names a problem | Do what it says. It usually means `club.conf` in the site repo needs fixing, followed by Software update. |
| A camera tile stays black | `ping <camera-address>` from the Pi, then `tools/cameras-all.sh` in `/opt/curling-kiosk`. |
| The menu does not appear on login | Run `kiosk-menu` by hand. The hook is in `~/.bashrc` between the `curling-kiosk menu` markers. |
| The install says it could not clone the site repo | Is the machine key a deploy key on that repo? Is it the right club's key? |
| The install says it could not clone the software | The product repo must be public. |
