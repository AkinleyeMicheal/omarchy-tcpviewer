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

## License

GPL-2.0-or-later. See [NOTICE](NOTICE) for upstream attribution and third-party components.

## Credits

Built by Proxyman LLC's [TCP Viewer](https://github.com/ProxymanApp/TCPViewer) team — this port reuses their GPL-2.0-or-later source with gratitude. Wireshark provides packet dissection.
