# ADR-1: Swift daemon reusing upstream core

Status: Accepted (2026-10-20)

## Context

Upstream's `PcapPlusPlusCore` (15,134 lines) is pure Swift + Foundation +
libpcap + a C-ABI Wireshark shim. Darwin-specific coupling is limited to
`import Darwin` (POSIX calls), one SystemConfiguration file (interface
friendly names), and Darwin notification centers (CLI transport). The Wireshark
integration is a clean C boundary (`WiresharkEpanShim.h`) that builds natively
on Linux.

## Decision

Port `PcapPlusPlusCore` to run inside a Linux daemon (`tcpviewerd`) with
minimal substitutions (Glibc imports, getifaddrs-based interface naming,
Unix-socket IPC replacing Darwin notifications). The Qt Quick app and Omarchy
plugin speak the documented upstream JSON contract (schema_version 1) to the
daemon.

## Consequences

- Highest fidelity: identical capture/dissection behavior to upstream.
- Upstream's test suite and pcap fixtures serve as our regression suite.
- Swift toolchain is a build-time requirement (users get prebuilt binaries
  via AUR; contributors use swiftly or the official tarball).
- UI must be rewritten in QML regardless; view models serve as the spec.

# ADR-2: Strip PRO licensing, Sparkle, Sentry, analytics

Status: Accepted (2026-10-20)

All functionality ships open under GPL-2.0-or-later. No license service,
no gating, no telemetry. License CLI commands are removed.

# ADR-3: Pure-QML diff for v1

Status: Accepted (2026-10-20)

Side-by-side/unified diff implemented in QML. Qt WebEngine + Monaco deferred
(post-v1 consideration).

# ADR-4: /proc-based app attribution for v1

Status: Accepted (2026-10-20)

Socket inode → /proc/<pid> mapping for local-traffic app attribution.
eBPF is the planned upgrade path. Domain/IP grouping unaffected.

# ADR-5: Snapshot import of upstream code

Status: Accepted (2026-10-20)

One-time GPL-compliant import with preserved copyright headers and NOTICE
attribution; independent evolution thereafter.

## ADR-6: UI fidelity — upstream-faithful QML with optional Omarchy theme remap (2026-10-21)

The upstream AppKit UI (57k lines) cannot run on Linux. Phase 4 rebuilds it
in QML using the AppKit source as a forensic spec: layout, columns,
shortcuts, menus, and all colors are extracted 1:1 into design tokens.
Non-portable assets are substituted: SF Pro → Inter (Omarchy's font) at
matching sizes, SF Symbols → redrawn SVGs, macOS vibrancy → Qt blur.

Default appearance is the exact upstream look. An optional
"Follow Omarchy theme" setting remaps only the color tokens onto the active
Omarchy/Catppuccin palette; layout and interactions are identical either way.
