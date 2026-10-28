// swift-tools-version:6.0
// Omarchy TCPViewer daemon package.
//
// Compiles the ported upstream capture/dissection core (GPL-2.0-or-later,
// see ../NOTICE) against the SYSTEM Wireshark development files
// (Arch: wireshark-cli). Never mix in vendored Wireshark 4.6 headers —
// ABI drift against the system 4.x libs segfaults (proven in spikes #1).
import PackageDescription

// All Wireshark/glib headers come from the system. Order matters: glib
// before wireshark; each -I must exist on the build machine.
let wiresharkIncludes = [
    "-I/usr/include/glib-2.0",
    "-I/usr/lib/glib-2.0/include",
    "-I/usr/include/sysprof-6",
    "-I/usr/include/wireshark",
]

let package = Package(
    name: "OmarchyTCPViewer",
    targets: [
        // C/C++ shim around libwireshark/wiretap/wsutil (embedded, plugin-free
        // design inherited from upstream). Vendored GPL file: vendor/ipaddr/ipaddr.c.
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

        // Ported upstream core (Swift). Callback/DispatchQueue based per
        // upstream AGENTS.md — no async/await.
        .target(
            name: "PcapPlusPlusCore",
            dependencies: ["TCPViewerWiresharkEpanShim"],
            exclude: ["Dissection/Spicy/README.md"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // Wire protocol shared by tcpviewerd, tcpviewer-cli and tcpviewer-mcp:
        // newline-delimited JSON, schema_version 1 (contract modeled on the
        // upstream CLI.md response envelope).
        .target(
            name: "TCPViewerIPC",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // Overview page aggregates (charts, top rows, TCP analysis): ported
        // upstream CaptureOverviewService/Classifier as a recompute-from-
        // buffer engine, with its schema_version 1 serialization.
        .target(
            name: "TCPViewerOverview",
            dependencies: ["PcapPlusPlusCore", "TCPViewerIPC"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // System zlib interop for the session-bundle ZIP layer (stands in
        // for upstream's ZIPFoundation; no new external dependency beyond
        // the libz every distro ships).
        .systemLibrary(
            name: "CZlib"
        ),

        // .tcpviewsession ZIP bundle read/write (upstream TCPViewSession
        // format: manifest + pcapng + JSON sidecars).
        .target(
            name: "TCPViewerSession",
            dependencies: ["PcapPlusPlusCore", "CZlib"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("z"),
            ]
        ),

        // The daemon: owns capture sources, runs the Unix-socket JSON server.
        .executableTarget(
            name: "tcpviewerd",
            dependencies: ["PcapPlusPlusCore", "TCPViewerIPC", "TCPViewerOverview", "TCPViewerSession"],
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

        // Thin CLI over the socket. Links NO Wireshark/capture libraries.
        .executableTarget(
            name: "tcpviewer-cli",
            dependencies: ["TCPViewerIPC"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        .testTarget(
            name: "TCPViewerIPCTests",
            dependencies: ["TCPViewerIPC"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // Overview engine tests: classifier pins + snapshot math (upstream
        // parity gate for the charts).
        .testTarget(
            name: "TCPViewerOverviewTests",
            dependencies: ["TCPViewerOverview"],
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

        // Session-bundle format tests: ZIP round-trip + record codecs
        // (parity gate for .tcpviewsession export/import).
        .testTarget(
            name: "TCPViewerSessionTests",
            dependencies: ["TCPViewerSession"],
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

        // Upstream fixture/core test suite (ported from the macOS Xcode
        // project's PcapPlusPlusCoreTests) as the phase-3 regression gate.
        .testTarget(
            name: "PcapPlusPlusCoreTests",
            dependencies: ["PcapPlusPlusCore"],
            resources: [.copy("Fixtures")],
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
    ]
)
