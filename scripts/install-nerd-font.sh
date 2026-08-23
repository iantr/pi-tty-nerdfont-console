#!/usr/bin/env bash
# Install a Nerd Font system-wide for kmscon and VERIFY IT RESOLVES.
#
# The most common way to get this wrong is to copy a .ttf into place, see the
# file on disk, and assume it works. If fontconfig does not match it, kmscon
# silently falls back to something else and the console looks subtly wrong.
# FILE EXISTS != FONT RESOLVES. fc-match is the proof.
set -euo pipefail

FONT_ZIP_URL=${FONT_ZIP_URL:-https://github.com/ryanoasis/nerd-fonts/releases/latest/download/CascadiaCode.zip}
FONT_NAME=${FONT_NAME:-"CaskaydiaCove Nerd Font Mono"}
DEST=/usr/local/share/fonts/nerd-fonts

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }

command -v fc-cache >/dev/null || apt-get install -y fontconfig
command -v unzip    >/dev/null || apt-get install -y unzip
command -v wget     >/dev/null || apt-get install -y wget

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
wget -q -O "$TMP/font.zip" "$FONT_ZIP_URL"
unzip -q "$TMP/font.zip" -d "$TMP/font"

mkdir -p "$DEST"
find "$TMP/font" -name '*Mono*.ttf' -exec install -m644 -o root -g root {} "$DEST/" \;
# fall back to all ttf if the Mono filter matched nothing
if ! ls "$DEST"/*.ttf >/dev/null 2>&1; then
    find "$TMP/font" -name '*.ttf' -exec install -m644 -o root -g root {} "$DEST/" \;
fi
chmod 755 "$DEST"
fc-cache -f >/dev/null

MATCH=$(fc-match "$FONT_NAME")
echo "fc-match \"$FONT_NAME\" -> $MATCH"
case "$MATCH" in
    *NerdFont*|*"Nerd Font"*) echo "OK: font resolves." ;;
    *) echo "FATAL: fontconfig did NOT find the font (fell back above)." >&2; exit 1 ;;
esac
