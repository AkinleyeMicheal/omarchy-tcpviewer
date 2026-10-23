# Omarchy TCPViewer

A Linux/Omarchy port of [TCP Viewer](https://github.com/ProxymanApp/TCPViewer) by Proxyman LLC — a native packet viewer for live captures and capture files, powered by Wireshark's dissection libraries.

**Status: under active development. Not yet ready for use.**

## What this is

Full-fidelity port of TCP Viewer to [Omarchy](https://omarchy.org) (Arch Linux + Hyprland):

- `daemon/` — `tcpviewerd`: capture + dissection engine (Swift, derived from upstream's `PcapPlusPlusCore`), speaking a JSON contract over a Unix socket
- `app/` — Qt Quick (QML) viewer app: packet table, filters, details tree, hex view, follow streams, statistics, diff
- `plugin/` — Omarchy shell plugin (`fonsgaudii.tcpviewer`): bar widget + panel integrating capture status and quick access
- `packaging/` — install scripts, `setcap` capability setup, AUR packaging
- `docs/` — design decisions (ADR), porting notes

## Build and run

```sh
# Daemon (capture + dissection engine)
cd daemon && swift build

# GUI
cmake -S app -B app/build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build app/build
```

Launch both with the repo script:

```sh
scripts/tcpviewer-run.sh
```

It starts `tcpviewerd` when it is not already answering, then opens the GUI.
A user-local install is also available:

- `~/.local/bin/omarchy-tcpviewer` → `scripts/tcpviewer-run.sh`
- `~/.local/share/applications/omarchy-tcpviewer.desktop`
- Hyprland binding: `SUPER + SHIFT + T` (see `~/.config/hypr/bindings.lua`)

Live capture needs packet capabilities on the daemon. Re-apply them after every
relink/rebuild of `tcpviewerd` (run this from the repository root, or use the
absolute path):

```sh
sudo setcap cap_net_raw,cap_net_admin+ep "$PWD/daemon/.build/debug/tcpviewerd"
```

Opening capture files works without capabilities. The launcher also restarts a
running `tcpviewerd` that predates the `setcap` call, because file capabilities
only take effect when a process starts. Daemon output goes to
`~/.local/state/omarchy-tcpviewer/daemon.log` (rotated at 1 MiB).

If live capture still reports `CAP_NET_RAW may be required`, restart the daemon
explicitly and retry:

```sh
pkill -x tcpviewerd
scripts/tcpviewer-run.sh
```

## Diff

Select a packet and press `Ctrl+Y` (or right-click → Diff Selected Packet) to
add it to the Diff pool. Add a second packet the same way; the first two are
assigned Left and Right. The window compares:

- **Packet Details** as side-by-side or unified text with changed lines tinted.
- **Packet Bytes** as two hex panes with the changed range highlighted.

`F7` / `Shift+F7` jump between changed lines. `Clear` empties the pool. Detail
diffs are capped at 2000 lines per side; byte diffs trim the common prefix and
suffix before highlighting, so length changes do not mark every later byte.

## Security

See [docs/security-review.md](docs/security-review.md). In short: the IPC socket
is `0700`/`0600` with same-UID peer checks, the app never fetches URLs (no SSRF
surface), imports are local files only, and capture-derived strings are rendered
as plain text.

## License

GPL-2.0-or-later. See [NOTICE](NOTICE) for upstream attribution and third-party components.

## Credits

Built by Proxyman LLC's [TCP Viewer](https://github.com/ProxymanApp/TCPViewer) team — this port reuses their GPL-2.0-or-later source with gratitude. Wireshark provides packet dissection.
