# --- console TUI auto-launch: append to ~/.bashrc -------------------------
#
# Do NOT test against a hardcoded pty (e.g. [ "$(tty)" = "/dev/pts/0" ]).
# kmscon's login shell gets whatever pty is free: the FIRST login after boot
# gets pts/0 and works, every restart after that lands on pts/1, pts/2... the
# test fails, the shell falls through to an interactive prompt, exits, and the
# console dies. That is why "it worked when I built it" and "it's frozen at
# boot" are both true of the same machine.
#
# Key off the logind seat instead - SSH sessions have no XDG_SEAT - and use
# new-session -A so a restart re-attaches instead of failing on the existing
# session.
#
# WARNING: the console shell is a LOGIN shell. Debian's chain is
# .profile -> sources .bashrc. Bash reads ~/.bash_profile IN PREFERENCE TO
# .profile, so creating even an EMPTY ~/.bash_profile silently breaks this
# chain and the hook never runs.

if [ -z "${TMUX:-}" ] && [ -z "${SSH_CONNECTION:-}" ] && [ -n "${XDG_SEAT:-}" ]; then
    export TMUX_SYSTEMD=0
    exec tmux -f ~/.tmux.conf new-session -A -s main ~/assistant-tui.sh
fi

# Idle blanking (no sudo needed). setterm only affects the current terminal,
# hence putting it here. 2>/dev/null keeps it quiet when sourced over SSH.
setterm --blank 10 --powerdown 15 2>/dev/null
