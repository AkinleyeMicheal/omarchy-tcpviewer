# Omarchy TCPViewer — UI design tokens (extracted from upstream AppKit source)

Forensic extraction of the upstream TCP Viewer AppKit UI (commit `56e72b9`) so the
Qt Quick rebuild can reproduce it 1:1 where possible (ADR-6). Each token cites the
upstream file it came from. Values marked *(derived)* are macOS semantic values
that AppKit resolves at runtime; they are reproduced as explicit light/dark pairs.

## Typography

| Token | Upstream | Value / mapping |
|---|---|---|
| UI font family | SF Pro Text (`NSFont.systemFont`) | Inter, fallback Noto Sans / Liberation Sans |
| `ui.size` | `NSFont.systemFontSize` | 13 px |
| `ui.small` | `NSFont.smallSystemFontSize` | 11 px |
| `ui.title` | empty state title | 19 px semibold (`AppKitUIUtilities.swift:70`) |
| Packet table font | `packetFont` default | **monospaced 12 px** (`AppConfiguration.swift:28,134`); user range 10–24 px |
| Packet row height | `ceil(max(22, packetFontSize + 12))` | **24 px** at default (`AppConfiguration.swift:130`) |
| Inspector tree row height | `Metrics.rowHeight` | 20 px (`PacketInspectorViewController.swift:676`) |
| Sidebar row height | `outlineView.rowHeight` | 28 px (`SidebarViewController.swift:479`) |
| Status strip labels | `monospacedDigitSystemFont` 11 | 11 px monospaced digits (`StatusStripViewController.swift:52,59`) |
| Hex view font | `packetFont(sizeDelta: -1)` | 11 px monospaced (`PacketHexViewController.swift:267`) |

Linux substitution: `SF Mono` → `JetBrainsMono Nerd Font` (present on Omarchy);
`SF Pro Text` → `Inter` (Arch `extra/inter-font`).

## Colors

Semantic AppKit colors used by the chrome. The Qt theme carries both palettes and
switches with the system color scheme; "Follow Omarchy theme" remaps only these
tokens.

| Token | Light (derived) | Dark (derived) | Upstream usage |
|---|---|---|---|
| `window.background` | `#ECECEC` | `#1E1E1E` | `windowBackgroundColor` (`StatusStripViewController.swift:71`) |
| `content.background` | `#FFFFFF` | `#252525` | `controlBackgroundColor` (workspace container) |
| `label.primary` | `#000000` 85 % | `#FFFFFF` 85 % | `labelColor` |
| `label.secondary` | `#000000` 50 % | `#FFFFFF` 55 % | `secondaryLabelColor` |
| `separator` | `#000000` 10 % | `#FFFFFF` 12 % | `separatorColor` |
| `accent` | `#007AFF` | `#0A84FF` | `controlAccentColor` |
| `row.alternate` | `#F5F5F5` | `#2A2A2A` | `usesAlternatingRowBackgroundColors` (`PacketTablePresentation.swift:12`) |

### Protocol palette (`PacketTableCells.swift:206-280`)

Protocol cells are centered pills: text in `tint`, pill filled with `tint` at the
listed alpha, semibold packet font.

| Protocol | Tint | Fill alpha |
|---|---|---|
| TCP | systemOrange `#FF9F0A` | 0.16 |
| UDP | systemCyan `#32ADE6` | 0.18 |
| TLS / SSL / HTTPS / TLSV1(.1/.2/.3) | systemGreen `#34C759` | 0.16 |
| HTTP | systemPink `#FF2D55` | 0.16 |
| DNS | systemPurple `#AF52DE` | 0.16 |
| ICMP / ICMPv6 | systemRed `#FF3B30` | 0.14 |
| ARP | systemTeal `#30B0C7` | 0.16 |
| IPv4 / IPv6 / IP | systemBlue `#007AFF` | 0.14 |
| Ethernet / Eth | systemGray `#8E8E93` | 0.18 |
| default (severity) | systemOrange | 0.18 |
| default | accent | 0.14 |

Summary text turns systemOrange for non-normal severity
(`PacketTablePresentation.swift:56`). Row highlight colors blend the user color
over `controlBackgroundColor` at 0.22 (light) / 0.32 (dark)
(`PacketTableCells.swift:13-25`).

## Layout metrics

| Token | Value | Source |
|---|---|---|
| Sidebar default / minimum | 280 / 220 px | `NetworkInspectorViewModel.swift:14-16` |
| Inspector trailing default / minimum | 360 / 100 px | `NetworkInspectorViewModel.swift:16-17` |
| Details:hex split | 70 % / 30 % | `PacketInspectorViewController.swift:681-682` |
| Minimum hex pane height | 120 px | `PacketInspectorViewController.swift:678` |
| Inspector tree filter bar | 34 px | `PacketInspectorViewController.swift:679` |
| Quick filter bar | 34 px high, 24 px buttons, 16 px insets, 16 px button padding | `PacketQuickFilterViewController.swift:62-69` |
| Status strip | 33 px high, top separator, 14 px side insets, 8 px control gap | `StatusStripViewController.swift:139-155` |
| Table text padding | left 5 px, right 4 px | `PacketTableCells.swift:29-30` |
| Protocol pill | min width 42, width text+16, max cell−12; height min(cell−4, max(18, text+6)); radius height/2 | `PacketTableCells.swift:159-172` |
| Client cell icon | 16 px icon, 6 px side padding, 4 px gap | `PacketTableCells.swift:296-299` |
| Empty state | icon 42 pt, title 19 semibold, message 13 secondary, 10 px stack spacing, max message width 420 px, 36 px top inset (top placement) | `AppKitUIUtilities.swift:58-100` |

## Packet table columns (`PacketTableColumnService.swift:195-220`)

Visible by default in **this order**; hidden columns are user-toggleable from the
header context menu.

| # | Title | Default width | Min width | Visible |
|---|---|---|---|---|
| 1 | `#` | 68 | 52 | yes |
| 2 | Time | 112 | 96 | yes |
| 3 | Source | 180 | 100 | yes |
| 4 | Destination | 180 | 100 | yes |
| 5 | Source Port | 92 | 76 | — |
| 6 | Destination Port | 118 | 92 | — |
| 7 | Protocol | 96 | 82 | yes |
| 8 | Client | 140 | 60 | yes |
| 9 | Domain | 150 | 60 | yes |
| 10 | Stream ID | 96 | 76 | — |
| 11 | Direction | 90 | 76 | — |
| 12 | Delta Time | 96 | 78 | — |
| 13 | Stream Delta | 106 | 88 | — |
| 14 | TCP Flags | 118 | 88 | — |
| 15 | TCP Payload | 104 | 86 | — |
| 16 | PID | 76 | 58 | — |
| 17 | Bundle ID | 220 | 120 | — |
| 18 | Decode Status | 120 | 96 | — |
| 19 | Interface | 112 | 84 | — |
| 20 | Length | 80 | 68 | yes |
| 21 | Summary | 320 | 120 | yes |
| 22 | Tags | 140 | 90 | yes |
| 23 | Comment | 320 | 140 | yes (flexible trailing) |

Table behavior: alternating row backgrounds, zero intercell spacing, last column
autoresizes, columns reorderable/resizable, multiple selection, full-width style,
selection highlight `.regular` (`PacketTablePresentation.swift:11-23`). Secondary
(monospaced-digit) text for numeric columns (`PacketTablePresentation.swift:57-75`).

Default visible set: `#`, Time, Source, Destination, Protocol, Client, Domain,
Length, Summary, Tags, Comment.

## Window chrome inventory (for the QML shell)

- **Toolbar** (`TCPViewerToolbarDataSource.swift`): toggle sidebar, interface
  picker, capture toggle, clear, centered status, share menu, split view toggle,
  inspector toggle, bottom-inspector toggle. (Upstream trial/Sentry/Sparkle items
  are intentionally absent per ADR-2.)
- **Sidebar**: source list (live interfaces, open capture files, pinned items) with
  a filter field; row height 28, `.sourceList` style.
- **Workspace**: packet table, quick-filter bar above it, status strip below.
- **Inspector**: details outline (20 px rows) over hex pane at 70/30.
- **Status strip**: Cancel Load / Clear / Filter buttons, centered packet count,
  right-aligned memory + throughput metrics.
- **Menus/shortcuts**: extracted from `Base.lproj/Main.storyboard` and
  `AppDelegate.swift` during the menu milestone; `⌘` maps to `Ctrl` on Linux.

## Documented substitutions (ADR-6)

| Upstream | Linux/Omarchy |
|---|---|
| SF Pro Text / SF Mono | Inter / JetBrainsMono Nerd Font |
| SF Symbols | redrawn SVG icons (same visual weight) |
| macOS vibrancy | Qt blurred panel background (optional) |
| `.regular` selection highlight | Qt palette highlight (same accent) |
| macOS system accent | Omarchy accent, default blue |
