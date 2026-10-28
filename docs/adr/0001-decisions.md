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

## ADR-7: System Wireshark (>= 4.7) instead of the vendored 4.6.6 checkout

Status: Accepted (2026-10-22)

Upstream vendors and patches Wireshark 4.6.6 (pinned commit
`3a22c3e`, built via `scripts/bootstrap-wireshark.sh`). Omarchy TCPViewer
builds the daemon against the SYSTEM Wireshark development files instead
(Arch: `wireshark-cli`, currently 4.7.3; headers under
`/usr/include/wireshark`). Rationale: security updates arrive through
pacman, no second copy of libwireshark is shipped or ABI-mixed (mixing the
vendored 4.6 headers with system 4.x libs segfaulted in spike #1), and the
GPL-2.0-or-later obligations stay simple. The only vendored GPL file left
is `vendor/ipaddr/ipaddr.c` (dfilter `ipaddr` plugin, patched to
`<epan/iana-info.h>`).

Consequences — behaviors 4.7 changed that the shim must reproduce
(each fix carries an explanatory comment in the shim):

- `col_dissect()` (new in 4.7) reads `col_item_t.hf_id`, which only
  `build_column_format_array()` initializes. The shim's two-column fast
  path must set `hf_id` from `proto_registrar_get_id_byname()` before use;
  otherwise recycled heap values reach `PROTO_REGISTRAR_GET_NTH`
  ("Unregistered hf." DissectorError, permanent Swift-fallback
  degradation).
- `dfvm_apply_full()` asserts a non-null `proto_tree`. Tap listeners carry
  their own compiled filter (`tl->code`, from `register_tap_listener`'s
  fstring) which 4.7 applies during tap delivery. While the stream-follow
  tap is registered, both the follow re-dissection and the shared
  first-pass dissector must build a tree; the first pass returns to the
  upstream tree-less fast path when follow ends.
- The follow tap handler now drops packets whose `stream_id` differs from
  `follow_info->stream_id`; the shim sets that field (one-line divergence
  from upstream, documented in the shim).
- Linux diagnosability addition: critical-exception reports carry the raw
  GLib message (`except_message`) and log it as `Wireshark Message:`.
  Upstream keeps it out of on-disk logs; the corresponding test
  expectation is flipped with a comment.

Port behavior notes:

- The native core's ObjC-style `error:` out-parameters are reproduced with
  `NSError?`. `TCPViewerCoreError.nativeBridgeNSError` round-trips code and
  message through `com.proxyman.tcpviewer.NativeBridge` so
  `NativeBridgeMapper.coreError` does not degrade every failure to the
  call site's default.
- `PcapPlusPlusCoreModule` metadata names the system dependency
  (`wiresharkPinnedTag == "system"`); `WiresharkDependencyPinTests` enforces
  the >= 4.7 floor via pkg-config.
- Regression gate: the upstream `PcapPlusPlusCoreTests` suite is ported
  into `daemon/Tests/PcapPlusPlusCoreTests` and must run with
  `swift test --no-parallel` (the epan session is process-global; parallel
  suites contend it). 166 core + 18 overview + 12 IPC + 10 session
  tests pass.

Session-bundle decision (Phase B slice 2, 2026-10-28):

- The `.tcpviewsession` format is a ZIP archive rooted at `TCPViewerSession/`
  (manifest.json, capture.pcapng, packets.jsonl, clients.json,
  annotations.json, state.json, icons/). Record shapes are byte-compatible
  with the macOS app so files interchange both ways.
- Upstream uses ZIPFoundation. The daemon implements the needed ZIP subset on
  the system zlib through a `CZlib` systemLibrary target (`-lz`): reader =
  EOCD scan + central-directory parse + stored(0)/deflate(8) extraction with
  CRC verification; writer = deflated payloads, stored directory entries,
  atomic temp-file replace. No ZIP64, encryption, data descriptors or
  streaming; no new external dependency (zlib ships in the base system).
- Import mirrors upstream `TCPViewSessionImportService`: archive path safety
  before extraction (no absolute paths, no `..`, no symlinks, all entries
  under `TCPViewerSession/`), manifest validation (magic + schema version),
  record sanitization (packetID == packet.id, captureOrdinal range and
  uniqueness, known clientIDs) with upstream's failedFlowCount accounting,
  annotation rehydration. Session files import alone (upstream rule).
- The source wraps an inner pcapng document (`SessionBundleDocument`):
  inspect/follow/export run against the inner capture with session↔inner
  packet-ID remapping (position-based by captureOrdinal, inner followStreamID
  applied); display filters forward to the inner document with
  ID-translated result batches; `save` reports the upstream read-only error.
- state.json is authored minimal-but-valid by the daemon (empty
  pins/savedPackets/customFilters/importedFiles + default quick-filter and
  structured-filter records) and passes through unsanitized on import until
  the app-state round-trip phase; upstream still reads our files.
