# kiosk — club-agnostic Raspberry Pi TV kiosks

Repo `github.com/garjones/curling-kiosk` (private until Gareth flips it
public, which the install model requires — Claude cannot change repo
visibility). The umbrella `../CLAUDE.md` rules apply: club-agnostic
product, KCC is the pilot site, nothing club-specific in this repo.
README.md is the real documentation; read it before changing anything.

## State (29 Sep 2026)

v11 built and proven off-Pi; **not yet run on a real Pi**. Parity with
v10.3 display modes and layout; club values moved to `club.conf`;
install is `bootstrap.sh` over SSH from this repo (decision 29 Sep
2026: same machine-key model as streamer; v1 = parity + config; the
fleet monitor is deferred). `tools/demo.sh` passes 64 checks;
shellcheck clean at warning level.

Next: Gareth makes the repo public, adds nothing else (KCC's
`kiosk/club.conf` + `kiosk/secrets.env.age` are already in
`../clubs/kcc`), installs one test Pi and works through the checklist
at the end of INSTALLATION.md. Rollout to the fleet after that, then
rotate the camera/Pi passwords (they stay as they are during the build,
by decision 29 Sep 2026 — private network, physical access needed).

## Layout

```
bootstrap.sh          one-line installer (curl | sudo bash) — public raw URL
bin/kiosk-run         display engine (ported kiosk.run.sh)
bin/kiosk-menu        whiptail operator menu (ported kiosk.sh)
bin/kiosk-deploy      applies <club-dir>/kiosk/ to this Pi; --check; v10 conversion
bin/kiosk-update      pulls both repos, runs kiosk-deploy
bin/kiosk-watchdog    network watchdog (ported wifi-watchdog.sh)
lib/kiosk-common.sh   config loading, URL-encoding, legacy conversion
systemd/              kiosk.service template, unclutter.service
tools/demo.sh         the proof; run it after any change
tools/cameras-all.sh  all cameras at once
monitor/              v10 kiosk-monitor.ps1, unchanged, KCC-specific — to be rebuilt
```

## Working here

- Run `tools/demo.sh` after every change. On the Cowork VM, `age` and
  `shellcheck` are not installed by default: static binaries from their
  GitHub releases into `$HOME/bin` (outside mnt/) work.
- On this mount, in-place edits (`sed -i`, python rewrite) drop the
  executable bit. `chmod 755` and check `git ls-files -s` before
  committing.
- Git in the connected folder needs delete permission (lock files).
- Provenance: files came from the v10.3 KCC system
  (`../legacy/curling-pi-kiosk`, still in production, still carrying
  live credentials at HEAD). This repo's history was checked 29 Sep
  2026 before going public: no credentials; only KCC subnet mentions
  and the name "Kelowna" in old docs and the monitor.
