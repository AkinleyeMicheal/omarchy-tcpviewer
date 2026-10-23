# Security review — Omarchy TCPViewer

Date: 2026-10-23. Scope: `app/` (Qt Quick + C++), `daemon/` (Swift, embedded
Wireshark epan shim, vendored Wireshark `ipaddr.c`), `scripts/`, `packaging/`,
`plugin/` (manifest only at this point).

This is a source-level review plus runtime checks, not a third-party audit. No
fuzzing was performed in this pass.

## Threat model

- Single-user Linux desktop app. The GUI and CLI talk to a per-user daemon over
  an `AF_UNIX` socket; there is no TCP listener.
- Untrusted data: capture files (`.pcap`/`.pcapng`), live packet bytes, display
  filter strings, interface names, file names/paths, and any strings derived
  from packets that reach the UI or a terminal.
- Same-UID IPC clients are treated as semi-trusted (they can issue every daemon
  command by design); other local users are not trusted at all.
- The daemon holds `cap_net_raw,cap_net_admin` for live capture.

## Fixed in this pass

| Severity | Issue | Fix | Location |
| --- | --- | --- | --- |
| Medium | GUI fell back to `/tmp/omarchy-tcpviewer/...` when `XDG_RUNTIME_DIR` was unset. In a shared `/tmp`, a foreign user could own that directory, replace the socket, and impersonate `tcpviewerd`. | Removed the fallback; the client requires `XDG_RUNTIME_DIR` (as the daemon already did) and reports a clear error. | `app/src/daemonclient.cpp` |
| Low–Medium | Daemon accepted a pre-existing socket directory without checking its owner, so a directory planted in a shared parent could be used for socket replacement. | After `mkdir`, `stat` the directory and refuse unless `st_uid == geteuid()`; `chmod 0700` remains. | `daemon/Sources/tcpviewerd/SocketServer.swift` |
| Low | `QLocalSocket` read buffer was unbounded if a peer streamed data without a newline (same-UID DoS). | Abort the connection when a partial line exceeds 20 MiB (daemon responses are capped at 16 MiB). | `app/src/daemonclient.cpp` |
| Low | QML `Text` defaults to `AutoText`, so capture-derived strings beginning with markup were parsed as rich text (UI spoofing). | `textFormat: Text.PlainText` on packet cells, detail rows, source titles, statistics cells, status/error strings, and follow-stream headers. | `app/qml/*.qml` |
| Low | CLI `--output text` printed packet-derived strings raw, allowing terminal escape/bidi injection from a malicious capture (e.g. OSC 52 clipboard writes). | `displaySafe()` replaces Unicode control and format characters before printing. | `daemon/Sources/tcpviewer-cli/main.swift` |
| Low | Detail-tree parsing recursed without a depth limit; a malformed/hostile daemon response could exhaust the GUI stack. | Depth capped at 64 (daemon clamps to 12). | `app/src/packetdetailmodel.{h,cpp}` |
| Info | Import accepted non-local URLs and passed them through as literal path strings. | Local files only: real `QUrl` values must be `file:` URLs; strings are paths; the daemon independently requires an absolute path and a capture extension. | `app/src/sessioncontroller.cpp` |

## Verified controls

- **No SSRF surface.** No `URLSession`, libcurl, QtNetwork, `XMLHttpRequest`,
  `fetch`, WebSocket client, or outbound `connect()` exists in the app or
  daemon. The only sockets are the `AF_UNIX` IPC endpoints. Imports are local
  files only, and the daemon's import validator requires an absolute path to an
  existing regular `.pcap`/`.pcapng`/`.cap` file. Nothing in the UI can make the
  daemon fetch a URL.
- **IPC hardening.** Directory `0700`, socket `0600`, `SO_PEERCRED` same-UID
  enforcement on accept, 1 MiB request / 16 MiB response caps, line-delimited
  JSON, refusal to replace a non-socket path, serial per-connection queues, and
  idempotent close.
- **No command execution.** No `system`, `popen`, `posix_spawn`, `Process`, or
  shell interpolation anywhere in app or daemon.
- **File handling.** Import: absolute, regular, readable, extension allowlist.
  Export: refuses symbolic-link destinations and does not overwrite without
  `overwrite`.
- **Rendering.** Hex view bounds-checks every row; QML shows capture strings as
  plain text; the CLI sanitizes control/format characters.
- **Privileges.** No setuid binaries. The daemon's only elevated capabilities
  are `cap_net_raw,cap_net_admin`, used for live capture; the GUI and CLI are
  unprivileged.
- **Dependencies.** The app links Qt Quick/Widgets/Dialogs only — no QtNetwork
  or QtWebEngine. The plugin currently has a manifest but no runtime code.

## Residual risks and recommendations

- **Packet parsers are the highest-impact attack surface.** PcapPlusPlus and the
  embedded Wireshark epan code parse untrusted captures in the same process
  that holds capture capabilities. Keep Wireshark and PcapPlusPlus current.
  Longer term, consider a capture helper or capability drop for file-only
  sessions, and fuzz pcap/pcapng inputs.
- **Same-UID clients are trusted.** Any process running as the user can drive
  the daemon (by design). The socket permissions keep other users out.
- **Import size is not capped.** Opening an enormous local capture can exhaust
  memory (availability only; user-initiated).
- **`TCPVIEWER_*` environment hooks** (open files, select packet/detail,
  screenshots, follow, statistics, split/tabs, socket override) are debug/CI
  aids. They are same-user environment variables, not a security boundary, and
  should not be exposed to untrusted processes.
- **Live capture capabilities are lost on relink.** After rebuilding
  `tcpviewerd`, re-apply:
  `sudo setcap cap_net_raw,cap_net_admin+ep daemon/.build/debug/tcpviewerd`.
  Until then, file viewing works but starting a live capture fails.

## Reproduce

```sh
# No network/exec client surfaces
grep -rniE 'URLSession|libcurl|QtNetwork|XMLHttpRequest|system\(|popen|posix_spawn' app/src daemon/Sources

# Socket permissions and ownership
ls -ld "$XDG_RUNTIME_DIR/omarchy-tcpviewer"
ls -l  "$XDG_RUNTIME_DIR/omarchy-tcpviewer/tcpviewerd.sock"

# Capabilities
getcap daemon/.build/debug/tcpviewerd
```
