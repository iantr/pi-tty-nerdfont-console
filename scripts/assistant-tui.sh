#!/usr/bin/env bash
# ~/assistant-tui.sh - what the console actually runs.
#
# Connects to a self-hosted AI assistant's terminal UI on another host and
# reconnects automatically if the link drops. Replace the ssh line with
# whatever TUI you want on screen (btop, k9s, a local assistant binary...).
export TERM=xterm-256color
clear
while true; do
    echo "Connecting..."
    ssh -tt assistant-host "/path/to/your/assistant --tui"
    EXIT_CODE=$?
    echo
    echo "Connection lost (exit code: $EXIT_CODE). Reconnecting in 5 seconds..."
    echo "Press Ctrl+C to stop."
    sleep 5
    clear
done
