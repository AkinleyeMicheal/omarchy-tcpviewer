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

# Live capture needs capabilities; relinking the daemon drops them. Surface the
# exact command once per launch instead of failing silently from a keybinding.
if command -v getcap >/dev/null 2>&1 && ! getcap "$DAEMON" 2>/dev/null | grep -q 'cap_net_raw'; then
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -a "Omarchy TCPViewer" -t 8000 \
            "Live capture needs capabilities" \
            "sudo setcap cap_net_raw,cap_net_admin+ep $DAEMON" || true
    fi
fi

# File capabilities only apply when a process starts. A daemon left over from
# before setcap keeps running without them, so restart those instances.
if command -v getcap >/dev/null 2>&1 \
    && getcap "$DAEMON" 2>/dev/null | grep -q 'cap_net_raw' \
    && getcap "$DAEMON" 2>/dev/null | grep -q 'cap_net_admin'; then
    stale_pids=()
    for pid in $(pgrep -x tcpviewerd 2>/dev/null || true); do
        cap_eff="$(awk '/^CapEff:/ {print $2}' "/proc/$pid/status" 2>/dev/null || true)"
        [[ -n "$cap_eff" ]] || continue
        if (( (16#$cap_eff & 0x3000) != 0x3000 )); then
            stale_pids+=("$pid")
        fi
    done
    if (( ${#stale_pids[@]} )); then
        kill "${stale_pids[@]}" 2>/dev/null || true
        for _ in {1..30}; do
            alive=0
            for pid in "${stale_pids[@]}"; do
                kill -0 "$pid" 2>/dev/null && alive=1
            done
            (( alive )) || break
            sleep 0.1
        done
        for pid in "${stale_pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                kill -KILL "$pid" 2>/dev/null || true
            fi
        done
        if command -v notify-send >/dev/null 2>&1; then
            notify-send -a "Omarchy TCPViewer" -t 5000 \
                "Restarted tcpviewerd" \
                "The daemon was started before capture capabilities were granted." || true
        fi
    fi
fi

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
