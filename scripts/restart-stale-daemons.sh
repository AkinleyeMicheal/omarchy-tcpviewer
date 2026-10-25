#!/usr/bin/env bash
# Restart tcpviewerd processes that predate a capture-capabilities grant.
# File capabilities only apply at process start, so a daemon left over from
# before `setcap` runs without them. Used by tcpviewer-run.sh and the quick
# access panel's Start live capture.
#
#   scripts/restart-stale-daemons.sh <tcpviewerd-path>
#
# Detach-safe: notifications once, no terminal output needed beyond logs.
set -euo pipefail

DAEMON="${1:-}"
if [[ -z "$DAEMON" || ! -x "$DAEMON" ]]; then
    exit 0
fi

if ! command -v getcap >/dev/null 2>&1; then
    exit 0
fi
getcap "$DAEMON" 2>/dev/null | grep -q cap_net_raw || exit 0
getcap "$DAEMON" 2>/dev/null | grep -q cap_net_admin || exit 0

stale_pids=()
while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    cap_eff="$(awk '/^CapEff:/ {print $2}' "/proc/$pid/status" 2>/dev/null || true)"
    [[ -n "$cap_eff" ]] || continue
    if (( (16#$cap_eff & 0x3000) != 0x3000 )); then
        stale_pids+=("$pid")
    fi
done < <(pgrep -x tcpviewerd 2>/dev/null || true)

# pgrep's own shell may match nothing: guard empty arrays on old bash.
((${#stale_pids[@]})) || exit 0

for pid in "${stale_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
done
for _ in {1..30}; do
    alive=0
    for pid in "${stale_pids[@]}"; do
        kill -0 "$pid" 2>/dev/null && alive=1
    done
    ((alive)) || break
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
