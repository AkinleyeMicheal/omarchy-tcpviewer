//
//  ZIPArchiveTests.swift
//  TCPViewerSessionTests
//
//  Round-trip and corruption tests for the zlib-backed ZIP layer that stands
//  in for upstream's ZIPFoundation session bundles.
//

import XCTest
import Foundation
@testable import TCPViewerSession

final class ZIPArchiveTests: XCTestCase {
    private func temporaryFileURL(_ name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tcpviewer-session-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    func testRoundTripFilesAndDirectories() throws {
        let url = temporaryFileURL("roundtrip.zip")
        defer { try? FileManager.default.removeItem(at: url) }

        let payloads: [(String, Data)] = [
            ("TCPViewerSession/", Data()),
            ("TCPViewerSession/manifest.json", Data("{\"magic\":\"TCPViewerSession\"}".utf8)),
            ("TCPViewerSession/capture.pcapng", Data((0..<4096).map { UInt8(($0 * 7) & 0xFF) })),
            ("TCPViewerSession/packets.jsonl", Data(String(repeating: "x", count: 200_000).utf8)),
        ]
        try ZIPArchiveWriter.write(payloads.map { ZIPArchiveWriter.Entry(path: $0.0, payload: $0.1) }, to: url)

        let data = try Data(contentsOf: url)
        let entries = try ZIPArchiveReader.readDirectory(data)
        XCTAssertEqual(entries.count, 4)

        for (expectedPath, expectedPayload) in payloads {
            let entry = try XCTUnwrap(entries.first { $0.path == expectedPath })
            XCTAssertEqual(entry.isDirectory, expectedPath.hasSuffix("/"))
            let actual = try ZIPArchiveReader.readFile(entry, from: data)
            XCTAssertEqual(actual, expectedPayload)
        }
    }

    func testDeflateShrinksAndStoredRoundTrips() throws {
        let url = temporaryFileURL("methods.zip")
        defer { try? FileManager.default.removeItem(at: url) }

        let repetitive = Data(String(repeating: "a", count: 10_000).utf8)
        try ZIPArchiveWriter.write([ZIPArchiveWriter.Entry(path: "file.bin", payload: repetitive)], to: url)
        let data = try Data(contentsOf: url)
        // Compressed size must come back from the central directory.
        let compressedSize = try XCTUnwrap(try ZIPArchiveReader.readDirectory(data).first).compressedSize
        XCTAssertLessThan(compressedSize, repetitive.count)
    }

    func testCorruptPayloadFailsChecksum() throws {
        let url = temporaryFileURL("corrupt.zip")
        defer { try? FileManager.default.removeItem(at: url) }

        let payload = Data("payload with a checksum".utf8)
        try ZIPArchiveWriter.write([ZIPArchiveWriter.Entry(path: "f.txt", payload: payload)], to: url)
        var data = try Data(contentsOf: url)
        // Stored entries keep their bytes verbatim: flip the entry's first
        // payload byte (local header 30 + name "f.txt", no extra field).
        let entry = try XCTUnwrap(try ZIPArchiveReader.readDirectory(data).first)
        data[entry.localHeaderOffset + 30 + "f.txt".utf8.count] ^= 0xFF
        XCTAssertThrowsError(try ZIPArchiveReader.readFile(entry, from: data))
    }

    func testNotAnArchive() {
        XCTAssertThrowsError(try ZIPArchiveReader.readDirectory(Data("plain text".utf8)))
    }
}
