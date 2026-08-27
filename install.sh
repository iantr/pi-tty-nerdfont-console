#!/usr/bin/env bash
# install.sh - one-shot installer for a kmscon Nerd Font console on a Pi.
#
# Orchestrates the scripts in scripts/ and the files in configs/. It does not
# duplicate them: every real step still lives in the script that documents it,
# so there is one place to fix a bug.
#
# DESIGN NOTE - why this decides by EVIDENCE, not by board name:
# the board model gates *support* (see check_board below), but every actual
# branch is taken by probing the machine: does apt offer kmscon? is card0 the
# render-only V3D node? Two boards with the same name can differ by OS, arch
# and kernel, and a name-based branch silently does the wrong thing when they
# do. The model check exists to say "I have not tested this here", which is a
# different question from "what does this machine need".
#
# Usage:
#   sudo bash install.sh                 # interactive
#   sudo bash install.sh --user pi       # set the autologin account
#   sudo bash install.sh --font-size 14
#   sudo bash install.sh --force         # proceed on an untested board
#   sudo bash install.sh --dry-run       # print the plan, change nothing
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONSOLE_USER=""
FONT_SIZE=""
FORCE=0
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --user)      CONSOLE_USER=${2:?--user needs a value}; shift 2 ;;
        --font-size) FONT_SIZE=${2:?--font-size needs a value}; shift 2 ;;
        --force)     FORCE=1; shift ;;
        --dry-run)   DRY_RUN=1; shift ;;
        -h|--help)   sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '\033[33m   WARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m   FATAL: %s\033[0m\n' "$*" >&2; exit 1; }
run()  {
    if [ "$DRY_RUN" -eq 1 ]; then printf '   [dry-run] %s\n' "$*"; return 0; fi
    "$@"
}

[ "$(id -u)" -eq 0 ] || die "run with sudo:  sudo bash install.sh"

# ---------------------------------------------------------------- board gate
# /proc/device-tree/model is the authoritative model string and is NUL-
# terminated, hence the tr. /proc/cpuinfo "Model" is derived from the same
# place but is absent on some kernels, so it is only a fallback.
detect_model() {
    if [ -r /proc/device-tree/model ]; then
        tr -d '\0' < /proc/device-tree/model
    elif grep -q '^Model' /proc/cpuinfo 2>/dev/null; then
        grep '^Model' /proc/cpuinfo | head -1 | cut -d: -f2- | sed 's/^ *//'
    else
        echo "unknown"
    fi
}

check_board() {
    MODEL=$(detect_model)
    info "Model:        $MODEL"
    info "Architecture: $(dpkg --print-architecture 2>/dev/null || uname -m)"
    info "OS:           $( . /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo unknown )"

    case "$MODEL" in
        *"Raspberry Pi Zero 2"*)
            BOARD=pi-zero; DEFAULT_FONT_SIZE=12
            info "Board is TESTED with this project." ;;
        # Must be "Pi 4 Model B", not a bare "Pi 4" prefix - the latter also
        # matches "Raspberry Pi 400", a different board this was never run on.
        *"Raspberry Pi 4 Model B"*)
            BOARD=pi-4;    DEFAULT_FONT_SIZE=14
            info "Board is TESTED with this project." ;;
        *"Raspberry Pi"*)
            BOARD=untested; DEFAULT_FONT_SIZE=14
            warn "This project has only been built and tested on the Raspberry Pi"
            warn "Zero 2 W and the Raspberry Pi 4. Yours is:"
            warn "    $MODEL"
            warn "Newer boards (the Pi 5 in particular) restructure the display"
            warn "path, so the DRM device layout this installer probes for may"
            warn "not match. Nothing here is destructive, and preflight.sh will"
            warn "tell you what actually happened - but you are past the tested"
            warn "ground and may need to adapt the udev rule yourself." ;;
        *)
            BOARD=unknown; DEFAULT_FONT_SIZE=14
            warn "This does not look like a Raspberry Pi at all:"
            warn "    $MODEL"
            warn "kmscon itself is not Pi-specific and may well work, but every"
            warn "board-specific workaround in this repo was written for a Pi." ;;
    esac

    if [ "$BOARD" = untested ] || [ "$BOARD" = unknown ]; then
        if [ "$FORCE" -eq 1 ]; then
            warn "--force given, continuing anyway."
        elif [ -t 0 ]; then
            printf '\n   Continue anyway? [y/N] '
            read -r reply
            case "$reply" in [yY]*) ;; *) die "stopped at your request." ;; esac
        else
            die "untested board and no TTY to ask. Re-run with --force if you mean it."
        fi
    fi
}

say "Checking the board"
check_board

[ -n "$FONT_SIZE" ] || FONT_SIZE=$DEFAULT_FONT_SIZE

# ------------------------------------------------------------------ the user
# The autologin account must be a real user - agetty --autologin fails at boot
# otherwise, and the console dies with nothing on screen to say why.
if [ -z "$CONSOLE_USER" ]; then
    CONSOLE_USER=${SUDO_USER:-}
    [ -n "$CONSOLE_USER" ] || CONSOLE_USER=$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd)
fi
[ -n "$CONSOLE_USER" ] || die "could not work out which user to autologin. Pass --user NAME."
id "$CONSOLE_USER" >/dev/null 2>&1 || die "user '$CONSOLE_USER' does not exist. Pass --user NAME."
USER_HOME=$(getent passwd "$CONSOLE_USER" | cut -d: -f6)
[ -d "$USER_HOME" ] || die "home directory for '$CONSOLE_USER' not found."
info "Autologin user: $CONSOLE_USER  (home: $USER_HOME)"
info "Font size:      $FONT_SIZE"

# -------------------------------------------------------------------- kmscon
# EVIDENCE, not board name: ask apt whether it has a candidate. On Raspberry Pi
# OS armhf it does; on Debian arm64 it does not and we build from source.
say "Installing kmscon"
if command -v kmscon >/dev/null 2>&1; then
    info "kmscon already present at $(command -v kmscon) - skipping."
elif apt-cache policy kmscon 2>/dev/null | grep -q 'Candidate: [0-9]'; then
    info "apt has a kmscon package - installing it."
    run apt-get update
    run apt-get install -y kmscon tmux fontconfig
else
    info "No kmscon package available here - compiling it locally instead."
    info "(this takes a few minutes)"
    run bash "$REPO_DIR/scripts/build-kmscon-arm64.sh"
fi

say "Installing the Nerd Font"
run bash "$REPO_DIR/scripts/install-nerd-font.sh"

# ---------------------------------------------------------------- the config
say "Writing configuration"
run install -d -m755 /etc/kmscon
if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] write /etc/kmscon/kmscon.conf with font-size=$FONT_SIZE"
else
    sed "s/^font-size=.*/font-size=$FONT_SIZE/" \
        "$REPO_DIR/configs/kmscon.conf" > /etc/kmscon/kmscon.conf
    chmod 644 /etc/kmscon/kmscon.conf
fi
info "/etc/kmscon/kmscon.conf   (font-size=$FONT_SIZE)"

run install -d -m755 /etc/systemd/system/kmsconvt@tty1.service.d
if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] write autologin drop-in with --autologin $CONSOLE_USER"
else
    sed "s/--autologin [A-Za-z0-9_.-]*/--autologin $CONSOLE_USER/" \
        "$REPO_DIR/configs/autologin.conf" \
        > /etc/systemd/system/kmsconvt@tty1.service.d/autologin.conf
    chmod 644 /etc/systemd/system/kmsconvt@tty1.service.d/autologin.conf
fi
info "autologin drop-in          (--autologin $CONSOLE_USER)"

# Resilience drop-in: kmscon v9.0.0 occasionally segfaults just after start, and
# the stock unit has no Restart= (only OnFailure=getty), so one crash silently
# demotes the console to a plain VT for good. See configs/resilience.conf.
run install -m644 "$REPO_DIR/configs/resilience.conf" \
    /etc/systemd/system/kmsconvt@tty1.service.d/resilience.conf
info "resilience drop-in         (Restart=always - survives a transient SEGV)"


# tmux.conf and the launcher belong to the user, not to root.
run install -m644 -o "$CONSOLE_USER" -g "$CONSOLE_USER" \
    "$REPO_DIR/configs/tmux.conf" "$USER_HOME/.tmux.conf"
info "$USER_HOME/.tmux.conf"

if [ -e "$USER_HOME/assistant-tui.sh" ]; then
    info "$USER_HOME/assistant-tui.sh already exists - left untouched."
else
    run install -m755 -o "$CONSOLE_USER" -g "$CONSOLE_USER" \
        "$REPO_DIR/scripts/assistant-tui.sh" "$USER_HOME/assistant-tui.sh"
    info "$USER_HOME/assistant-tui.sh   <- EDIT THIS to run your own TUI"
fi

# The hook must appear EXACTLY ONCE. Re-running the installer otherwise stacks
# duplicates in .bashrc, and preflight check 6 fails on a system that is
# otherwise fine.
if grep -q 'assistant-tui.sh' "$USER_HOME/.bashrc" 2>/dev/null; then
    info ".bashrc hook already present - not appending again."
else
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[dry-run] append configs/bashrc-hook.sh to $USER_HOME/.bashrc"
    else
        cat "$REPO_DIR/configs/bashrc-hook.sh" >> "$USER_HOME/.bashrc"
    fi
    info "appended console hook to $USER_HOME/.bashrc"
fi

# A ~/.bash_profile shadows ~/.profile, so the hook never runs and the console
# comes up as a bare prompt. Cheap to detect, baffling to debug.
if [ -e "$USER_HOME/.bash_profile" ]; then
    warn "$USER_HOME/.bash_profile exists. Bash reads it INSTEAD of ~/.profile,"
    warn "so the console hook will never run. Move it aside or source ~/.bashrc"
    warn "from it."
fi

# ------------------------------------------------------------------ dual-DRM
# Evidence-based: install the seat rule only where card0 really is the
# render-only V3D node. On a single-card board card0 IS the display controller
# and moving it off seat0 would break a working console.
say "Checking the DRM layout"
if [ -e /dev/dri/card0 ] \
   && udevadm info -q property -n /dev/dri/card0 2>/dev/null \
      | grep -q 'ID_PATH=platform-fec00000.v3d'; then
    info "card0 is the render-only V3D node - kmscon would grab it and hang."
    info "Installing the udev seat rule."
    run install -m644 "$REPO_DIR/configs/61-kmscon-v3d-offseat.rules" /etc/udev/rules.d/
    run udevadm control --reload-rules
    run udevadm trigger --subsystem-match=drm --action=change
else
    info "card0 is not the V3D render node - seat rule not needed here."
    if [ "$BOARD" = untested ] || [ "$BOARD" = unknown ]; then
        warn "On an untested board this check is not proof the layout is fine -"
        warn "it only means it does not match the Pi 4's. If kmscon starts but"
        warn "the screen never changes, inspect /sys/class/drm/ to see which"
        warn "card owns the HDMI connectors."
    fi
fi

# ---------------------------------------------------------------- switch tty1
say "Handing tty1 to kmscon"
run systemctl daemon-reload
run systemctl disable getty@tty1.service
run systemctl enable kmsconvt@tty1.service
info "getty@tty1 disabled, kmsconvt@tty1 enabled."

# ------------------------------------------------------------------ preflight
say "Preflight"
if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would run scripts/preflight.sh as $CONSOLE_USER"
    exit 0
fi

# preflight checks ~/.bashrc and ~/assistant-tui.sh, so it has to run as the
# console user, not as root.
set +e
sudo -u "$CONSOLE_USER" \
    LAUNCHER="$USER_HOME/assistant-tui.sh" \
    bash "$REPO_DIR/scripts/preflight.sh"
PREFLIGHT_RC=$?
set -e

echo
if [ "$PREFLIGHT_RC" -eq 0 ]; then
    say "Done - preflight passed"
    echo "   Edit $USER_HOME/assistant-tui.sh to run whatever you want on screen,"
    echo "   then reboot:   sudo reboot"
else
    say "Done - but preflight reported problems"
    echo "   Fix the FAIL lines above before rebooting. A failed preflight"
    echo "   usually means the console will come up blank, which is far more"
    echo "   annoying to debug from the far side of a reboot."
fi
echo
echo "   Checks that only mean anything once it is running (kmscon holding"
echo "   video fds, the 152x50 geometry) are expected to SKIP right now."
exit "$PREFLIGHT_RC"
