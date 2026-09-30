#!/bin/bash
# demo.sh — prove the kiosk's logic without a Pi, a TV or a camera.
#
#   tools/demo.sh
#
# Runs every display mode through kiosk-run's dry run, a full kiosk-deploy
# into a scratch root (including converting a v10 Pi), and the config
# parsing edge cases. Prints PASS/FAIL per check; exits non-zero on any
# failure. Needs bash, and age + ssh-keygen for the decryption check
# (skipped, and said so, if they are missing).
#
# What this cannot prove: that ffplay and Chromium draw the right thing
# on a real screen. That is the single-Pi test in INSTALLATION.md.

set -u
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FAILS=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILS=$((FAILS + 1)); }
check() { local what=$1; shift; if "$@"; then pass "$what"; else fail "$what"; fi; }
has()   { grep -qF -- "$2" <<<"$1"; }
hasnt() { ! grep -qF -- "$2" <<<"$1"; }
not()   { ! "$@"; }

PASSWORD='p@ss:w/rd #1é'
ENC='p%40ss%3Aw%2Frd%20%231%C3%A9'

# ---- a small club: 3 sheets, one camera URL written with double quotes ----
ETC="$T/etc"; mkdir -p "$ETC"
cat > "$ETC/club.conf" <<'CONF'
CLUB_NAME="Demo Curling Club"
SHEETS=3
CAM_HOME[1]='rtsp://${CAM_USER}:${CAM_PASS}@10.0.0.51/stream'
CAM_HOME[2]='rtsp://${CAM_USER}:${CAM_PASS}@10.0.0.52/stream'
CAM_HOME[3]="rtsp://${CAM_USER}:${CAM_PASS}@10.0.0.53/stream"
CAM_AWAY[1]='rtsp://${CAM_USER}:${CAM_PASS}@10.0.0.71/stream'
CAM_AWAY[2]='rtsp://${CAM_USER}:${CAM_PASS}@10.0.0.72/stream'
CAM_AWAY[3]='rtsp://${CAM_USER}:${CAM_PASS}@10.0.0.73/stream'
WEB_URL[1]='https://example.com/signage?a=1&b=2'
WEB_NAME[1]='Lounge'
CONF
# a v10-style kiosk.env: quoted values, arrays, comments — only the two
# CAM_ lines may be taken from it
cat > "$ETC/secrets.env" <<SEC
# old kiosk.env
KCC_VERSION="10.3"
CAM_USER="root"
CAM_PASS="$PASSWORD"
CAM_HOME=(
  "10.1.1.1"
)
SEC

echo "---- configuration"
(
    export KIOSK_ETC="$ETC"
    . "$REPO/lib/kiosk-common.sh"
    kiosk_load_club
    check "secrets: user read from quoted line"    [ "$CAM_USER" = root ]
    check "secrets: password read intact"          [ "$CAM_PASS" = "$PASSWORD" ]
    check "url-encoding of @ : / space # and UTF-8" [ "$(kiosk_urlencode "$PASSWORD")" = "$ENC" ]
    check "camera URL gets encoded login"          [ "$(kiosk_cam_url home 1)" = "rtsp://root:$ENC@10.0.0.51/stream" ]
    check "double-quoted club.conf line still works" [ "$(kiosk_cam_url home 3)" = "rtsp://root:$ENC@10.0.0.53/stream" ]
    check "valid club.conf passes the check"       kiosk_check_club
    check "pairs for 3 sheets: only 1-2"           [ "$(kiosk_pairs)" = "1 2" ]
    SHEETS=4; unset 'CAM_AWAY[3]'; CAM_HOME[4]=x; CAM_AWAY[4]=x; REBOOT_TIME=7am
    out=$(kiosk_check_club); rc=$?
    check "check fails on missing camera"          has "$out" "CAM_AWAY[3] is missing"
    check "check fails on bad REBOOT_TIME"         has "$out" "REBOOT_TIME must be HH:MM"
    check "check returns non-zero"                 [ $rc -ne 0 ]
    check "legacy HC0102 -> pair 1/2" [ "$(kiosk_convert_legacy HC0102 | tr '\n' ' ')" = "ROTATION=H MODE=pair BOTTOM=1 TOP=2 " ]
    check "legacy VS0303 -> single 3" [ "$(kiosk_convert_legacy VS0303 | tr '\n' ' ')" = "ROTATION=V MODE=single BOTTOM=3 " ]
    check "legacy HK01 -> web 1"      [ "$(kiosk_convert_legacy HK01 | tr '\n' ' ')" = "ROTATION=H MODE=web WEB=1 " ]
    check "legacy garbage rejected"   not kiosk_convert_legacy "hello"
)

run() { KIOSK_ETC="$ETC" KIOSK_DRY_RUN=1 KIOSK_SCREEN=1920x1080 TMPDIR="$T" "$REPO/bin/kiosk-run" 2>&1; }

echo "---- kiosk-run: two sheets"
printf 'MODE=pair\nROTATION=H\nTOP=2\nBOTTOM=1\nWEB=0\n' > "$ETC/display.conf"
out=$(run)
check "four camera tiles"                 [ "$(grep -c '^RUN\[bg\] ffplay rtsp' <<<"$out")" = 4 ]
# 1920x1080: usable height 1030, tiles 910x515, right column at 1010
check "top-left = sheet 2 away at 0,0"    has "$out" "ffplay rtsp://root:****@10.0.0.72/stream -an -noborder -alwaysontop -x 910 -y 515 -left 0 -top 0"
check "top-right = sheet 2 home at 1010,0" has "$out" "@10.0.0.52/stream -an -noborder -alwaysontop -x 910 -y 515 -left 1010 -top 0"
check "bottom-left = sheet 1 away"        has "$out" "@10.0.0.71/stream -an -noborder -alwaysontop -x 910 -y 515 -left 0 -top 515"
check "bottom-right = sheet 1 home"       has "$out" "@10.0.0.51/stream -an -noborder -alwaysontop -x 910 -y 515 -left 1010 -top 515"
check "sheet labels 2 and 1"              has "$out" "drawtext=text='2'"
check "status bar carries club name"      has "$out" "drawtext=text='Demo Curling Club'"
check "password never printed (raw)"      hasnt "$out" "$PASSWORD"
check "password never printed (encoded)"  hasnt "$out" "$ENC"

echo "---- kiosk-run: vertical single sheet"
printf 'MODE=single\nROTATION=V\nBOTTOM=3\n' > "$ETC/display.conf"
out=$(run)
check "two camera tiles, both sheet 3"    [ "$(grep -c '@10.0.0.[57]3/stream' <<<"$out")" = 2 ]
check "labels rotated"                    has "$out" ",transpose=2"

echo "---- kiosk-run: web page"
printf 'MODE=web\nWEB=1\n' > "$ETC/display.conf"
out=$(run)
check "chromium opens the local wrapper"  has "$out" "--kiosk --disable-web-security --allow-file-access-from-files file://$T/kiosk.html"
check "wrapper iframes the page, &-escaped" grep -qF 'src="https://example.com/signage?a=1&amp;b=2"' "$T/kiosk.html"
check "wrapper shows club name"           grep -qF '<span>Demo Curling Club</span>' "$T/kiosk.html"

echo "---- kiosk-run: problems become a setup screen, not a blank TV"
rm -f "$ETC/display.conf"
out=$(run)
check "no display.conf -> setup screen"   grep -qF 'This screen has not been set up yet.' "$T/kiosk.html"
check "...and no cameras started"         hasnt "$out" "ffplay rtsp"
printf 'MODE=pair\nTOP=9\nBOTTOM=1\n' > "$ETC/display.conf"
run >/dev/null
check "sheet out of range -> setup screen" grep -qF 'Sheets 1 and 9 are not both between 1 and 3.' "$T/kiosk.html"

echo "---- kiosk-run: the v10 monitor's ~/kiosk.config still works"
FAKEHOME="$T/home"; mkdir -p "$FAKEHOME"
printf 'MODE=web\nWEB=1\n' > "$ETC/display.conf"
touch -d '2 minutes ago' "$ETC/display.conf"
echo "HS0202" > "$FAKEHOME/kiosk.config"
out=$(HOME="$FAKEHOME" run)
check "newer kiosk.config wins (sheet 2 single)" [ "$(grep -c '@10.0.0.[57]2/stream' <<<"$out")" = 2 ]
touch "$ETC/display.conf"; touch -d '2 minutes ago' "$FAKEHOME/kiosk.config"
out=$(HOME="$FAKEHOME" run)
check "newer display.conf wins (web page)"  has "$out" "file://$T/kiosk.html"
rm -rf "$FAKEHOME"

echo "---- kiosk-menu, driven by a scripted stand-in for whiptail"
# The stub answers each whiptail call from a queue: a menu tag, "yes", or
# "no"/"back". It also records every menu it was shown.
mkdir -p "$T/stub"
cat > "$T/stub/whiptail" <<'STUB'
#!/bin/bash
echo "$*" >> "$WT_LOG"
ans=$(head -n1 "$WT_QUEUE"); sed -i 1d "$WT_QUEUE"
case "$ans" in
    yes) exit 0;;
    no|back|"") exit 1;;
    *) echo "$ans" >&2; exit 0;;
esac
STUB
chmod +x "$T/stub/whiptail"
menu() {   # menu answer... — run kiosk-menu with these answers
    printf '%s\n' "$@" > "$T/queue"; : > "$T/wtlog"
    PATH="$T/stub:$PATH" WT_QUEUE="$T/queue" WT_LOG="$T/wtlog" KIOSK_ETC="$ETC" \
        KIOSK_NO_REBOOT=1 "$REPO/bin/kiosk-menu" >/dev/null 2>&1
}
rm -f "$ETC/display.conf"
menu P1 C0102 yes
check "menu: two sheets 1&2 saved"        grep -qx 'TOP=2' "$ETC/display.conf"
check "menu: offered only pair 1-2 of 3 sheets" grep -qF 'C0102 Sheets 1 and 2' "$T/wtlog"
check "menu: no pair 3-4 offered"         not grep -qF 'C0304' "$T/wtlog"
menu P5 V P2 S03 yes
check "menu: rotation V kept with single 3" [ "$(tr '\n' ' ' < "$ETC/display.conf")" = "MODE=single ROTATION=V TOP=0 BOTTOM=3 WEB=0 " ]
menu P1 C0102 yes
check "menu: rotation survives a mode change" grep -qx 'ROTATION=V' "$ETC/display.conf"
menu P3 7 ok 3 2 yes   # "ok" dismisses the error box
check "menu: custom pair rejects sheet 7" grep -qF "'7' is not a sheet number from 1 to 3." "$T/wtlog"
check "menu: custom pair 3 bottom, 2 top" [ "$(grep -E '^(TOP|BOTTOM)=' "$ETC/display.conf" | tr '\n' ' ')" = "TOP=2 BOTTOM=3 " ]
menu P4 K01 yes
check "menu: web page 1 offered by name"  grep -qF 'K01 Lounge' "$T/wtlog"
check "menu: web page saved"              grep -qx 'MODE=web' "$ETC/display.conf"
cp "$ETC/display.conf" "$T/before"
menu P1 C0102 no back
check "menu: answering No changes nothing" cmp -s "$T/before" "$ETC/display.conf"

echo "---- kiosk-deploy into a scratch root, converting a v10 Pi"
R="$T/root"; U=$(id -un); H="$R/home/$U"
CLUBREPO="$T/club"; mkdir -p "$CLUBREPO/kiosk" "$H" "$R/lib/systemd/system" "$R/etc/xdg/labwc" "$R/etc/kiosk"
cp "$ETC/club.conf" "$CLUBREPO/kiosk/club.conf"
echo "HC0304" > "$H/kiosk.config"
printf 'export X=1\n/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/garjones/pi-kiosk/main/kiosk.sh)"\n' > "$H/.bashrc"
ln -s "$H/kiosk.service" "$R/lib/systemd/system/kiosk.service"
echo "labwc-autostart" > "$R/etc/xdg/labwc/autostart"

AGE_OK=0
if command -v age >/dev/null 2>&1 && command -v ssh-keygen >/dev/null 2>&1; then
    AGE_OK=1
    ssh-keygen -q -t ed25519 -N '' -C demo -f "$T/machine" >/dev/null
    printf 'CAM_USER=root\nCAM_PASS=%s\n' "$PASSWORD" | age -R "$T/machine.pub" -o "$CLUBREPO/kiosk/secrets.env.age"
    install -m 600 "$T/machine" "$R/etc/kiosk/machine.key"
else
    cp "$ETC/secrets.env" "$R/etc/kiosk/secrets.env"
fi
out=$(KIOSK_ROOT="$R" "$REPO/bin/kiosk-deploy" "$CLUBREPO" --user "$U" 2>&1); rc=$?
check "deploy exits 0"                     [ $rc -eq 0 ]
[ $rc -eq 0 ] || echo "$out"
if [ $AGE_OK = 1 ]; then
    check "secrets decrypted with the machine key" grep -qxF "CAM_PASS=$PASSWORD" "$R/etc/kiosk/secrets.env"
    check "secrets.env mode 640" [ "$(stat -c %a "$R/etc/kiosk/secrets.env")" = 640 ]
else
    echo "SKIP  age decryption (age or ssh-keygen not installed here)"
fi
check "v10 kiosk.config HC0304 -> display.conf" grep -qx 'TOP=4' "$R/etc/kiosk/display.conf"
check "v10 unit symlink removed"           [ ! -e "$R/lib/systemd/system/kiosk.service" ]
check "kiosk.service written for this user" grep -qx "User=$U" "$R/etc/systemd/system/kiosk.service"
check "kiosk.service runs kiosk-run"       grep -qx "ExecStart=/usr/local/bin/kiosk-run" "$R/etc/systemd/system/kiosk.service"
check "no placeholders left in unit"       not grep -q '@[A-Z]*@' "$R/etc/systemd/system/kiosk.service"
check "daily reboot at 07:00"              grep -qx '0 7 \* \* \* root /sbin/shutdown -r now' "$R/etc/cron.d/curling-kiosk"
check "watchdog every 15 minutes"          grep -qF '*/15 * * * * root /usr/local/bin/kiosk-watchdog' "$R/etc/cron.d/curling-kiosk"
check "commands linked onto PATH"          [ "$(readlink "$R/usr/local/bin/kiosk-menu")" = "$REPO/bin/kiosk-menu" ]
check "v10 GitHub line gone from .bashrc"  not grep -q 'pi-kiosk' "$H/.bashrc"
check "rest of .bashrc kept"               grep -qx 'export X=1' "$H/.bashrc"
check "menu hook added once"               [ "$(grep -c '>>> curling-kiosk menu >>>' "$H/.bashrc")" = 1 ]
check "desktop autostart disabled"         [ -f "$R/etc/xdg/labwc/autostart.disabled" ]
check "install.conf records user and club" grep -qx "CLUB_DIR=$CLUBREPO" "$R/etc/kiosk/install.conf"

out=$(KIOSK_ROOT="$R" "$REPO/bin/kiosk-deploy" "$CLUBREPO" --user "$U" 2>&1); rc=$?
check "second run exits 0 (idempotent)"    [ $rc -eq 0 ]
check "second run keeps display.conf"      has "$out" "keeping"
check "menu hook still there only once"    [ "$(grep -c '>>> curling-kiosk menu >>>' "$H/.bashrc")" = 1 ]

echo 'SHEETS=0' >> "$CLUBREPO/kiosk/club.conf"
out=$(KIOSK_ROOT="$R" "$REPO/bin/kiosk-deploy" "$CLUBREPO" --user "$U" 2>&1); rc=$?
check "broken club.conf stops deploy (78)" [ $rc -eq 78 ]
check "...and says why"                    has "$out" "SHEETS must be a number"

echo
if [ $FAILS -eq 0 ]; then echo "demo: all checks passed"; else echo "demo: $FAILS check(s) FAILED"; exit 1; fi
