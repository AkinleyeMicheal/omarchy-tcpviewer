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
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -a "Omarchy TCPViewer" -t 8000 \
            "Omarchy TCPViewer is not built yet" \
            "Inside the plugin clone run:\ncd daemon && swift build\ncmake -S app -B app/build -G Ninja && cmake --build app/build" || true
    fi
    exit 1
fi
if [[ ! -x "$DAEMON" ]]; then
    printf 'omarchy-tcpviewer: build the daemon first (%s missing)\n' "$DAEMON" >&2
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -a "Omarchy TCPViewer" -t 8000 \
            "tcpviewerd is not built yet" \
            "Inside the plugin clone run:\ncd daemon && swift build" || true
    fi
    exit 1
fi

# Live capture needs file capabilities; relinking drops them. Try to grant
# them automatically: the passwordless root helper installed by
# setup-capture-helper.sh, then a desktop password dialog via pkexec, then
# cached sudo; if all of that is unavailable, notify-send surfaces the exact
# one-time setup command. File viewing works without.
"$ROOT/scripts/grant-capture-caps.sh" "$DAEMON" || true

# File capabilities only apply when a process starts. A daemon left over from
# before a grant keeps running without them, so restart those instances.
"$ROOT/scripts/restart-stale-daemons.sh" "$DAEMON"

# Start the daemon when it is not already answering on the IPC socket. Keep a
# small log so failures are diagnosable when launched from a keybinding.
if ! "$CLI" app status >/dev/null 2>&1; then
    STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-tcpviewer"
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR" 2>/dev/null || true
    DAEMON_LOG="$STATE_DIR/daemon.log"
    if [[ -f "$DAEMON_LOG" ]] && (( $(stat -c%s "$DAEMON_LOG" 2>/dev/null || echo 0) > 1048576 )); then
        mv -f "$DAEMON_LOG" "$DAEMON_LOG.1"
    fi
    ( umask 077; touch "$DAEMON_LOG" )
    chmod 600 "$DAEMON_LOG" 2>/dev/null || true
    nohup "$DAEMON" >>"$DAEMON_LOG" 2>&1 &
    for _ in {1..30}; do
        "$CLI" app status >/dev/null 2>&1 && break
        sleep 0.1
    done
fi

exec "$APP" "$@"
