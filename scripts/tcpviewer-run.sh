#!/usr/bin/env bash
# Launch Omarchy TCPViewer: make sure tcpviewerd is running, then start the GUI.
# Safe for desktop launchers and Hyprland keybindings (no terminal, no eval).
set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
ROOT="$(cd -P "$(dirname "$SOURCE")/.." && pwd)"

APP="$ROOT/app/build/omarchy-tcpviewer"
DAEMON="$ROOT/daemon/.build/debug/tcpviewerd"
CLI="$ROOT/daemon/.build/debug/tcpviewer-cli"

if [[ ! -x "$APP" ]]; then
    printf 'omarchy-tcpviewer: build the app first (%s missing)\n' "$APP" >&2
    exit 1
fi
if [[ ! -x "$DAEMON" ]]; then
    printf 'omarchy-tcpviewer: build the daemon first (%s missing)\n' "$DAEMON" >&2
    exit 1
fi

# Start the daemon when it is not already answering on the IPC socket.
if ! "$CLI" app status >/dev/null 2>&1; then
    nohup "$DAEMON" >/dev/null 2>&1 &
    for _ in {1..30}; do
        "$CLI" app status >/dev/null 2>&1 && break
        sleep 0.1
    done
fi

exec "$APP" "$@"
