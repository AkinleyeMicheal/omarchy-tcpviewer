#!/usr/bin/env bash
# Grant live-capture capabilities to tcpviewerd without a terminal.
#
# Tries, in order:
#   1. the passwordless root helper installed by setup-capture-helper.sh
#      (runs via pkexec with our narrow polkit policy - no dialog);
#   2. a direct `pkexec setcap` (shows a desktop password dialog when a
#      polkit authentication agent is running);
#   3. non-interactive `sudo -n setcap` (works while a sudo password is
#      still cached).
# Every outcome is reported with notify-send so this is safe for execDetached
# keybindings and panel rows. Exits 0 when capabilities are (now) present,
# 1 when they could not be obtained, 2 when nothing can be checked.
#
#   scripts/grant-capture-caps.sh [path-to-tcpviewerd]
set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
ROOT="$(cd -P "$(dirname "$SOURCE")/.." && pwd)"

WAIT="${TCPVIEWER_GRANT_WAIT:-60}"

notify() {
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -a "Omarchy TCPViewer" -t 8000 "$1" "${2:-}" || true
    fi
}

caps_present() {
    command -v getcap >/dev/null 2>&1 \
        && getcap "$1" 2>/dev/null | grep -q cap_net_raw \
        && getcap "$1" 2>/dev/null | grep -q cap_net_admin
}

DAEMON="${1:-$ROOT/daemon/.build/debug/tcpviewerd}"
if ! command -v getcap >/dev/null 2>&1; then
    exit 2
fi
if [[ ! -x "$DAEMON" ]]; then
    exit 2
fi
if caps_present "$DAEMON"; then
    exit 0
fi

SETCAP_ARGS=(cap_net_raw,cap_net_admin+ep "$DAEMON")
HELPER="/usr/local/libexec/omarchy-tcpviewer/grant-caps"

granted=0
if [[ -x "$HELPER" ]] && command -v pkexec >/dev/null 2>&1; then
    if timeout "$WAIT" pkexec "$HELPER" >/dev/null 2>&1 && caps_present "$DAEMON"; then
        granted=1
    fi
fi
if (( ! granted )) && command -v pkexec >/dev/null 2>&1; then
    if timeout "$WAIT" pkexec /usr/bin/setcap "${SETCAP_ARGS[@]}" >/dev/null 2>&1 \
        && caps_present "$DAEMON"; then
        granted=1
    fi
fi
if (( ! granted )) && command -v sudo >/dev/null 2>&1; then
    if sudo -n /usr/bin/setcap "${SETCAP_ARGS[@]}" >/dev/null 2>&1 \
        && caps_present "$DAEMON"; then
        granted=1
    fi
fi

if (( granted )); then
    notify "Capture permissions granted" "tcpviewerd can now listen live"
    exit 0
fi

notify "One-time capture setup" \
    "Start capture then run once:\nsudo bash $ROOT/scripts/setup-capture-helper.sh\n\nOr grant now:\nsudo setcap cap_net_raw,cap_net_admin+ep $DAEMON"
exit 1
