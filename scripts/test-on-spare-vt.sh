#!/usr/bin/env bash
# Exercise the REAL unit on tty4 instead of risking the live console on tty1.
#
# PITFALL THAT COSTS A FULL CYCLE: the drop-in lives in kmsconvt@tty1.service.d,
# i.e. TTY1 ONLY. Starting kmsconvt@tty4 without copying it runs the STOCK
# ExecStart, reproduces the original error, and convinces you your fix failed.
# Always confirm the running process's actual argv matches what you are testing.
#
# PITFALL 2: a BACKGROUND VT never spawns its login, so a tty4 test shows no
# children and no DRM fds EVEN WHEN CORRECT. You must foreground it to make the
# test meaningful - that is what makes broken and working look identical.
#
# PITFALL 3: do NOT tear down with `pkill -f 'kmscon --vt=tty4'` typed at a
# shell - the pattern matches the command string carrying it and kills your own
# SSH session. Use systemctl, as below.
set -euo pipefail
VT=${VT:-4}
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }

case "${1:-start}" in
start)
    mkdir -p "/etc/systemd/system/kmsconvt@tty$VT.service.d"
    cp -v /etc/systemd/system/kmsconvt@tty1.service.d/autologin.conf \
          "/etc/systemd/system/kmsconvt@tty$VT.service.d/"
    systemctl daemon-reload
    systemctl start "kmsconvt@tty$VT.service"
    sleep 6
    echo "--- is-active ---";  systemctl is-active "kmsconvt@tty$VT"
    echo "--- actual argv (confirm YOUR flags are here) ---"
    ps aux | grep "[k]mscon --vt=tty$VT" || echo "(not running)"
    echo "--- journal ---"
    journalctl -u "kmsconvt@tty$VT" --since -1min --no-pager -o cat
    echo
    echo "Now FOREGROUND it to make the test meaningful:  sudo chvt $VT"
    echo "(a background VT never spawns its login - it will look dead either way)"
    echo "Then from SSH, count video fds:"
    echo "  sudo lsof -p \$(pgrep -f 'kmscon --vt=tty$VT'|head -1) | grep -cE '/dev/dri|/dev/fb'"
    echo "  0 == drawing to NOTHING. Healthy == non-zero."
    ;;
stop)
    systemctl stop "kmsconvt@tty$VT.service" || true
    rm -rf "/etc/systemd/system/kmsconvt@tty$VT.service.d"
    systemctl daemon-reload
    echo "torn down tty$VT"
    ;;
*) echo "usage: $0 [start|stop]" >&2; exit 1 ;;
esac
