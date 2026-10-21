//
//  IPCFramingTests.swift
//  Omarchy TCPViewer
//
//  Unit tests for schema_version 1 line framing and inbound validation
//  (every inbound byte is untrusted).
//

import XCTest

@testable import TCPViewerIPC

final class IPCFramingTests: XCTestCase {
    // MARK: - Round trips

    func testRequestRoundTrip() throws {
        // Millisecond-representable fixed date: wire format keeps .SSS precision.
        let request = IPCRequest(
            requestID: "req-1",
            command: .captureStart,
            params: ["interface": .string("enp0s25"), "promiscuous": .bool(true)],
            createdAt: Date(timeIntervalSince1970: 1_760_000_000.5)
        )
        let line = try IPCCodec.encodeLine(request, limit: IPCLimits.maxRequestBytes)
        XCTAssertEqual(line.last, 0x0A, "line must be newline-terminated")

        let decoded = try IPCCodec.decodeRequest(line: line)
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.command, .captureStart)
        XCTAssertEqual(decoded.string("interface"), "enp0s25")
        XCTAssertEqual(decoded.bool("promiscuous"), true)
    }

    func testResponseEnvelopeMatchesUpstreamShape() throws {
        // Upstream CLI.md: {"schema_version":1,"request_id":"...","ok":true,...}
        let response = IPCResponse.success(
            requestID: "req-1",
            command: "capture.start",
            data: ["source_id": .string("ABC-123")]
        )
        let line = try IPCCodec.encodeLine(response, limit: IPCLimits.maxResponseBytes)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])

        XCTAssertEqual(json["schema_version"] as? Int, 1)
        XCTAssertEqual(json["request_id"] as? String, "req-1")
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["command"] as? String, "capture.start")
        XCTAssertNil(json["error"])
    }

    func testFailureEnvelopeMatchesUpstreamShape() throws {
        let response = IPCResponse.failure(
            requestID: "req-2",
            command: "capture.start",
            code: IPCError.permissionDenied,
            message: "missing CAP_NET_RAW"
        )
        let line = try IPCCodec.encodeLine(response, limit: IPCLimits.maxResponseBytes)
        let decoded = try IPCCodec.decodeServerLine(line: line)

        guard case .response(let value) = decoded else {
            return XCTFail("expected response")
        }
        XCTAssertFalse(value.ok)
        XCTAssertEqual(value.error?.code, "permission_denied")
    }

    func testEventAndResponseAreDistinguishable() throws {
        let event = IPCEventMessage(
            event: .capturePackets,
            data: ["source_id": .string("s1"), "packets": .array([.string("1")])]
        )
        let eventLine = try IPCCodec.encodeLine(event, limit: IPCLimits.maxResponseBytes)
        guard case .event(let name, let data) = try IPCCodec.decodeServerLine(line: eventLine) else {
            return XCTFail("expected event")
        }
        XCTAssertEqual(name, "capture.packets")
        XCTAssertEqual(data["source_id"]?.stringValue, "s1")

        let response = IPCResponse.success(requestID: "r", command: "app.status", data: [:])
        let responseLine = try IPCCodec.encodeLine(response, limit: IPCLimits.maxResponseBytes)
        guard case .response = try IPCCodec.decodeServerLine(line: responseLine) else {
            return XCTFail("expected response")
        }
    }

    // MARK: - Inbound validation (untrusted)

    func testUnknownCommandRejected() {
        let line = Data(#"{"schema_version":1,"request_id":"r1","command":"license.activate","params":{}}"#.utf8)
        XCTAssertThrowsError(try IPCCodec.decodeRequest(line: line)) { error in
            XCTAssertEqual((error as? IPCFramingError)?.code, IPCError.unknownCommand)
        }
    }

    func testUnsupportedSchemaRejected() {
        let line = Data(#"{"schema_version":2,"request_id":"r1","command":"app.status","params":{}}"#.utf8)
        XCTAssertThrowsError(try IPCCodec.decodeRequest(line: line)) { error in
            XCTAssertEqual((error as? IPCFramingError)?.code, IPCError.unsupportedSchema)
        }
    }

    func testInvalidRequestIDRejected() throws {
        for bad in ["has spaces", "semi;colon", String(repeating: "x", count: 65), ""] {
            let json = #"{"schema_version":1,"request_id":"\#(bad)","command":"app.status","params":{}}"#
            XCTAssertThrowsError(
                try IPCCodec.decodeRequest(line: Data(json.utf8)),
                "request_id \(bad) must be rejected"
            ) { error in
                XCTAssertEqual((error as? IPCFramingError)?.code, IPCError.invalidRequest)
            }
        }
    }

    func testOversizedLineRejected() {
        var line = Data(#"{"schema_version":1,"request_id":"r","command":"app.status","params":{"pad":""#.utf8)
        line.append(Data(repeating: 0x61, count: IPCLimits.maxRequestBytes + 1))
        XCTAssertThrowsError(try IPCCodec.decodeRequest(line: line)) { error in
            XCTAssertEqual((error as? IPCFramingError)?.code, IPCError.invalidRequest)
        }
    }

    func testDeeplyNestedJSONRejectedBeforeDecoding() {
        // 10k nested arrays: must fail the depth pre-scan, never reach the parser.
        var line = Data(#"{"schema_version":1,"request_id":"r","command":"app.status","params":{"a":"#.utf8)
        line.append(Data(repeating: 0x5B, count: 10_000))  // [[[[...
        line.append(Data(repeating: 0x5D, count: 10_000))
        line.append(Data("}}".utf8))
        XCTAssertThrowsError(try IPCCodec.decodeRequest(line: line)) { error in
            XCTAssertEqual((error as? IPCFramingError)?.code, IPCError.invalidRequest)
        }
    }

    func testBracketsInsideStringsDoNotCountTowardDepth() throws {
        let request = IPCRequest(
            requestID: "r1",
            command: .packetsList,
            params: ["filter": .string(String(repeating: "[[[]]]", count: 100))]
        )
        let line = try IPCCodec.encodeLine(request, limit: IPCLimits.maxRequestBytes)
        let decoded = try IPCCodec.decodeRequest(line: line)
        XCTAssertEqual(decoded.string("filter")?.count, 600)
    }

    func testExpiryDetection() {
        let expired = IPCRequest(
            requestID: "r1",
            command: .appStatus,
            createdAt: Date(timeIntervalSinceNow: -120),
            expiresAt: Date(timeIntervalSinceNow: -60)
        )
        let fresh = IPCRequest(
            requestID: "r2",
            command: .appStatus,
            createdAt: Date(timeIntervalSinceNow: -1),
            expiresAt: Date(timeIntervalSinceNow: +30)
        )
        XCTAssertTrue(IPCCodec.isExpired(expired))
        XCTAssertFalse(IPCCodec.isExpired(fresh))
        XCTAssertFalse(IPCCodec.isExpired(IPCRequest(requestID: "r3", command: .appStatus)))
    }

    func testGracefulCRLFLine() throws {
        let request = IPCRequest(
            requestID: "r1",
            command: .interfacesList,
            createdAt: Date(timeIntervalSince1970: 1_760_000_000.25)
        )
        var line = try IPCCodec.encodeLine(request, limit: IPCLimits.maxRequestBytes)
        line.removeLast()
        line.append(0x0D)
        line.append(0x0A)
        XCTAssertEqual(try IPCCodec.decodeRequest(line: line), request)
    }
}
