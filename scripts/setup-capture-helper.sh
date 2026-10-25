#!/usr/bin/env bash
# ONE-TIME privileged setup for automatic live capture.
#
# Run this once, with sudo, from the plugin clone whose tcpviewerd you use:
#
#   sudo bash ~/.config/omarchy/plugins/fonsgaudii.tcpviewer/scripts/setup-capture-helper.sh
#
# What it does (everything is idempotent; re-running re-applies the same state):
#   1. Installs libcap (setcap/getcap) if missing.
#   2. Best-effort installs and enables the hyprpolkitagent authentication
#      agent, so any pkexec password dialog is a desktop prompt, not a TTY.
#   3. Writes a ROOT-OWNED helper at
#        /usr/local/libexec/omarchy-tcpviewer/grant-caps
#      that does exactly one thing: apply cap_net_raw,cap_net_admin+ep to the
#      tcpviewerd binary of THIS clone (never takes arguments).
#   4. Writes a narrow polkit policy that lets the ACTIVE session run that
#      helper WITHOUT a password. Nothing else on the system changes.
#   5. Applies the capabilities immediately and reports the result.
#
# After this, Start live capture, Stop capture and post-build re-grants are
# fully automatic: no terminal, no password prompts.
#
# Re-run this script whenever the plugin clone moves or you use multiple
# clones (the last run wins - the helper embeds one path only).
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "Run me once with sudo:" >&2
    echo "  sudo bash $0" >&2
    exit 1
fi

# Resolve the user that owns the desktop session (sudo or pkexec origin).
TARGET_USER="${SUDO_USER:-}"
if [ -n "${PKEXEC_UID:-}" ]; then
    TARGET_USER="$(getent passwd "$PKEXEC_UID" 2>/dev/null | cut -d: -f1 || true)"
fi
[ -n "$TARGET_USER" ] || TARGET_USER="$(id -nu 1000 2>/dev/null || true)"
[ -n "$TARGET_USER" ] || { echo "Cannot determine the owning user; run via sudo." >&2; exit 1; }

SOURCE="$0"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [ "$SOURCE" = "${SOURCE#/}" ] && SOURCE="$DIR/$SOURCE"
done
ROOT="$(cd -P "$(dirname "$SOURCE")/.." && pwd)"
DAEMON="$ROOT/daemon/.build/debug/tcpviewerd"

if [ ! -x "$DAEMON" ]; then
    echo "tcpviewerd is not built yet in $ROOT" >&2
    echo "Build first (panel row 'Build engine & viewer' or scripts/build.sh), then re-run." >&2
    exit 1
fi

echo "[1/5] setcap/getcap (libcap)"
if [ ! -x /usr/bin/setcap ]; then
    if command -v pacman >/dev/null 2>&1; then
        pacman -S --needed --noconfirm libcap
    else
        echo "ERROR: /usr/bin/setcap missing and pacman unavailable" >&2
        exit 1
    fi
fi

echo "[2/5] polkit authentication agent (hyprpolkitagent, best effort)"
if [ ! -x /usr/bin/hyprpolkitagent ] && [ ! -f /usr/lib/systemd/user/hyprpolkitagent.service ]; then
    if command -v pacman >/dev/null 2>&1; then
        pacman -S --needed --noconfirm hyprpolkitagent || echo "WARN: could not install hyprpolkitagent (not fatal)"
    else
        echo "WARN: pacman unavailable; skipping agent install (not fatal)"
    fi
fi
if [ -f /usr/lib/systemd/user/hyprpolkitagent.service ]; then
    UID_="$(id -u "$TARGET_USER")"
    if runuser -u "$TARGET_USER" -- env XDG_RUNTIME_DIR="/run/user/$UID_" \
        systemctl --user enable --now hyprpolkitagent.service 2>/dev/null; then
        echo "      agent enabled for $TARGET_USER"
    elif pgrep -u "$TARGET_USER" -f hyprpolkitagent >/dev/null 2>&1; then
        echo "      agent already running"
    else
        echo "WARN: could not enable hyprpolkitagent; passwordless helper still works" >&2
    fi
fi

echo "[3/5] root-owned grant helper"
HELPER_DIR=/usr/local/libexec/omarchy-tcpviewer
HELPER="$HELPER_DIR/grant-caps"
mkdir -p "$HELPER_DIR"
cat > "$HELPER" <<EOF
#!/bin/sh
# Installed by Omarchy TCPViewer's setup-capture-helper.sh.
# Applies live-capture file capabilities to exactly one binary: the
# tcpviewerd built in this plugin clone. Takes no arguments on purpose:
# the polkit policy authorizes only this fixed action.
set -eu
TARGET="$DAEMON"
OWNER="$TARGET_USER"
[ -f "\$TARGET" ] || exit 3
[ -x "\$TARGET" ] || exit 3
[ "\$(stat -c '%U' "\$TARGET")" = "\$OWNER" ] || exit 4
AW="\$(stat -c '%A' "\$TARGET")"
[ "\$(expr substr "\$AW" 10 1)" != "w" ] || exit 4
[ -x /usr/bin/setcap ] || exit 5
exec /usr/bin/setcap cap_net_raw,cap_net_admin+ep "\$TARGET"
EOF
chown root:root "$HELPER"
chmod 755 "$HELPER"

echo "[4/5] narrow polkit policy (passwordless for active sessions)"
POLICY=/usr/share/polkit-1/actions/org.omarchy-tcpviewer.grant-caps.policy
cat > "$POLICY" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC "-//freedesktop//DTD polkit Policy Configuration 1.0//EN"
 "http://www.freedesktop.org/software/polkit/policyconfig-1.dtd">
<policyconfig>
  <vendor>Omarchy TCPViewer</vendor>
  <vendor_url>https://github.com/AkinleyeMicheal/omarchy-tcpviewer</vendor_url>

  <action id="org.omarchy-tcpviewer.grant-caps">
    <description>Grant packet-capture capabilities to Omarchy TCPViewer's daemon</description>
    <message>Omarchy TCPViewer asks to grant capture capabilities to tcpviewerd</message>
    <icon_name>network-wired-symbolic</icon_name>
    <defaults>
      <allow_any>no</allow_any>
      <allow_inactive>no</allow_inactive>
      <allow_active>yes</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">$HELPER</annotate>
  </action>
</policyconfig>
EOF
chown root:root "$POLICY"
chmod 644 "$POLICY"
if command -v python3 >/dev/null 2>&1; then
    if ! python3 -c 'import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])' "$POLICY" 2>/dev/null; then
        echo "ERROR: generated policy XML is invalid; removing it" >&2
        rm -f "$POLICY" /usr/share/polkit-1/actions/org.omarchy-tcpviewer.grant-caps.policy
        exit 1
    fi
fi

echo "[5/5] grant capabilities now"
if "$HELPER" && getcap "$DAEMON" 2>/dev/null | grep -q cap_net_raw; then
    echo "OK: $DAEMON has cap_net_raw,cap_net_admin"
    echo
    echo "Done. Live capture, Stop capture and post-build re-grants now run"
    echo "without any terminal or password prompt."
    echo "If the plugin clone moves, re-run this setup from the new clone."
else
    echo "ERROR: grant helper did not produce capabilities; inspect $HELPER" >&2
    exit 1
fi
