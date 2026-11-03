//
//  PacketStructuredFilterServiceTests.swift
//  PcapPlusPlusCoreTests
//
//  Parity gate for the structured-builder engine port (upstream
//  PacketStructuredFilterService): all ten conditions, the enabled toggle,
//  AND/OR joining, the five-row cap, numeric guards and invalid-regex
//  behavior.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

@Suite struct PacketStructuredFilterServiceTests {

    private let service = PacketStructuredFilterService()

    private let packet = PacketSummary(
        id: 5,
        packetNumber: 5,
        timestamp: Date(timeIntervalSince1970: 1_000),
        source: .live,
        interfaceID: "eth0",
        transportHint: .tcp,
        protocolSummary: "HTTPS",
        endpoints: PacketEndpoints(
            source: PacketEndpoint(address: "10.0.0.5", port: 44_000),
            destination: PacketEndpoint(address: "93.184.216.34", port: 443)
        ),
        originalLength: 1_400,
        capturedLength: 1_400,
        streamID: 7,
        direction: .outbound,
        tcpFlags: "SYN, ACK",
        tcpPayloadLength: 0,
        infoSummary: "example.com:443 HTTPS",
        layers: [PacketLayer(name: "tcp"), PacketLayer(name: "tls")],
        decodeStatus: PacketDecodeStatus(kind: .malformed, reason: "short record"),
        captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false, interfaceName: "eth0"),
        sniDomainName: "example.com",
        client: PacketClient(
            pid: 4_242,
            name: "demo",
            displayName: "Demo App",
            executablePath: "/usr/bin/demo",
            bundleIdentifier: "com.example.demo"
        )
    )

    private func row(
        _ field: PacketStructuredFilterQuery,
        _ condition: PacketStructuredFilterCondition,
        _ text: String,
        enabled: Bool = true
    ) -> PacketStructuredFilter {
        PacketStructuredFilter(field: field, condition: condition, text: text, isEnabled: enabled)
    }

    @Test func stringConditionsMatchCaseInsensitively() {
        #expect(service.matches(packet, filter: row(.urlDomain, .contains, "EXAMPLE.com")))
        #expect(service.matches(packet, filter: row(.urlDomain, .notContains, "other.org")))
        #expect(!service.matches(packet, filter: row(.urlDomain, .notContains, "example")))

        #expect(service.matches(packet, filter: row(.tcpFlags, .hasPrefix, "syn")))
        #expect(service.matches(packet, filter: row(.tcpFlags, .hasSuffix, "ack")))
        #expect(service.matches(packet, filter: row(.tcpFlags, .notHasSuffix, "fin")))
        #expect(!service.matches(packet, filter: row(.tcpFlags, .notHasPrefix, "syn")))

        #expect(service.matches(packet, filter: row(.tcpFlags, .matchesRegex, "^syn,\\s*ack$")))
        #expect(service.matches(packet, filter: row(.summary, .matchesRegex, "https$")))
        #expect(service.matches(packet, filter: row(.tcpFlags, .notMatchesRegex, "fin$")))
        #expect(!service.matches(packet, filter: row(.tcpFlags, .notMatchesRegex, "ack")))
    }

    @Test func semanticFieldsExposeUpstreamValues() {
        #expect(service.matches(packet, filter: row(.client, .contains, "demo app")))
        #expect(service.matches(packet, filter: row(.pid, .contains, "4242")))
        #expect(service.matches(packet, filter: row(.bundleIdentifier, .contains, "example.demo")))
        #expect(service.matches(packet, filter: row(.streamID, .contains, "7")))
        #expect(service.matches(packet, filter: row(.summary, .contains, "https")))
        #expect(service.matches(packet, filter: row(.direction, .contains, "outbound")))
        #expect(service.matches(packet, filter: row(.source, .contains, "10.0.0.5")))
        #expect(service.matches(packet, filter: row(.destination, .contains, "93.184.216.34")))
        #expect(service.matches(packet, filter: row(.tcpFlags, .contains, "SYN")))
        #expect(service.matches(packet, filter: row(.length, .contains, "1400")))
        #expect(service.matches(packet, filter: row(.interface, .contains, "eth0")))
        #expect(service.matches(packet, filter: row(.tags, .contains, "Malformed")))
        #expect(service.matches(packet, filter: row(.decodeStatus, .contains, "short record")))
        #expect(service.matches(packet, filter: row(.protocol, .contains, "tls")))
    }

    @Test func numericComparisonsApplyOnlyToNumericFields() {
        #expect(service.matches(packet, filter: row(.length, .lessThan, "2000")))
        #expect(!service.matches(packet, filter: row(.length, .lessThan, "1400")))
        #expect(service.matches(packet, filter: row(.length, .greaterThanOrEqual, "1400")))
        #expect(service.matches(packet, filter: row(.streamID, .greaterThanOrEqual, "7")))
        #expect(!service.matches(packet, filter: row(.streamID, .lessThan, "7")))
        #expect(service.matches(packet, filter: row(.sourcePort, .lessThan, "50000")))
        #expect(!service.matches(packet, filter: row(.sourcePort, .greaterThanOrEqual, "50000")))
        #expect(service.matches(packet, filter: row(.destinationPort, .greaterThanOrEqual, "443")))
        #expect(service.matches(packet, filter: row(.pid, .lessThan, "99999")))
        #expect(service.matches(packet, filter: row(.tcpPayload, .lessThan, "1")))

        // Non-numeric expectation matches nothing (upstream guard).
        #expect(!service.matches(packet, filter: row(.length, .lessThan, "not-a-number")))
        // Numeric conditions on non-numeric fields match nothing.
        #expect(!service.matches(packet, filter: row(.urlDomain, .lessThan, "1")))
    }

    @Test func invalidRegexMatchesNothing() {
        #expect(!service.matches(packet, filter: row(.tcpFlags, .matchesRegex, "([unclosed")))
        #expect(!service.matches(packet, filter: row(.tcpFlags, .notMatchesRegex, "([unclosed")))
    }

    @Test func enabledToggleInactiveRowsAndBooleanJoin() {
        // A disabled miss row never contributes: AND passes on the hit row.
        // (If the disabled row were still evaluated, the group would miss.)
        let group = PacketStructuredFilterGroup(filters: [
            row(.tcpFlags, .contains, "SYN"),
            row(.client, .contains, "nobody", enabled: false),
        ], join: .and)
        #expect(service.matches(packet, group: group))

        // Same rows enabled: AND misses because of the client row.
        let andGroup = PacketStructuredFilterGroup(filters: [
            row(.tcpFlags, .contains, "SYN"),
            row(.client, .contains, "nobody"),
        ], join: .and)
        #expect(!service.matches(packet, group: andGroup))

        // OR hits on the second row.
        let orGroup = PacketStructuredFilterGroup(filters: [
            row(.client, .contains, "nobody"),
            row(.tcpFlags, .contains, "SYN"),
        ], join: .or)
        #expect(service.matches(packet, group: orGroup))
    }

    @Test func emptyTextRowsNeverContribute() {
        let group = PacketStructuredFilterGroup(filters: [
            row(.client, .contains, "   "),
            row(.length, .lessThan, "9000"),
        ], join: .and)
        #expect(service.matches(packet, group: group))
    }

    @Test func groupCapsAtFiveRows() {
        let rows = (0..<6).map { row(.client, .contains, "x\($0)") }
        #expect(PacketStructuredFilterGroup(filters: rows, join: .or).filters.count == 5)
    }
}
