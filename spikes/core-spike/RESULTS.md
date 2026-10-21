# Spike #1 — Upstream core compiles, links, and dissects on Linux

**Status: PASSED** (2026-10-21, Omarchy x86_64)

## Verdict

The full upstream `PcapPlusPlusCore` Swift core (11,576 lines) compiles with
Swift 6.4.1, links against **system libwireshark 4.7.3** (Arch `wireshark-cli`
package), initializes the Wireshark epan runtime, and dissects a real pcapng
fixture end-to-end with output **byte-for-byte identical to tshark**:

```
$ spike-cli
spike: PcapPlusPlusCore linked OK
spike result: success: 2 packets
  #1 UDP — 4000 → 5000 Len=4[Malformed Packet]
  #2 DNS — Standard query response 0x1234 A www.example.com A 93.184.216.34
```

tshark ground truth (`tshark -r tinyshield-sanitized-sample.pcapng`):

```
1 eth:ethertype:ip:udp:tapa  192.168.0.1 → 192.168.0.2  UDP  4000 → 5000 Len=4[Malformed Packet]
2 eth:ethertype:ip:udp:dns   192.168.0.2 → 192.168.0.1  DNS  Standard query response 0x1234 A www.example.com A 93.184.216.34
```

The `[Malformed Packet]` expert annotation on packet 1 is intentional fixture
content (a `tapa`-dissected test packet), reproduced identically.

## How to reproduce

```sh
bash setup.sh && swift build
.build/out/Products/Debug-linux-x86_64/spike-cli
```

`setup.sh` rebuilds `Sources/` from the pristine upstream checkout at
`~/Work/TCPViewer` (commit `56e72b9`) and applies every Linux patch below as
code — the spike is fully reproducible from upstream + this script.

## Key finding: use SYSTEM Wireshark, not the vendored 4.6 submodule

The first attempt compiled the shim against the pinned vendored Wireshark
**4.6.6** headers while linking the system **4.7.3** libraries. This crashed
with SIGSEGV at runtime (`configuration_init` → glib), because 4.6→4.7 changed
multiple ABI-relevant signatures. The fix that made everything work: compile
against **system headers** (`/usr/include/wireshark`, shipped by Arch's
`wireshark-cli`), so compile-time signatures always match the linked libraries.
The vendored tree is kept only as a fallback include for headers Arch does not
ship (`epan/iana-ip.h`, a 47-line self-contained table header).

Consequence for Phase 3: the port does **not** need to build vendored Wireshark
at all. Build-dep is just the distro `wireshark` package (headers + libs).
Note: `libwireshark.so.0` SONAME stability means this survives Arch minor
updates; recompilation is cheap (~30 s shim).

## Linux compatibility patch set (all applied by setup.sh)

### Swift side (candidates for upstreaming, small shims)
1. `import Darwin` → `#if canImport(Darwin)` in 5 files.
2. `SystemConfiguration` resolver stubbed (Phase 3: real `getifaddrs` naming).
3. `Protected.swift`: `fileprivate func lock/unlock` → internal (Linux
   stricter about protocol witness access).
4. `LinuxCompat.swift`: `AutoreleasingUnsafeMutablePointer` typealias,
   no-op `autoreleasepool`, `enum Darwin { close, dup, pread }` forwarding
   to Glibc.
5. `LinuxXAttrCompat.swift`: Darwin-signature xattr wrappers via
   `@_silgen_name` (Linux drops `position`; needs `user.` namespace prefix).
6. SPM split: C/C++ shim into its own target `TCPViewerWiresharkEpanShim`
   with `include/` public headers; `swiftLanguageMode(.v5)`.

### C++ shim side (Wireshark 4.6→4.7 API deltas)
7. `init_process_policies()` must precede `configuration_init()` — 4.7
   asserts in `started_with_special_privs()` otherwise. (4.6 did not.)
8. `CurrentExecutablePath()`: added `__linux__` branch via
   `readlink("/proc/self/exe")` — upstream returned a bare `"TCPViewer"`
   string, which made `configuration_init` dereference garbage → SIGSEGV.
9. `configuration_init(arg0, app_flavor_lower)` — gained 2nd arg
   (`"tcpviewer"`).
10. `wtap_init(false, "WIRESHARK", NULL, 0)` — gained 3 args. The prefix is
    **whitelist-matched** inside `register_pcapng()`: only `"WIRESHARK"` or
    `"STRATOSHARK"` register the pcapng file type; anything else silently
    skips it (→ fatal `pcapng_file_type_subtype != -1` assert on open, plus
    NULL-handler GLib criticals).
11. `epan_init(cb, client_data, load_plugins, app_data)` — gained
    `epan_app_data_t*`, dereferenced unconditionally. Filled with
    `env_var_prefix="TCPVIEWER"`, the standard 7-column title/format pairs
    (reproduces 4.6 `pre_init_prefs()` defaults that the shim reads back via
    `prefs.num_cols`), `register_func=register_all_protocols`,
    `handoff_func=register_all_protocol_handoffs` (4.6 hardcoded these
    inside `proto_init`; 4.7 moved them to the app), and
    `tap_reg_listeners=NULL` (explicitly handled; matches upstream shim,
    which never registered builtin taps).
12. `packet_provider_funcs` gained `get_start_ts`/`get_end_ts` after
    `get_frame_ts` (9 fields in 4.7 vs 7) — two stub accessors returning
    NULL (documented as "unavailable").
13. `WiresharkIPDisplayFilterPlugin.c`: absolute include path to vendored
    `plugins/epan/dfilter/ipaddr/ipaddr.c` (compiled against system
    headers; registers the `ip.addr` display-filter functions in the
    plugin-free embedded build).

## Toolchain notes

- Swift 6.4.1 (Ubuntu 24.04 build) at `~/.local/share/swift/toolchain`,
  made self-contained via `patchelf --force-rpath` on 28 binaries plus
  compat symlinks (`libncurses.so.6` → `libncursesw.so.6`,
  `libxml2.so.2` → `libxml2.so.16`, the latter also copied next to
  `libFoundationXML.so` whose own `RUNPATH=$ORIGIN` overrides inheritance).
- No `LD_LIBRARY_PATH` needed anymore.
- Spike builds in ~30 s (incremental: single-file shim edits rebuild in s).

## Risks / open items for the gate

- **Arch Wireshark updates**: `register_pcapng`'s whitelist and
  `epan_app_data_t` layout are 4.7-specific; a future 4.8 bump may add more
  deltas (cheap to re-fix: the spike shows the failure mode is a compile
  error or an init-path assert, not silent corruption).
- **Plugin dissectors**: `epan_init(..., load_plugins=false)` matches the
  upstream embedded design; Arch's packaged plugin dissectors (e.g.
  `/usr/lib/wireshark/plugins/4.7/epan/*.so`) are not loaded. Phase 3
  decides whether to enable them (upstream ships everything statically).
- `get_start_ts`/`get_end_ts` return NULL — verify no statistics feature
  depends on them when Statistics is ported.
