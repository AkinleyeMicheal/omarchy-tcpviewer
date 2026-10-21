// swift-tools-version:6.0
import PackageDescription
let wiresharkIncludes = [
    "-I/usr/include/glib-2.0", "-I/usr/lib/glib-2.0/include", "-I/usr/include/sysprof-6",
    "-I/usr/include/wireshark",
    // Fallback for headers Arch doesn't ship (epan/iana-ip.h); system headers
    // above always win because they appear first.
    "-I/home/fonsgaudii/Work/TCPViewer/Vendor/Wireshark",
    "-I/usr/include/wireshark",
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
