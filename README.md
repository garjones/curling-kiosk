# curling-kiosk

Raspberry Pi kiosks for a curling club's TVs. Each Pi drives one screen
and shows one of:

- **Two sheets**: four live camera tiles, with the away end on the left,
  the home end on the right and the sheet numbers down the middle
- **One sheet**: the two cameras of one sheet
- **A web page** full-screen, such as signage or a counter `/tv` page

A status bar along the bottom shows the club name, the time and the
Pi's address. What each screen shows is chosen from a menu that opens
when you SSH in. No Linux knowledge is needed.

It works for any club. Everything about a particular club (its name,
sheets, cameras, pages and camera login) lives in that club's own
private **site repo**, never here. This repo is public so that a Pi can
install it with one line.

> Rebuilt from the Kelowna Curling Club's v10.3 kiosk system
> (`curling-pi-kiosk`). The screen layout is unchanged. What changed is
> where configuration comes from and how a Pi is installed. See
> CHANGELOG.md.

## How a Pi gets set up

Setup is done entirely over SSH, from this public repo:

```sh
curl -fsSL https://raw.githubusercontent.com/garjones/curling-kiosk/main/bootstrap.sh \
  | sudo bash -s -- --club <owner>/<site-repo>
```

It asks for one thing, the **club machine key**. That is an SSH private
key kept in the club's password manager. The key does two jobs: it is a
read-only deploy key on the club's site repo, and it decrypts the
camera login stored there. The streaming nodes
([curling-streamer](https://github.com/garjones/curling-streamer)) use
the same key, so there is one key per club.

INSTALLATION.md has the full step-by-step. Running the same line again
upgrades the Pi. After the first install, **Software update** in the
menu does the same thing.

## The club's site repo

The club's site repo needs a `kiosk/` folder containing two files:

| File | What it is |
|---|---|
| `kiosk/club.conf` | Club name, number of sheets, one camera URL per end of each sheet, the web pages, the daily reboot time and the watchdog host. Start from `club.example.conf`. |
| `kiosk/secrets.env.age` | `CAM_USER` and `CAM_PASS`, encrypted with [age](https://age-encryption.org) to the machine key's public half. Start from `secrets.example.env`. |

Camera URLs write the login as the literal text `${CAM_USER}` and
`${CAM_PASS}`. The real values are filled in when the screen starts, and
they are URL-encoded, so any character works in the password.

To check an edited `club.conf` before pushing it:
`bin/kiosk-deploy --check <site-repo>`.

## On the Pi

| Where | What |
|---|---|
| `/opt/curling-kiosk` | this repo (public, pulled over HTTPS) |
| `/opt/curling-club` | the club's site repo (pulled with the machine key) |
| `/etc/kiosk/club.conf` | copied from the site repo |
| `/etc/kiosk/secrets.env` | decrypted camera login; readable only by root and the kiosk user |
| `/etc/kiosk/machine.key` | the machine key; readable only by root |
| `/etc/kiosk/display.conf` | what this screen shows; written by the menu |
| `/etc/kiosk/install.conf` | the kiosk user and site-repo path, used by `kiosk-update` |
| `/etc/cron.d/curling-kiosk` | the daily reboot, and the watchdog every 15 minutes |
| `kiosk.service` | runs `kiosk-run` as the Pi's login user at boot |

| Command | What it does |
|---|---|
| `kiosk-run` | The display engine. `KIOSK_DRY_RUN=1 kiosk-run` prints what it would start, with passwords masked. |
| `kiosk-menu` | The operator menu. It runs on SSH login; Quit leaves you at a normal shell. |
| `kiosk-update` | Pulls both repos and re-deploys. Run with `sudo`. |
| `kiosk-deploy` | Applies the site repo to this Pi. Also `--check`. |
| `kiosk-watchdog` | Reboots the Pi if the watchdog host has been unreachable. |
| `tools/cameras-all.sh` | Every camera at once, for checking them. `--offline` uses a test clip instead. |

If the configuration is missing or wrong, the screen does not go blank.
It shows what is wrong and the SSH command to fix it.

## Proving it

`tools/demo.sh` runs 64 checks with no Pi, TV or camera:

- Every display mode through the engine's dry run, including tile
  positions and checks that no password is printed
- The menu, driven by a scripted stand-in for whiptail
- A full `kiosk-deploy` into a scratch root, including converting a v10
  Pi and real age decryption with a throwaway key

The deploy checks need `age` and `ssh-keygen`; without them the
decryption check is skipped and the script says so. The scripts pass
`shellcheck -x -S warning`.

What the demo cannot show is the picture on a real screen. That is the
single-Pi test at the end of INSTALLATION.md.

## Decisions taken while building

- **Same install model as curling-streamer.** Code comes from this public
  repo and club settings from a private one. Secrets are committed only
  as age ciphertext, and one machine key per club unlocks them.
- **`club.conf` is a shell file, not YAML.** The Pi has bash and nothing
  that parses YAML. A volunteer can read and edit `KEY="value"`. It is
  sourced, because it comes from the club's own repo.
- **`secrets.env` is parsed, never sourced.** Only `CAM_USER` and
  `CAM_PASS` are taken, so a whole v10 `kiosk.env` also works.
- **Converting a v10 Pi happens in place.** `kiosk-deploy` turns
  `~/kiosk.config` into `display.conf` and removes v10's unit symlinks,
  crontab lines and fetch-from-GitHub `.bashrc` line. The old files in
  the home directory are left alone.
- **The v10 monitor keeps working during the move.** `kiosk-run` uses
  `~/kiosk.config` when it is newer than `display.conf`. That is the
  file `kiosk-monitor.ps1` writes when it changes a screen.
- **Two v10 menu faults were fixed while porting.** "Any two sheets" for
  sheets 3 and 7 wrote `C37`, which the engine could not read. Rotation
  was also reset to horizontal on every mode change.
- **The setup screen is local.** An unconfigured Pi shows a local page
  instead of `whatismyipaddress.com`.

## Known gaps

- **The camera URL, password included, is on ffplay's command line.**
  It is visible in `ps` to anyone logged into the Pi, as it was in v10.
  ffplay has no other way to take it. The Pi is single-purpose and
  that login is the kiosk user's anyway.
- **The fleet monitor is not rebuilt yet.** `monitor/kiosk-monitor.ps1`
  is the v10 script, still hard-wired to one club. It is deferred until
  the Pi side is proven.
- **`unclutter` does nothing under Wayland (labwc).** It is carried over
  unchanged from v10.

## Not yet tested

- On a real Pi, TV or camera. `tools/demo.sh` covers the logic only.
- The `bootstrap.sh` clone from GitHub, which needs this repo to be
  public and the machine key to be a deploy key on the site repo.
