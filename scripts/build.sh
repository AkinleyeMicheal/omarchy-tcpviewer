#!/usr/bin/env bash
# Build the daemon (Swift) and GUI (Qt Quick) inside this plugin clone so the
# quick access panel / run script can launch them.
#
#   scripts/build.sh
#
# Detached-safe: invoked with execDetached from the panel, so all feedback
# goes through notify-send and the full log lands in .build-logs/.
# A lockfile prevents two overlapping builds (panel double-click etc.).
set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
ROOT="$(cd -P "$(dirname "$SOURCE")/.." && pwd)"

LOG_DIR="$ROOT/.build-logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/build-$(date +%Y%m%d-%H%M%S).log"

# Rotate: keep the last five build logs. `|| true`: under pipefail an empty
# glob (ls with no match) would otherwise kill the script.
ls -t "$LOG_DIR"/build-*.log 2>/dev/null | tail -n +6 | xargs -r rm -f -- || true

LOCK="$LOG_DIR/build.lock"
if [[ -e "$LOCK" ]] && kill -0 "$(cat "$LOCK")" 2>/dev/null; then
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -a "Omarchy TCPViewer" -t 5000 "Build already running" "Watch the panel status for the result" || true
    fi
    exit 0
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

notify() {
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -a "Omarchy TCPViewer" -t 6000 "$1" "${2:-}" || true
    fi
}

# Find the Swift toolchain (swift.org installs outside PATH on some setups).
if ! command -v swift >/dev/null 2>&1; then
    for cand in "$HOME/.local/share/swift/toolchain/usr/bin" "/usr/local/share/swift/usr/bin" "/opt/swift/usr/bin"; do
        if [[ -x "$cand/swift" ]]; then
            export PATH="$cand:$PATH"
            break
        fi
    done
fi

notify "Building TCPViewer…" "daemon + viewer app — first build takes a few minutes"

{
    echo "[build.sh] $(date -Is) root=$ROOT"
    echo "[build.sh] daemon: swift build"
    ( cd "$ROOT/daemon" && swift build )
    echo "[build.sh] daemon: OK"
    echo "[build.sh] app: cmake configure + ninja"
    cmake -S "$ROOT/app" -B "$ROOT/app/build" -G Ninja -DCMAKE_BUILD_TYPE=Release
    cmake --build "$ROOT/app/build"
    echo "[build.sh] app: OK"
    echo "[build.sh] done $(date -Is)"
} >>"$LOG" 2>&1 || {
    notify "TCPViewer build failed" "See $LOG"
    exit 1
}

# Live capture still needs capabilities; point at the exact command so the
# next Start live capture succeeds. File viewing works without it.
if [[ -x "$ROOT/daemon/.build/debug/tcpviewerd" ]]; then
    if command -v getcap >/dev/null 2>&1 \
        && ! getcap "$ROOT/daemon/.build/debug/tcpviewerd" 2>/dev/null | grep -q cap_net_raw; then
        notify "TCPViewer build finished" \
            "Launch it from the quick access panel. For live capture run:\nsudo setcap cap_net_raw,cap_net_admin+ep $ROOT/daemon/.build/debug/tcpviewerd"
    else
        notify "TCPViewer build finished" "Launch it from the quick access panel"
    fi
fi
