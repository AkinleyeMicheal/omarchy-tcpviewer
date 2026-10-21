#!/usr/bin/env bash
# Spike #1 setup: compile + link upstream PcapPlusPlusCore on Linux.
# Rebuilds the spike package from the pristine upstream checkout at
# ~/Work/TCPViewer (sparse clone, commit 56e72b9 + pinned Vendor submodules).
#
# All patches below are the minimal Linux compatibility layer; they are
# candidates for upstreaming/landing in daemon/ in Phase 3.
set -euo pipefail

UPSTREAM=~/Work/TCPViewer
SPIKE="$(cd "$(dirname "$0")" && pwd)"
WS="$UPSTREAM/Vendor/Wireshark"
GEN="$SPIKE/gen-include"

export PATH="$HOME/.local/share/swift/toolchain/usr/bin:$PATH"

# --- 1. Sources -------------------------------------------------------------
rm -rf "$SPIKE/Sources"
mkdir -p "$SPIKE/Sources/PcapPlusPlusCore" "$SPIKE/Sources/TCPViewerWiresharkEpanShim/include" "$SPIKE/Sources/spike-cli" "$GEN"

cp -r "$UPSTREAM/PcapPlusPlusCore/." "$SPIKE/Sources/PcapPlusPlusCore/"

# C/C++ shim becomes its own SPM target (SPM forbids mixed-language targets)
cd "$SPIKE/Sources/PcapPlusPlusCore"
mv Dissection/WiresharkEpanShim.cpp Dissection/WiresharkEpanShim.h \
   Dissection/WiresharkIPDisplayFilterPlugin.c "$SPIKE/Sources/TCPViewerWiresharkEpanShim/"
mv "$SPIKE/Sources/TCPViewerWiresharkEpanShim/WiresharkEpanShim.h" \
   "$SPIKE/Sources/TCPViewerWiresharkEpanShim/include/"

# The IP display-filter plugin #includes Wireshark's own ipaddr.c source
sed -i \
  's|#include "\.\./\.\./Vendor/Wireshark/plugins/epan/dfilter/ipaddr/ipaddr.c"|#include "'"$HOME"'/Work/TCPViewer/Vendor/Wireshark/plugins/epan/dfilter/ipaddr/ipaddr.c"|' \
  "$SPIKE/Sources/TCPViewerWiresharkEpanShim/WiresharkIPDisplayFilterPlugin.c"

# --- 2. Wireshark headers -----------------------------------------------------
# Compile against SYSTEM headers (/usr/include/wireshark, 4.7.3) so shim
# signatures match the system libraries we link at runtime. The vendored 4.6
# submodule (used on macOS) is kept for reference only — mixing its headers
# with 4.7 libs crashes (e.g. wtap_init/epan_init gained parameters).
SYS_WS=/usr/include/wireshark
if [ ! -f "$SYS_WS/ws_version.h" ]; then
    echo "ERROR: system Wireshark headers not found at $SYS_WS" >&2
    exit 1
fi
GEN="$SYS_WS"

# --- 3. Swift/Linux compatibility patches ------------------------------------
# 3a. import Darwin -> conditional Glibc import (5 files)
grep -rln '^import Darwin$' . --include='*.swift' | while read -r f; do
  python3 - "$f" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('import Darwin\n', '#if canImport(Darwin)\nimport Darwin\n#else\nimport Glibc\n#endif\n', 1)
open(p, 'w').write(s)
PYEOF
done

# 3b. SystemConfiguration resolver -> Linux stub (real getifaddrs impl in Phase 3)
python3 - <<'PYEOF'
import re
p = 'NativeBridge/NativeBridgeSupport.swift'
s = open(p).read()
s = s.replace('import SystemConfiguration\n', '')
stub = '''private enum SystemNetworkInterfaceNameResolver {
    // Linux port: macOS SCNetworkService name resolution is unavailable.
    // Phase 3 replaces this with getifaddrs/NetworkManager-based naming.
    static func friendlyName(for technicalName: String) -> String? { nil }

    static func normalizedName(_ name: String?, technicalName: String) -> String? {
        guard let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedName.isEmpty else {
            return nil
        }
        let lowercasedName = trimmedName.lowercased()
        if lowercasedName == technicalName.lowercased() ||
            lowercasedName == "no description available" {
            return nil
        }
        return trimmedName
    }
}'''
pattern = re.compile(r'private enum SystemNetworkInterfaceNameResolver \{.*?\n\}\n\n(?=#if DEBUG)', re.S)
if not pattern.search(s):
    raise SystemExit('SystemNetworkInterfaceNameResolver pattern not found')
s = pattern.sub(stub + '\n\n', s)
open(p, 'w').write(s)
PYEOF

# 3c. Protected.swift Linux lock: fileprivate cannot satisfy public Lock protocol
sed -i 's/    fileprivate func lock() {/    func lock() {/; s/    fileprivate func unlock() {/    func unlock() {/' Models/Protected.swift

# 3d. Cross-platform shims (ObjC pointer type, autoreleasepool, Darwin POSIX calls)
cat > LinuxCompat.swift <<'EOF'
// Linux compatibility shims for the Omarchy TCPViewer port.
// AutoreleasingUnsafeMutablePointer exists only with the ObjectiveC runtime;
// on Linux, C `NSError **`-style out-parameters import as UnsafeMutablePointer.
#if os(Linux)
public typealias AutoreleasingUnsafeMutablePointer<Pointee> = UnsafeMutablePointer<Pointee>
#endif

#if os(Linux)
import Glibc

/// Linux has no autorelease pools; drain eagerly (no-op).
public func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}

/// Minimal stand-in so upstream `Darwin.close/pread/dup` call sites compile.
/// The real calls go straight to Glibc.
enum Darwin {
    static func close(_ fd: Int32) -> Int32 { Glibc.close(fd) }
    static func dup(_ fd: Int32) -> Int32 { Glibc.dup(fd) }
    static func pread(
        _ fd: Int32, _ buf: UnsafeMutableRawPointer, _ n: Int, _ offset: off_t
    ) -> Int {
        Glibc.pread(fd, buf, n, offset)
    }
}
#endif
EOF

# 3e. Darwin xattr signatures (Linux drops the position argument; needs user. namespace)
cat > LinuxXAttrCompat.swift <<'EOF'
// Linux compatibility: match Darwin's xattr signatures so upstream call
// sites compile unchanged. Linux requires a namespace prefix (user.) for
// unprivileged extended attributes.
#if os(Linux)
import Glibc

@_silgen_name("setxattr")
private func _tcv_setxattr(
    _ path: UnsafePointer<CChar>, _ name: UnsafePointer<CChar>,
    _ value: UnsafeRawPointer?, _ size: Int, _ flags: Int32
) -> Int32

@_silgen_name("getxattr")
private func _tcv_getxattr(
    _ path: UnsafePointer<CChar>, _ name: UnsafePointer<CChar>,
    _ value: UnsafeMutableRawPointer?, _ size: Int
) -> Int

@_silgen_name("removexattr")
private func _tcv_removexattr(
    _ path: UnsafePointer<CChar>, _ name: UnsafePointer<CChar>, _ flags: Int32
) -> Int32

private func namespaced(_ name: String) -> String {
    name.hasPrefix("user.") || name.hasPrefix("trusted.") || name.hasPrefix("security.")
        ? name : "user." + name
}

func setxattr(
    _ path: String, _ name: String, _ value: UnsafeRawPointer?,
    _ size: Int, _ position: UInt32, _ options: Int32
) -> Int32 {
    path.withCString { p in
        namespaced(name).withCString { n in
            _tcv_setxattr(p, n, value, size, options)
        }
    }
}

func getxattr(
    _ path: String, _ name: String, _ value: UnsafeMutableRawPointer?,
    _ size: Int, _ position: UInt32, _ options: Int32
) -> Int {
    path.withCString { p in
        namespaced(name).withCString { n in
            _tcv_getxattr(p, n, value, size)
        }
    }
}

func removexattr(_ path: String, _ name: String, _ options: Int32) -> Int32 {
    path.withCString { p in
        namespaced(name).withCString { n in
            _tcv_removexattr(p, n, options)
        }
    }
}
#endif
EOF

# 3f. C++ shim: Wireshark 4.7 runtime-init deltas vs vendored 4.6 headers.
#     (a) init_process_policies() must precede configuration_init()
#     (b) CurrentExecutablePath() must yield a real path on Linux or
#         configuration_init() dereferences garbage -> SIGSEGV
python3 - <<'PYEOF'
p = '../TCPViewerWiresharkEpanShim/WiresharkEpanShim.cpp'
s = open(p).read()

# (a) process policies before configuration_init. The declaration must be at
# file scope: block-scope extern "C" is illegal, and a plain block-scope extern
# would be captured by the surrounding anonymous namespace.
old = '''        // Wireshark resolves bundled data relative to the host executable path.
        const auto executablePath = CurrentExecutablePath();
        if (char *configurationError = configuration_init(executablePath.c_str())) {'''
new = '''        // Wireshark resolves bundled data relative to the host executable path.
        const auto executablePath = CurrentExecutablePath();
        // Wireshark >= 4.7 asserts in started_with_special_privs() unless process
        // policies are initialized first (the vendored 4.6 headers predate this).
        init_process_policies();
        if (char *configurationError = configuration_init(executablePath.c_str())) {'''
if old not in s:
    raise SystemExit('configuration_init anchor not found in WiresharkEpanShim.cpp')
s = s.replace(old, new, 1)

decl_anchor = 'class WiresharkRuntime {'
if s.count(decl_anchor) != 1:
    raise SystemExit(f'WiresharkRuntime class anchor count {s.count(decl_anchor)} != 1')
s = s.replace(decl_anchor,
              '// Wireshark >= 4.7: process policies must precede configuration_init().\n'
              'extern "C" void init_process_policies(void);\n\n' + decl_anchor, 1)

# (b) Linux branch for CurrentExecutablePath (readlink /proc/self/exe)
old_exe = '''    }
#endif
    return "TCPViewer";
}'''
new_exe = '''    }
#elif defined(__linux__)
    std::vector<char> linuxPathBuffer(4096);
    const ssize_t linuxPathLength = readlink("/proc/self/exe", linuxPathBuffer.data(), linuxPathBuffer.size() - 1);
    if (linuxPathLength > 0) {
        linuxPathBuffer[static_cast<size_t>(linuxPathLength)] = '\\0';
        return std::string(linuxPathBuffer.data());
    }
#endif
    return "TCPViewer";
}'''
if s.count(old_exe) != 1:
    raise SystemExit(f'CurrentExecutablePath anchor count {s.count(old_exe)} != 1')
s = s.replace(old_exe, new_exe, 1)

# readlink() needs <unistd.h>
first_include = '#include'
idx = s.index(first_include)
line_end = s.index('\n', idx)
s = s[:line_end + 1] + '#include <unistd.h>\n' + s[line_end + 1:]

open(p, 'w').write(s)
print('patched WiresharkEpanShim.cpp: init_process_policies + Linux CurrentExecutablePath')
PYEOF

# 3g. Wireshark 4.6 -> 4.7 API deltas in the shim (compiled against system headers).
python3 - <<'PYEOF'
p = '../TCPViewerWiresharkEpanShim/WiresharkEpanShim.cpp'
s = open(p).read()

def replace_once(old, new, label):
    global s
    if s.count(old) != 1:
        raise SystemExit(f'{label}: anchor count {s.count(old)} != 1')
    s = s.replace(old, new, 1)

# configuration_init() gained app_flavor_lower
replace_once(
    'configuration_init(executablePath.c_str())',
    'configuration_init(executablePath.c_str(), "tcpviewer")',
    'configuration_init')

# wtap_init() gained (env prefix, file extensions, count).
# The prefix is whitelist-matched inside register_pcapng(): only "WIRESHARK"
# or "STRATOSHARK" register the pcapng file type; anything else early-returns
# leaving pcapng_file_type_subtype == -1 (fatal on open) and its handler
# hash tables NULL (GLib criticals).
replace_once(
    'wtap_init(false);',
    'wtap_init(false, "WIRESHARK", NULL, 0);',
    'wtap_init')

# epan_init() gained epan_app_data_t*. 4.7 dereferences it unconditionally
# (env prefix, column defaults, dissector registration) — NULL crashes, and
# skipping register_func would leave zero dissectors registered. The values
# below reproduce the vendored 4.6 behavior: proto_init() hardcoded
# register_all_protocols, and pre_init_prefs() hardcoded the standard
# 7 columns the shim reads back via prefs.num_cols.
replace_once('#include <unistd.h>',
             '#include <unistd.h>\n#include <epan/register.h>',
             'register.h include')
replace_once(
    'class WiresharkRuntime {',
    '''// Wireshark 4.7 moved dissector registration, column defaults, and the env
// prefix out of epan_init() into an app-provided descriptor. Column pairs
// mirror the vendored 4.6 pre_init_prefs() defaults (title, format) so
// prefs.num_cols == 7 exactly as before.
static epan_app_data_t tcpViewerEpanAppData()
{
    static const char *columnFormatPairs[] = {
        "No.", "%m", "Time", "%t", "Source", "%s", "Destination", "%d",
        "Protocol", "%p", "Length", "%L", "Info", "%i",
    };
    epan_app_data_t appData{};
    appData.env_var_prefix = "TCPVIEWER";
    appData.col_fmt = columnFormatPairs;
    appData.num_cols = sizeof(columnFormatPairs) / sizeof(columnFormatPairs[0]) / 2;
    appData.register_func = register_all_protocols;
    appData.handoff_func = register_all_protocol_handoffs;
    appData.tap_reg_listeners = nullptr;
    return appData;
}

class WiresharkRuntime {''',
    'epan_app_data helper')
replace_once(
    '''didInitializeEpan = epan_init(nullptr, nullptr, false);''',
    '''auto appData = tcpViewerEpanAppData();
                didInitializeEpan = epan_init(nullptr, nullptr, false, &appData);''',
    'epan_init call')

# packet_provider_funcs gained get_start_ts/get_end_ts after get_frame_ts
replace_once(
    'const struct packet_provider_funcs kPacketProviderFuncs = {',
    '''const nstime_t *ProviderGetSessionStartTimestamp(packet_provider_data *)
{
    return nullptr;
}

const nstime_t *ProviderGetSessionEndTimestamp(packet_provider_data *)
{
    return nullptr;
}

const struct packet_provider_funcs kPacketProviderFuncs = {''',
    'packet_provider_funcs decl')

replace_once(
    '''    ProviderGetFrameTimestamp,
    ProviderGetInterfaceName,''',
    '''    ProviderGetFrameTimestamp,
    ProviderGetSessionStartTimestamp,
    ProviderGetSessionEndTimestamp,
    ProviderGetInterfaceName,''',
    'packet_provider_funcs init')

open(p, 'w').write(s)
print('patched WiresharkEpanShim.cpp: Wireshark 4.7 API deltas (configuration_init/wtap_init/epan_init/packet_provider_funcs)')
PYEOF

cd "$SPIKE"

# --- 4. Manifest -------------------------------------------------------------
cat > Package.swift <<EOF
// swift-tools-version:6.0
import PackageDescription
let wiresharkIncludes = [
    "-I/usr/include/glib-2.0", "-I/usr/lib/glib-2.0/include", "-I/usr/include/sysprof-6",
    "-I/usr/include/wireshark",
    // Fallback for headers Arch doesn't ship (epan/iana-ip.h); system headers
    // above always win because they appear first.
    "-I$WS",
    "-I$GEN",
]
let package = Package(
    name: "PcapPlusPlusCore",
    targets: [
        .target(
            name: "TCPViewerWiresharkEpanShim",
            cSettings: [
                .headerSearchPath("include"),
                .unsafeFlags(wiresharkIncludes),
            ],
            cxxSettings: [
                .headerSearchPath("include"),
                .unsafeFlags(wiresharkIncludes),
            ],
            linkerSettings: [
                .linkedLibrary("pcap"),
                .linkedLibrary("glib-2.0"),
                .linkedLibrary("gobject-2.0"),
                .linkedLibrary("gmodule-2.0"),
            ]
        ),
        .executableTarget(
            name: "spike-cli",
            dependencies: ["PcapPlusPlusCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("wireshark"),
                .linkedLibrary("wiretap"),
                .linkedLibrary("wsutil"),
                .linkedLibrary("glib-2.0"),
                .linkedLibrary("gobject-2.0"),
                .linkedLibrary("gmodule-2.0"),
                .linkedLibrary("pcap"),
            ]
        ),
        .target(
            name: "PcapPlusPlusCore",
            dependencies: ["TCPViewerWiresharkEpanShim"],
            exclude: ["Dissection/Spicy/README.md"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
EOF

# --- 5. Spike harness --------------------------------------------------------
cat > Sources/spike-cli/main.swift <<'EOF'
import Foundation
import PcapPlusPlusCore

// Omarchy TCPViewer Spike #1: prove the upstream core links against system
// libwireshark and dissects a real capture end-to-end on Linux.
print("spike: PcapPlusPlusCore linked OK")

let fixture = NSString(string: "~/Work/TCPViewer/PcapPlusPlusCoreTests/Fixtures/CaptureFiles/tinyshield-sanitized-sample.pcapng")
    .expandingTildeInPath

guard FileManager.default.fileExists(atPath: fixture) else {
    print("spike: fixture missing at \(fixture)")
    exit(2)
}

let core = NativeTCPViewerCore()
let done = DispatchSemaphore(value: 0)
var outcome = "timeout"

core.loadPacketSummaries(from: URL(fileURLWithPath: fixture)) { result in
    switch result {
    case .success(let summaries):
        outcome = "success: \(summaries.count) packets"
        for summary in summaries {
            outcome += "\n  #\(summary.packetNumber) \(summary.protocolSummary ?? "?") — \(summary.infoSummary)"
        }
    case .failure(let error):
        outcome = "failure: \(error)"
    }
    done.signal()
}

_ = done.wait(timeout: .now() + 30)
print("spike result: \(outcome)")
exit(outcome.hasPrefix("success") ? 0 : 1)
EOF

echo "setup complete: $SPIKE"
