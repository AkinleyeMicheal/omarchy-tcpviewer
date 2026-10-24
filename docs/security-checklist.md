# Plugin security checklist

Status of every marketplace security item for `fonsgaudii.tcpviewer`, with the
evidence that backs it. Details and the full issue table live in
[security-review.md](security-review.md) (source-level review dated 2026-10-23).

| Checklist item | Status | Evidence |
| --- | --- | --- |
| IPC exposed only to the owning user | ✅ | `AF_UNIX` socket with `0700` directory + `0600` socket, owner checks on both directory (`st_uid == geteuid()`) and peer (same-UID credential check). `daemon/Sources/tcpviewerd/SocketServer.swift`, `app/src/daemonclient.cpp` |
| No outbound network access from the plugin/app/daemon (SSRF surface) | ✅ | No `URLSession`/libcurl/HTTP/WebSocket client or outbound `connect()` anywhere; QtNetwork is linked only for `QLocalSocket`. Imports are local-file-only (`file:` URLs, absolute paths, capture extensions enforced). |
| Capture data cannot spoof or inject into the UI/terminal | ✅ | `Text.PlainText` on all capture-derived QML strings; CLI `displaySafe()` strips control/format characters (blocks OSC 52 clipboard abuse and escape injection). |
| Capabilities are minimized | ✅ | Only `tcpviewerd` holds `cap_net_raw,cap_net_admin` (live capture); the Qt app runs unprivileged and file opens need no capabilities. |
| No user-config overwrite without consent | ✅ | The plugin writes nothing at install/remove time beyond what `omarchy plugin add/remove` itself manages. The app persists view state only in `~/.config/omarchy-tcpviewer/Omarchy TCPViewer.conf` (Qt QSettings); the daemon logs under `~/.local/state/omarchy-tcpviewer/`. No Hyprland, shell.json, or theme files are ever touched by project code. |
| Install and removal verified end-to-end | ✅ | `omarchy plugin add https://github.com/AkinleyeMicheal/omarchy-tcpviewer --enable --yes` and `omarchy plugin remove fonsgaudii.tcpviewer --yes` were run against this GitHub repo on 2026-10-24; manifest passes `omarchy plugin validate` on a pristine clone. |
| Bounded data structures (hostile-capture DoS) | ✅ | IPC line cap (20 MiB read abort), detail-tree depth clamp (64), source-tree caps (apps 10k, domains 50k, IPs 50k, children 5k, flat rows 200k). |
| Third-party code provenance | ✅ | Upstream TCPViewer code (GPL-2.0-or-later, ported), one vendored Wireshark file (`daemon/vendor/ipaddr/ipaddr.c`, GPL-2.0-or-later), system Wireshark/GLib/libpcap libraries at runtime. See [../NOTICE](../NOTICE). |
| Privacy of committed imagery/fixtures | ✅ | The README cover and test fixtures use synthetic data only: `10.x`/`203.0.113.x` addresses, locally-administered `02:` MACs, `example.com` hostnames; `.gitignore` blocks stray captures. |
| Error handling of malformed plugin input (IPC peer abuse) | ✅ | Daemon validates every command payload field (ids are UUIDs, filter strings length-capped); the app aborts non-`ok` responses cleanly instead of crashing. |

Remaining known limitations (documented, not fixed): no container/namespace
isolation for the daemon (single-user threat model by design); live packet
buffers grow with traffic but are bounded by the same per-source caps as the
plugin list.
