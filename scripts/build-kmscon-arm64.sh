#!/usr/bin/env bash
# Build kmscon v9.0.0 from source on 64-bit Debian (arm64) for a Pi 4.
#
# WHY: kmscon is not packaged in every distribution or for every architecture,
# so where apt cannot supply it we compile it locally instead. Availability
# genuinely varies - Raspberry Pi OS (armhf) has it, Debian bookworm arm64 has
# it (9.0.0-4), Debian trixie has it only in trixie-backports and not in main.
# Do not assume from the board name: ASK APT, which is what install.sh does.
#     apt-cache policy kmscon      # Candidate: (none)  ->  build from source
# On a machine with no candidate, "apt-get source kmscon" will not help either
# unless the sources.list carries a matching deb-src line.
#
# WHY v9.0.0 AND NOT HEAD: Debian trixie ships libtsm 4.0.2; v9.1.0 requires
# >=4.1.0 and will not configure. v9.0.0 is also the exact version the armhf
# package provides, so both consoles end up on identical behaviour.
# Version-matching the working host is the point - do not chase the newer tag.
set -euo pipefail

KMSCON_TAG=v9.0.0
SRC=${SRC:-$HOME/src}

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }

apt-get update
apt-get install -y build-essential meson ninja-build pkg-config \
  libudev-dev libxkbcommon-dev libdrm-dev libgbm-dev libegl-dev \
  libgles2-mesa-dev libpango1.0-dev libtsm-dev libsystemd-dev \
  libpixman-1-dev git tmux fontconfig

mkdir -p "$SRC" && cd "$SRC"
[ -d kmscon ] || git clone --depth 1 --branch "$KMSCON_TAG" https://github.com/Aetf/kmscon.git
cd kmscon

meson setup build --prefix=/usr 2>&1 | tee /tmp/kmscon-meson.log

# The pango engine is what font-engine=pango in kmscon.conf needs. Without it
# the Nerd Font silently never renders and you are back to tofu boxes.
if ! grep -qE 'font_pango\s*:\s*true' /tmp/kmscon-meson.log; then
    echo "FATAL: meson summary does not show 'font_pango : true'." >&2
    echo "Install libpango1.0-dev and re-run." >&2
    exit 1
fi
echo "OK: font_pango : true"

ninja -C build
ninja -C build install

# GOTCHA: --prefix=/usr installs the systemd units under a MULTIARCH path that
# systemd does not scan. Symptom: "systemctl cat kmsconvt@tty1" prints NOTHING
# and your drop-in appears to do nothing - easily misread as a bad drop-in.
MA=$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo aarch64-linux-gnu)
for u in kmscon.service kmsconvt@.service; do
    if [ -f "/usr/lib/$MA/systemd/system/$u" ]; then
        cp -v "/usr/lib/$MA/systemd/system/$u" /usr/lib/systemd/system/
    fi
done
systemctl daemon-reload

# systemctl cat is the proof a unit exists - not ls.
if systemctl cat kmsconvt@tty1 2>/dev/null | grep -q ExecStart; then
    echo "OK: systemd resolves kmsconvt@tty1"
else
    echo "FATAL: systemd still cannot see kmsconvt@.service" >&2
    exit 1
fi

echo
echo "Built and installed kmscon $KMSCON_TAG."
echo "Next: install the Nerd Font, kmscon.conf, the autologin drop-in,"
echo "and (Pi 4) the 61-kmscon-v3d-offseat.rules udev rule."
