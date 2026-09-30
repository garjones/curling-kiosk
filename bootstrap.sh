#!/bin/bash
# bootstrap.sh — a Raspberry Pi to a running club kiosk, over SSH, in one line.
#
#   curl -fsSL https://raw.githubusercontent.com/garjones/curling-kiosk/main/bootstrap.sh \
#     | sudo bash -s -- --club <owner>/<site-repo>
#
# Run it in an SSH session as the Pi's login user (that user runs the
# display). It asks for ONE thing: the club machine key, an SSH private
# key kept in the club's password manager. That key reads the club's
# private site repo and decrypts the camera login; everything else comes
# from this public repo. Re-running it is also the upgrade path.
#
#   --club owner/repo   the club's private site repo on GitHub (required)
#   --user NAME         the Pi's login user (default: whoever ran sudo)
#   --key-file PATH     the machine key, instead of pasting it
#   --branch NAME       product branch to install (default main)
#
# Raspberry Pi OS with desktop (Bookworm or later). Idempotent.

set -eu

PRODUCT_REPO="${PRODUCT_REPO:-https://github.com/garjones/curling-kiosk.git}"
PRODUCT_DIR=/opt/curling-kiosk
CLUB_DIR=/opt/curling-club
ETC=/etc/kiosk
KEY="$ETC/machine.key"
BRANCH=main
CLUB=""
KUSER="${SUDO_USER:-}"
KEYFILE=""

die() { echo "bootstrap: $*" >&2; exit 1; }
usage() { sed -n '2,18p' "$0" 2>/dev/null >&2 || true; die "usage: ... | sudo bash -s -- --club owner/repo"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --club)     CLUB=$2; shift 2;;
        --user)     KUSER=$2; shift 2;;
        --key-file) KEYFILE=$2; shift 2;;
        --branch)   BRANCH=$2; shift 2;;
        *)          usage;;
    esac
done
[ -n "$CLUB" ] || usage
case "$CLUB" in */*) ;; *) die "--club must be owner/repo, e.g. garjones/curling-kcc";; esac
[ "$(id -u)" = 0 ] || die "run with sudo"
[ -n "$KUSER" ] && [ "$KUSER" != root ] || die "run it as the Pi's login user with sudo, or pass --user NAME"
command -v apt-get >/dev/null 2>&1 || die "this installer is for Raspberry Pi OS / Debian"

echo "== packages"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    git age ffmpeg unclutter whiptail curl ca-certificates openssh-client
command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1 ||
    echo "WARNING: no Chromium found — web pages need the full Raspberry Pi OS desktop image"

echo "== kiosk software: $PRODUCT_REPO ($BRANCH) -> $PRODUCT_DIR"
if [ -d "$PRODUCT_DIR/.git" ]; then
    git -C "$PRODUCT_DIR" fetch -q origin "$BRANCH"
    git -C "$PRODUCT_DIR" checkout -q "$BRANCH"
    git -C "$PRODUCT_DIR" pull -q --ff-only origin "$BRANCH"
else
    git clone -q -b "$BRANCH" "$PRODUCT_REPO" "$PRODUCT_DIR" ||
        die "could not clone $PRODUCT_REPO — the product repo must be public"
fi

echo "== club machine key"
install -d -m 755 "$ETC"
if [ ! -f "$KEY" ]; then
    if [ -n "$KEYFILE" ]; then
        install -m 600 "$KEYFILE" "$KEY"
    else
        [ -r /dev/tty ] || die "no terminal to paste the key on — use --key-file PATH"
        printf '\nPaste the club machine key from the password manager\n' > /dev/tty
        printf '(the whole block, -----BEGIN ... -----END), then press Enter:\n\n' > /dev/tty
        umask 077
        : > "$KEY"
        while IFS= read -r line; do
            printf '%s\n' "$line" >> "$KEY"
            case "$line" in *-----END*) break;; esac
        done < /dev/tty
        umask 022
    fi
    if ! ssh-keygen -y -f "$KEY" >/dev/null 2>&1; then
        rm -f "$KEY"
        die "that is not a usable private key — nothing was saved; run again"
    fi
    echo "machine key saved at $KEY (readable by root only)"
else
    echo "machine key already at $KEY"
fi

echo "== club settings: $CLUB -> $CLUB_DIR"
SSH_CMD="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
if [ -d "$CLUB_DIR/.git" ]; then
    git -C "$CLUB_DIR" pull -q --ff-only
else
    GIT_SSH_COMMAND="$SSH_CMD" git clone -q "git@github.com:$CLUB.git" "$CLUB_DIR" ||
        die "could not clone git@github.com:$CLUB.git — is the machine key a deploy key on that repo?"
    git -C "$CLUB_DIR" config core.sshCommand "$SSH_CMD"   # so kiosk-update's git pull works
fi

echo "== apply"
"$PRODUCT_DIR/bin/kiosk-deploy" "$CLUB_DIR" --user "$KUSER"

cat <<DONE

== done. Reboot to start the display:   sudo reboot
   Then log in again over SSH: the kiosk menu opens and you choose what
   this screen shows. Later updates: menu > Software update.
DONE
