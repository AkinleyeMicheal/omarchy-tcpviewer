//
//  WiresharkDependencyPinTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 12/7/26.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

@Suite(.serialized)
struct WiresharkDependencyPinTests {
    // Linux divergence: Omarchy TCPViewer links the SYSTEM Wireshark
    // (Arch: wireshark-cli) instead of upstream's patched vendored 4.6.6
    // checkout. These tests pin that policy: the published metadata must
    // declare the system dependency, the development files the daemon
    // builds against must be installed, and pkg-config must report a
    // version at or above the 4.7 floor the shim relies on
    // (col_dissect hf_id initialization, dfvm tree asserts, follow tap
    // stream_id).

    private static let minimumMajor = 4
    private static let minimumMinor = 7

    @Test func publishedPinUsesSystemWiresharkDependency() {
        #expect(PcapPlusPlusCoreModule.wiresharkPinnedTag == "system")
        #expect(PcapPlusPlusCoreModule.wiresharkPinnedCommit == "n/a (system library)")
    }

    @Test func systemWiresharkDevelopmentFilesAreInstalled() {
        #expect(FileManager.default.fileExists(atPath: "/usr/include/wireshark/epan/epan.h"))
        #expect(FileManager.default.fileExists(atPath: "/usr/include/wireshark/wiretap/wtap.h"))
    }

    @Test func systemWiresharkVersionMeetsShimFloor() throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkg-config")
        process.arguments = ["--modversion", "wireshark"]
        process.standardOutput = output
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let version = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(process.terminationStatus == 0)

        let components = version.split(separator: ".").compactMap { Int($0) }
        #expect(components.count >= 2)
        let major = components.first ?? 0
        let minor = components.count > 1 ? components[1] : 0
        #expect(
            (major, minor) >= (Self.minimumMajor, Self.minimumMinor),
            "system Wireshark \(version) is older than \(Self.minimumMajor).\(Self.minimumMinor)"
        )
    }
}
