#!/usr/bin/env bash
# Verify a kmscon TUI console BEFORE rebooting. Run on the Pi.
#
# Every check here exists because its absence produced a console that looked
# fine from SSH and was dead on the actual screen.
FONT=${FONT:-"CaskaydiaCove Nerd Font Mono"}
LAUNCHER=${LAUNCHER:-"$HOME/assistant-tui.sh"}
fail=0
chk() { # chk <label> <ok-condition-output> ...
  printf '%-46s' "$1"
  shift
  if "$@" >/dev/null 2>&1; then echo "PASS"; else echo "FAIL"; fail=$((fail+1)); fi
}

echo "== kmscon console preflight =="

chk "1  kmscon binary present"            test -x /usr/bin/kmscon
chk "2  font RESOLVES (not just present)" bash -c "fc-match \"$FONT\" | grep -qiE 'nerd ?font'"
chk "3  kmscon.conf uses pango engine"    grep -q '^font-engine=pango' /etc/kmscon/kmscon.conf
chk "4  tmux installed"                   command -v tmux
chk "5  launcher executable"              test -x "$LAUNCHER"
chk "6  bashrc hook present exactly once" bash -c "[ \"\$(grep -c \"$(basename "$LAUNCHER")\" ~/.bashrc)\" = 1 ]"
chk "6b .bash_profile does NOT exist"     bash -c "! test -e ~/.bash_profile"
chk "7  systemd RESOLVES the unit"        bash -c "systemctl cat kmsconvt@tty1 | grep -q ExecStart"
# 8: only meaningful where card0 is the RENDER-ONLY V3D node (Pi 4). On a
# single-card board card0 IS the display controller and belongs on seat0 - do
# not "fix" that. The card1-HDMI-A-* connector entries under /sys/class/drm/
# are the authoritative tell for which card owns the outputs.
printf '%-46s' "8  render-only V3D node off seat0"
if [ "$(udevadm info -q property -n /dev/dri/card0 2>/dev/null | grep -c 'ID_PATH=platform-fec00000.v3d')" -eq 0 ]; then
    echo "SKIP (card0 is not the V3D node)"
elif loginctl seat-status seat0 2>/dev/null | grep -q 'drm:card0'; then
    echo "FAIL (render-only card0 still on seat0)"; fail=$((fail+1))
else
    echo "PASS"
fi
chk "9  tty1 owned by kmscon not getty"   bash -c "[ \"\$(systemctl is-enabled kmsconvt@tty1)\" = enabled ] && [ \"\$(systemctl is-enabled getty@tty1)\" = disabled ]"

# 10: the decisive probe. systemctl is-active returning 'active' proves NOTHING:
# kmscon can start, take the VT, spawn the login shell (so SSH and tmux look
# perfectly healthy) and never open a DRM device at all - drawing to nothing
# while the kernel framebuffer's last text stays frozen on screen.
#
# Read /proc/PID/fd directly rather than parsing lsof. lsof can return nothing
# useful for a root-owned process depending on how it was invoked (seen for
# real over sudo-on-SSH), which reports a PERFECTLY HEALTHY console as 0 fds -
# a false alarm that mimics the exact failure this check exists to catch.
# The /proc symlinks are the authoritative source.
printf '%-46s' "10 kmscon holds video fds"
PID=$(pgrep -f 'kmscon --vt=tty1' | head -1)
if [ -z "$PID" ]; then
    echo "SKIP (not running yet)"
else
    # NB: the glob must expand INSIDE the privileged shell. Writing
    # `sudo readlink /proc/$PID/fd/*` expands it as the calling user first,
    # who cannot read that root-owned dir, so it silently yields nothing and
    # reports a healthy console as FAIL.
    CARDS=$(sudo sh -c "readlink /proc/$PID/fd/* 2>/dev/null" | grep -E '^/dev/(dri|fb)' | sort -u)
    if [ -n "$CARDS" ]; then
        echo "PASS ($(echo "$CARDS" | paste -sd, -))"
    else
        echo "FAIL (0 == drawing to NOTHING)"; fail=$((fail+1))
    fi
fi

# 11: kmsconvt@.service ships OnFailure=getty@%i.service. A plain login prompt
# with a blinking cursor on the console means kmscon CRASHED and agetty replaced
# it. That prompt is a failure indicator, not a success one.
chk "11 fallback getty NOT active"        bash -c "[ \"\$(systemctl is-active getty@tty1)\" != active ]"

# 12: geometry is itself a health signal. 80x23 is the kernel framebuffer
# default - i.e. nobody took over the display. Native panel res = it worked.
printf '%-46s' "12 tmux client geometry"
G=$(tmux list-clients -F '#{client_width}x#{client_height}' 2>/dev/null | head -1)
case "${G:-none}" in
    none)  echo "SKIP (no tmux client)" ;;
    80x23) echo "FAIL ($G = raw framebuffer default)"; fail=$((fail+1)) ;;
    *)     echo "PASS ($G)" ;;
esac

echo
[ "$fail" -eq 0 ] && echo "ALL CHECKS PASSED" || echo "$fail CHECK(S) FAILED"
exit "$fail"
