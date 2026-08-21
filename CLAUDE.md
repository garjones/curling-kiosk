# kiosk — club-agnostic rebuild of the Pi kiosk system

Seed folder for the rebuild of the KCC Pi kiosk system (Raspberry Pi driven
TVs showing camera feeds or rotating web content). Not yet a git repo; will
be renamed/rebranded before it becomes one. The umbrella `../CLAUDE.md` rules
apply: club-agnostic product, KCC is the pilot site, nothing KCC-specific gets
hardcoded or committed.

## What is in this folder

Generic engine files copied 20 Aug 2026 from the production checkout at
`~/dev/claude/kcc-old/pi-kiosk` (repo `github.com/garjones/pi-kiosk`, private
since 20 Aug 2026, v10.1, in production at KCC — the Pis install from GitHub):

- `kiosk.run.sh` — display engine (Chromium kiosk or RTSP mosaic)
- `kiosk.sh` — whiptail operator menu, presented on SSH login
- `kiosk-monitor.ps1` — fleet monitor; polls Pis + cameras, writes a
  self-contained HTML status page
- `cameras-all.sh` — local mosaic of all cameras, for testing
- `wifi-watchdog.sh` — cron job, reboots the Pi if the network is gone
- `kiosk.service`, `unclutter.service` — systemd units
- `tiny-test.mp4` — test asset
- `README.md`, `INSTALLATION.md`, `CHANGELOG.md` — docs from the KCC system

**Credentials were scrubbed from these copies** (`root:<password>@`,
"in `kiosk.env`", `CHANGEME` placeholders in the ps1). The originals in the
pi-kiosk repo still contain the real values. Do not reintroduce credentials
here; the rebuild should load them from an untracked per-site env file.

Deliberately NOT copied here (KCC-specific): `kiosk.env` (live camera + Pi
credentials), `CAMERAS.md` (camera fleet), `pi-hosts.txt` (Pi IPs),
`kiosk.config` (per-device id), `kiosk-monitor.html` (generated output with
embedded fleet status). Those live in the pi-kiosk repo and, as the pilot
site's operational reference, in `../clubs/kcc/kiosk/` (`kiosk.env` holds
live credentials — never let it near a git repo).

The old working checkout at `~/dev/claude/kcc-old` was cleaned up on
20 Aug 2026: its two uncommitted production changes were pushed to the
pi-kiosk repo, the five files above copied to `../clubs/kcc/kiosk/`, and the
folder deleted.

## Rebuild notes (when that work starts)

- New name/branding to be chosen; new repo; this folder's files are the
  starting point, not sacred.
- Rotate the camera and Pi credentials before anything is published — the old
  values were public on GitHub long enough to assume they were scraped
  (`../HANDOFF.md` §4.4 has the history).
- The cameras are Axis, end-of-support, seven unpatched CVEs; the rebuild
  should not assume they stay.
- Everything site-specific (camera lists, host lists, credentials, device
  ids) becomes per-club configuration, following the `clubs/<club>/` pattern.
- Rewrite this file once the rebuild begins; it currently documents
  provenance, not architecture.
