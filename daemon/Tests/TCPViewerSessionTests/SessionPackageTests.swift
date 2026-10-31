//
//  SessionPackageTests.swift
//  TCPViewerSessionTests
//
//  Export/import round-trip and validation-parity tests for the
//  .tcpviewsession package layer (upstream TCPViewSessionImport/ExportService
//  semantics on the daemon's zlib ZIP).
//

import XCTest
import Foundation
import PcapPlusPlusCore
@testable import TCPViewerSession

final class SessionPackageTests: XCTestCase {
    private func makePacket(
        id: UInt64,
        comment: String? = nil,
        textStyle: PacketTextStyle? = nil
    ) -> PacketSummary {
        PacketSummary(
            id: id,
            packetNumber: id,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(id)),
            source: .offline,
            transportHint: .tcp,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: "10.0.0.\(id)", port: 1024 + UInt16(id)),
                destination: PacketEndpoint(address: "10.0.0.1", port: 80)
            ),
            originalLength: 74,
            capturedLength: 74,
            infoSummary: "Packet \(id)",
            layers: [PacketLayer(name: "eth"), PacketLayer(name: "tcp")],
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(
                linkType: .ethernet,
                isTruncated: false,
                packetComment: nil
            ),
            textStyle: textStyle,
            customComment: comment
        )
    }

    private func temporaryFileURL(_ name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tcpviewer-session-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    private func writeBundle(
        packets: [PacketSummary],
        pins: [SessionPinRecord] = [],
        to url: URL
    ) throws {
        var state = TCPViewSessionState(sourceMetadata: TCPViewSessionSourceMetadata(
            fileName: "sample.pcapng",
            filePath: "/tmp/sample.pcapng",
            format: "pcapng",
            packetCount: packets.count
        ))
        state.pins = pins
        try SessionPackage.writePackage(
            packets: packets,
            captureFileData: Data("synthetic-capture-bytes".utf8),
            state: state,
            to: url
        )
    }

    func testWriteAndLoadRoundTrip() throws {
        let url = temporaryFileURL("bundle.tcpviewsession")
        defer { try? FileManager.default.removeItem(at: url) }

        let packets = [
            makePacket(id: 1, comment: "first"),
            makePacket(id: 2),
            makePacket(id: 3, textStyle: PacketTextStyle(highlightColor: .blue)),
        ]
        try writeBundle(packets: packets, to: url)

        let contents = try SessionPackage.loadPackage(at: url)
        defer { try? FileManager.default.removeItem(at: contents.extractionDirectoryURL) }
        XCTAssertEqual(contents.packets.count, 3)
        XCTAssertEqual(contents.packetRecords.map(\.packetID), packets.map(\.id))
        XCTAssertEqual(contents.packetRecords.map(\.captureOrdinal), [0, 1, 2])
        XCTAssertEqual(contents.importReport.importedFlowCount, 3)
        XCTAssertEqual(contents.importReport.failedFlowCount, 0)
        XCTAssertEqual(contents.manifest.magic, TCPViewSessionFormat.magic)
        XCTAssertEqual(contents.manifest.packetCount, 3)
        XCTAssertEqual(contents.state.sourceMetadata?.fileName, "sample.pcapng")
        // Comments and styles rehydrate through the annotations sidecar.
        XCTAssertEqual(contents.packets.first?.customComment, "first")
        XCTAssertEqual(contents.packets.last?.textStyle?.highlightColor, .blue)
        XCTAssertEqual(contents.captureFileURL.lastPathComponent, "capture.pcapng")
        XCTAssertTrue(FileManager.default.fileExists(atPath: contents.captureFileURL.path))
    }

    func testPinRecordsRoundTripThroughStateJSON() throws {
        // C2: pins ride state.json like upstream's document-scoped PacketPin
        // list — decode keeps the fields (placeholders lost them) and the
        // package re-encodes them byte-compatibly for re-export.
        let url = temporaryFileURL("pins-bundle.tcpviewsession")
        defer { try? FileManager.default.removeItem(at: url) }

        let pins = [
            SessionPinRecord(
                id: "domain:example.com", kind: "domain", title: "example.com",
                createdAt: Date(timeIntervalSince1970: 1_760_000_000), domain: "example.com"),
            SessionPinRecord(
                id: "ip:10.0.0.1", kind: "ip", title: "10.0.0.1",
                createdAt: Date(timeIntervalSince1970: 1_760_000_100), ipAddress: "10.0.0.1"),
            SessionPinRecord(
                id: "client:/usr/bin/curl", kind: "client", title: "curl",
                createdAt: Date(timeIntervalSince1970: 1_760_000_200),
                clientKey: "/usr/bin/curl", clientDisplayName: "curl"),
        ]
        try writeBundle(packets: [makePacket(id: 1)], pins: pins, to: url)

        let contents = try SessionPackage.loadPackage(at: url)
        defer { try? FileManager.default.removeItem(at: contents.extractionDirectoryURL) }
        XCTAssertEqual(contents.state.pins, pins)
        XCTAssertEqual(contents.state.pins.first?.domain, "example.com")
        XCTAssertEqual(contents.state.pins[1].ipAddress, "10.0.0.1")
        XCTAssertEqual(contents.state.pins.last?.clientKey, "/usr/bin/curl")
    }

    func testSessionPinKeepsUpstreamCamelCaseKeys() throws {
        // The session JSON is upstream-interchange: PacketPin fields encode
        // camelCase with an iso8601 createdAt, same as the macOS app.
        let pin = SessionPinRecord(
            id: "domain:example.com", kind: "domain", title: "example.com",
            createdAt: Date(timeIntervalSince1970: 1_760_000_000), domain: "example.com")
        let data = try TCPViewerSession.TCPViewSessionCodec.encodeJSON([pin])
        let payload = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(payload.contains("\"id\""), payload)
        XCTAssertTrue(payload.contains("\"createdAt\""), payload)
        XCTAssertTrue(payload.contains("\"domain\""), payload)
        let decoded = try TCPViewSessionCodec
            .decodeJSON([SessionPinRecord].self, from: data)
        XCTAssertEqual(decoded, [pin])
    }

    func testWrongMagicIsRejected() throws {
        let url = temporaryFileURL("wrongmagic.zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeBundle(packets: [makePacket(id: 1)], to: url)
        try rewriteArchiveEntry(url, "TCPViewerSession/manifest.json") { payload in
            String(data: payload, encoding: .utf8)!
                .replacingOccurrences(of: TCPViewSessionFormat.magic, with: "SomethingElse")
        }
        XCTAssertThrowsError(try SessionPackage.loadPackage(at: url)) { error in
            let message = (error as? TCPViewerCoreError)?.message ?? ""
            XCTAssertTrue(message.contains("not a TCPViewer session"), message)
        }
    }

    func testFutureSchemaIsRejected() throws {
        let url = temporaryFileURL("future-schema.zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeBundle(packets: [makePacket(id: 1)], to: url)
        try rewriteArchiveEntry(url, "TCPViewerSession/manifest.json") { payload in
            String(data: payload, encoding: .utf8)!
                .replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":99")
        }
        XCTAssertThrowsError(try SessionPackage.loadPackage(at: url)) { error in
            let message = (error as? TCPViewerCoreError)?.message ?? ""
            XCTAssertTrue(message.contains("unsupported schema version"), message)
        }
    }

    /// Replaces one entry's payload inside the archive, keeping every other
    /// entry intact (the manifest edit tests above).
    private func rewriteArchiveEntry(
        _ url: URL,
        _ path: String,
        transform: (Data) -> String
    ) throws {
        let data = try Data(contentsOf: url)
        let entries = try ZIPArchiveReader.readDirectory(data)
        var rewritten: [ZIPArchiveWriter.Entry] = []
        for entry in entries {
            var payload = try ZIPArchiveReader.readFile(entry, from: data)
            if entry.path == path {
                payload = Data(transform(payload).utf8)
            }
            rewritten.append(ZIPArchiveWriter.Entry(path: entry.path, payload: payload))
        }
        try ZIPArchiveWriter.write(rewritten, to: url)
    }

    func testUnsafePathsAreRejected() throws {
        let url = temporaryFileURL("unsafe.zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try ZIPArchiveWriter.write([
            ZIPArchiveWriter.Entry(path: "TCPViewerSession/manifest.json", payload: Data("{}".utf8)),
            ZIPArchiveWriter.Entry(path: "TCPViewerSession/../escape.json", payload: Data("{}".utf8)),
        ], to: url)
        XCTAssertThrowsError(try SessionPackage.loadPackage(at: url)) { error in
            XCTAssertTrue(((error as? TCPViewerCoreError)?.message ?? "").contains("unsafe path"))
        }
    }

    func testMissingRequiredFileIsRejected() throws {
        let url = temporaryFileURL("missing.zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try ZIPArchiveWriter.write([
            ZIPArchiveWriter.Entry(path: "TCPViewerSession/"),
            ZIPArchiveWriter.Entry(path: "TCPViewerSession/manifest.json", payload: Data("{\"magic\":\"TCPViewerSession\",\"schemaVersion\":1}".utf8)),
        ], to: url)
        XCTAssertThrowsError(try SessionPackage.loadPackage(at: url)) { error in
            XCTAssertTrue(((error as? TCPViewerCoreError)?.message ?? "").contains("missing"))
        }
    }

    func testDuplicateOrdinalsCountAsFailedFlows() throws {
        let url = temporaryFileURL("dupes.tcpviewsession")
        defer { try? FileManager.default.removeItem(at: url) }

        // Two packets share captureOrdinal 0 and carry mismatched packetIDs.
        let records = [
            TCPViewSessionPacketRecord(packetID: 1, captureOrdinal: 0, clientID: nil, packet: makePacket(id: 1)),
            TCPViewSessionPacketRecord(packetID: 2, captureOrdinal: 0, clientID: nil, packet: makePacket(id: 2)),
        ]
        let packets = [makePacket(id: 1), makePacket(id: 2)]

        let recordsJSON = try records.reduce(into: Data()) { data, record in
            data.append(try TCPViewSessionCodec.encodeJSON(record))
            data.append(0x0A)
        }
        let manifest = TCPViewSessionManifest(
            createdAt: Date(),
            applicationName: "TCPViewer",
            applicationVersion: "1.0",
            applicationBuild: "1",
            packetCount: packets.count
        )
        try ZIPArchiveWriter.write([
            ZIPArchiveWriter.Entry(path: "TCPViewerSession/"),
            ZIPArchiveWriter.Entry(path: "TCPViewerSession/\(TCPViewSessionFormat.capturePath)", payload: Data("x".utf8)),
            ZIPArchiveWriter.Entry(path: "TCPViewerSession/\(TCPViewSessionFormat.packetsPath)", payload: recordsJSON),
            ZIPArchiveWriter.Entry(path: "TCPViewerSession/\(TCPViewSessionFormat.clientsPath)", payload: try TCPViewSessionCodec.encodeJSON(TCPViewSessionClientStore(clients: []))),
            ZIPArchiveWriter.Entry(path: "TCPViewerSession/\(TCPViewSessionFormat.annotationsPath)", payload: try TCPViewSessionCodec.encodeJSON(TCPViewSessionAnnotations(annotations: []))),
            ZIPArchiveWriter.Entry(path: "TCPViewerSession/\(TCPViewSessionFormat.statePath)", payload: try TCPViewSessionCodec.encodeJSON(TCPViewSessionState(sourceMetadata: nil))),
            ZIPArchiveWriter.Entry(path: "TCPViewerSession/\(TCPViewSessionFormat.manifestPath)", payload: try TCPViewSessionCodec.encodeJSON(manifest)),
            ZIPArchiveWriter.Entry(path: "TCPViewerSession/icons/"),
        ], to: url)

        let contents = try SessionPackage.loadPackage(at: url)
        defer { try? FileManager.default.removeItem(at: contents.extractionDirectoryURL) }
        XCTAssertEqual(contents.packetRecords.count, 1)
        XCTAssertEqual(contents.importReport.importedFlowCount, 1)
        // Upstream accounting: max(skipped decoded records, manifest deficit)
        // = max(1, 2-1) = 1 (the duplicate ordinal is one failed flow).
        XCTAssertEqual(contents.importReport.failedFlowCount, 1)
    }
}
