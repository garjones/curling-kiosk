#!/bin/bash
# --------------------------------------------------------------------------------
#  cameras-all.sh — every camera of the club at once, to check them
# --------------------------------------------------------------------------------
#  Away ends across the top row, home ends across the bottom, one column
#  per sheet. Reads the same config as the kiosk (KIOSK_ETC, default
#  /etc/kiosk), so on a deployed Pi it just works:
#
#      tools/cameras-all.sh               real cameras
#      tools/cameras-all.sh --offline     tiny-test.mp4 in every tile
#      KIOSK_SCREEN=1800x1169 tools/cameras-all.sh    set the window area
#
#  Press Enter to close everything.
# --------------------------------------------------------------------------------
#  (C) Copyright Gareth Jones - gareth@gareth.com
# --------------------------------------------------------------------------------

set -u
HERE="$(dirname "$(readlink -f "$0")")"
# shellcheck source=../lib/kiosk-common.sh
. "$HERE/../lib/kiosk-common.sh"

KIOSK_ERROR=""
kiosk_load_club || { echo "cameras-all: $KIOSK_ERROR" >&2; exit 1; }
if ! problems=$(kiosk_check_club); then
    echo "cameras-all: club.conf has problems:" >&2; echo "$problems" >&2; exit 1
fi
OFFLINE=0; [ "${1:-}" = "--offline" ] && OFFLINE=1

RES="${KIOSK_SCREEN:-1800x1169}"
SCRN_WIDTH=${RES%x*}
SCRN_HEIGHT=${RES#*x}
VID_W=$((SCRN_WIDTH / SHEETS))
VID_H=$((SCRN_HEIGHT / 2))

do_video() {
    (while true; do
        ffplay "$1" -an -noborder -alwaysontop -x "$2" -y "$3" -left "$4" -top "$5"
        sleep 5
    done) &
}

for ((n = 1; n <= SHEETS; n++)); do
    if [ "$OFFLINE" = 1 ]; then
        away="$HERE/tiny-test.mp4"; home="$away"
    else
        away="$(kiosk_cam_url away "$n")"; home="$(kiosk_cam_url home "$n")"
    fi
    do_video "$away" "$VID_W" "$VID_H" $((VID_W * (n - 1))) 0
    do_video "$home" "$VID_W" "$VID_H" $((VID_W * (n - 1))) "$VID_H"
done

read -r -p "Press Enter to quit..." _
kill 0
