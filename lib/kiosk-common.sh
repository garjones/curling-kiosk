#!/bin/bash
# shellcheck disable=SC2034  # a library: the variables it sets are read by its callers
# kiosk-common.sh — shared by kiosk-run, kiosk-menu, kiosk-deploy and the
# tools. Loads the three configuration files and turns them into shell
# variables. Nothing here starts anything.
#
#   /etc/kiosk/club.conf     the club: name, sheets, cameras, web pages.
#                            Comes from the club's site repo; same on every Pi.
#   /etc/kiosk/secrets.env   CAM_USER and CAM_PASS. Decrypted from the
#                            club's site repo; never in a git repo in clear.
#   /etc/kiosk/display.conf  what THIS screen shows. Written by kiosk-menu.
#
# KIOSK_ETC overrides /etc/kiosk (the tools use it to run without root).

KIOSK_ETC="${KIOSK_ETC:-/etc/kiosk}"

# ---------------------------------------------------------------------------
# kiosk_load_club — read club.conf and secrets.env
# ---------------------------------------------------------------------------
# club.conf is a shell file, but camera URLs name the credentials as the
# literal text ${CAM_USER} and ${CAM_PASS}. Whether the volunteer used
# single or double quotes, the placeholders survive: while club.conf is
# read, the two variables are set to their own names. The real values are
# substituted later, URL-encoded, by kiosk_cam_url.
kiosk_load_club() {
    CLUB_NAME=""
    SHEETS=0
    REBOOT_TIME="07:00"
    WATCHDOG_HOST="1.1.1.1"
    CAM_HOME=(); CAM_AWAY=(); WEB_URL=(); WEB_NAME=()

    if [ ! -r "$KIOSK_ETC/club.conf" ]; then
        KIOSK_ERROR="$KIOSK_ETC/club.conf is missing"
        return 1
    fi
    _kiosk_source_club
    kiosk_load_secrets
}

_kiosk_source_club() {
    # shellcheck disable=SC2016  # the literal placeholder text is the point
    local CAM_USER='${CAM_USER}' CAM_PASS='${CAM_PASS}'
    # shellcheck source=/dev/null
    . "$KIOSK_ETC/club.conf"
}

# secrets.env is read line by line, never sourced: only CAM_USER and
# CAM_PASS are taken, with optional surrounding quotes removed. Anything
# else in the file (an old kiosk.env, say) is ignored.
kiosk_load_secrets() {
    CAM_USER=""; CAM_PASS=""
    [ -r "$KIOSK_ETC/secrets.env" ] || return 0
    local key val
    while IFS='=' read -r key val || [ -n "$key" ]; do
        case "$key" in
            CAM_USER|CAM_PASS)
                val="${val%$'\r'}"
                case "$val" in
                    \"*\") val="${val#\"}"; val="${val%\"}";;
                    \'*\') val="${val#\'}"; val="${val%\'}";;
                esac
                printf -v "$key" '%s' "$val";;
        esac
    done < "$KIOSK_ETC/secrets.env"
}

# ---------------------------------------------------------------------------
# kiosk_check_club — print one line per problem; return 1 if any
# ---------------------------------------------------------------------------
kiosk_check_club() {
    local bad=0 n
    [ -n "$CLUB_NAME" ] || { echo "CLUB_NAME is empty"; bad=1; }
    if ! [[ "$SHEETS" =~ ^[0-9]+$ ]] || [ "$SHEETS" -lt 1 ] || [ "$SHEETS" -gt 99 ]; then
        echo "SHEETS must be a number from 1 to 99 (it is '$SHEETS')"; return 1
    fi
    for ((n = 1; n <= SHEETS; n++)); do
        [ -n "${CAM_HOME[n]:-}" ] || { echo "CAM_HOME[$n] is missing"; bad=1; }
        [ -n "${CAM_AWAY[n]:-}" ] || { echo "CAM_AWAY[$n] is missing"; bad=1; }
    done
    for n in "${!WEB_URL[@]}"; do
        [ -n "${WEB_NAME[n]:-}" ] || { echo "WEB_URL[$n] has no WEB_NAME[$n]"; bad=1; }
    done
    if [ -n "$REBOOT_TIME" ] && ! [[ "$REBOOT_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        echo "REBOOT_TIME must be HH:MM, 24-hour, or empty (it is '$REBOOT_TIME')"; bad=1
    fi
    # shellcheck disable=SC2016
    if printf '%s\n' "${CAM_HOME[@]}" "${CAM_AWAY[@]}" | grep -q '${CAM_PASS}' && [ -z "$CAM_PASS" ]; then
        echo "camera URLs use \${CAM_PASS} but $KIOSK_ETC/secrets.env has no CAM_PASS"; bad=1
    fi
    return $bad
}

# ---------------------------------------------------------------------------
# kiosk_cam_url home|away N — the camera URL with credentials filled in
# ---------------------------------------------------------------------------
kiosk_urlencode() {
    local LC_ALL=C s="$1" out="" c i   # byte by byte, so UTF-8 encodes correctly
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c";;
            *) out+=$(printf '%%%02X' "'$c");;
        esac
    done
    printf '%s' "$out"
}

kiosk_cam_url() {
    local url
    if [ "$1" = home ]; then url="${CAM_HOME[$2]:-}"; else url="${CAM_AWAY[$2]:-}"; fi
    url="${url//\$\{CAM_USER\}/$(kiosk_urlencode "$CAM_USER")}"
    url="${url//\$\{CAM_PASS\}/$(kiosk_urlencode "$CAM_PASS")}"
    printf '%s' "$url"
}

# ---------------------------------------------------------------------------
# kiosk_load_display — read display.conf (or the legacy one-line format)
# ---------------------------------------------------------------------------
# display.conf, written by kiosk-menu:
#   MODE=pair|single|web     ROTATION=H|V
#   TOP=2  BOTTOM=1          (sheets; single uses BOTTOM)
#   WEB=1                    (which WEB_URL)
kiosk_load_display() {
    MODE=""; ROTATION="H"; TOP=0; BOTTOM=0; WEB=0
    [ -r "$KIOSK_ETC/display.conf" ] || return 1
    local key val
    while IFS='=' read -r key val || [ -n "$key" ]; do
        val="${val%$'\r'}"
        case "$key" in
            MODE)     [[ "$val" =~ ^(pair|single|web)$ ]] && MODE=$val;;
            ROTATION) [[ "$val" =~ ^[HV]$ ]] && ROTATION=$val;;
            TOP)      [[ "$val" =~ ^[0-9]+$ ]] && TOP=$((10#$val));;
            BOTTOM)   [[ "$val" =~ ^[0-9]+$ ]] && BOTTOM=$((10#$val));;
            WEB)      [[ "$val" =~ ^[0-9]+$ ]] && WEB=$((10#$val));;
        esac
    done < "$KIOSK_ETC/display.conf"
    [ -n "$MODE" ]
}

# The v10 Pis kept one line in ~/kiosk.config: rotation, mode letter,
# bottom sheet, top sheet — "HC0102", "HS0303", "VK01". Prints the
# display.conf equivalent, or fails if the line is not recognised.
kiosk_convert_legacy() {
    local line="$1"
    line="${line%%[[:space:]]*}"
    [[ "$line" =~ ^([HV])([CSK])([0-9]{2})([0-9]{2})?$ ]] || return 1
    local rot=${BASH_REMATCH[1]} m=${BASH_REMATCH[2]} a=$((10#${BASH_REMATCH[3]})) b=${BASH_REMATCH[4]}
    echo "ROTATION=$rot"
    case "$m" in
        C) echo "MODE=pair"; echo "BOTTOM=$a"; echo "TOP=$((10#${b:-0}))";;
        S) echo "MODE=single"; echo "BOTTOM=$a";;
        K) echo "MODE=web"; echo "WEB=$a";;
    esac
}

# ---------------------------------------------------------------------------
# kiosk_pairs — the sheet pairs offered by the menu: "1 2", "3 4", ...
# An odd last sheet is offered on its own row in single mode only.
# ---------------------------------------------------------------------------
kiosk_pairs() {
    local n
    for ((n = 1; n + 1 <= SHEETS; n += 2)); do echo "$n $((n + 1))"; done
}

# Two-digit sheet number, as the menu tags use.
kiosk_2d() { printf '%02d' "$1"; }
