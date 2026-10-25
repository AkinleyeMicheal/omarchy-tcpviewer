#!/usr/bin/env bash
# Quick capture control for the Omarchy shell panel and keybindings.
#
#   quick-capture.sh start   Ensure tcpviewerd is answering, then start live
#                            capture on the default-route interface.
#   quick-capture.sh stop    Stop the active capture (keeps the daemon running
#                            for file work and the viewer app).
#   quick-capture.sh status  Print one line: "capturing", "idle", or "offline".
#
# Safe for execDetached and Hyprland keybindings: no terminal, no eval;
# user feedback goes through notify-send, exits are quiet.
set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
ROOT="$(cd -P "$(dirname "$SOURCE")/.." && pwd)"

DAEMON="$ROOT/daemon/.build/debug/tcpviewerd"
CLI="$ROOT/daemon/.build/debug/tcpviewer-cli"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-tcpviewer"
DAEMON_LOG="$STATE_DIR/daemon.log"

notify() {
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -a "Omarchy TCPViewer" -t 6000 "$1" "${2:-}" || true
    fi
}

ensure_daemon() {
    if "$CLI" app status >/dev/null 2>&1; then
        return 0
    fi
    if [[ ! -x "$DAEMON" ]]; then
        notify "tcpviewerd is not built" "Build it: cd $ROOT/daemon && swift build"
        return 1
    fi
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR" 2>/dev/null || true
    if [[ -f "$DAEMON_LOG" ]] && (( $(stat -c%s "$DAEMON_LOG" 2>/dev/null || echo 0) > 1048576 )); then
        mv -f "$DAEMON_LOG" "$DAEMON_LOG.1"
    fi
    ( umask 077; touch "$DAEMON_LOG" )
    chmod 600 "$DAEMON_LOG" 2>/dev/null || true
    nohup "$DAEMON" >>"$DAEMON_LOG" 2>&1 &
    for _ in {1..30}; do
        "$CLI" app status >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    notify "tcpviewerd did not answer" "See $DAEMON_LOG"
    return 1
}

default_interface() {
    ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}'
}

case "${1:-}" in
    start)
        # Capabilities: try to fix automatically (passwordless helper via
        # polkit policy, then a desktop password dialog, then cached sudo).
        # If still missing, notify-send surfaces the exact one-time setup.
        "$ROOT/scripts/grant-capture-caps.sh" "$DAEMON" || true
        # A daemon started before a grant keeps running without the caps:
        # restart those instances so the spawn below actually has them.
        "$ROOT/scripts/restart-stale-daemons.sh" "$DAEMON"
        ensure_daemon || exit 1
        IFACE="$(default_interface)"
        if [[ -z "$IFACE" ]]; then
            notify "No default-route interface" "Open the app to pick one manually"
            exit 1
        fi
        out="$("$CLI" capture start --interface "$IFACE" 2>&1)" || {
            notify "Capture failed on $IFACE" "$(printf '%s' "$out" | head -c 160)"
            exit 1
        }
        notify "Capture started" "Listening on $IFACE"
        ;;
    stop)
        if "$CLI" capture stop >/dev/null 2>&1; then
            notify "Capture stopped" "tcpviewerd keeps running"
        else
            notify "No active capture"
        fi
        ;;
    status)
        if "$CLI" capture status >/dev/null 2>&1; then
            echo "capturing"
        elif "$CLI" app status >/dev/null 2>&1; then
            echo "idle"
        else
            echo "offline"
        fi
        ;;
    *)
        printf 'usage: quick-capture.sh start|stop|status\n' >&2
        exit 2
        ;;
esac
