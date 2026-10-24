//
//  CaptureOverviewTests.swift
//  TCPViewerOverviewTests
//  Omarchy TCP Viewer
//
//  Parity gate for the Overview engine: upstream classifier pins (packet
//  lengths, TCP analysis markers, service names, conversation sides) and
//  snapshot math (direction splits, timeline compaction, bounded top rows).
//  Adapted from upstream CaptureOverviewService/Classifier test intent.
//

import Foundation
import PcapPlusPlusCore
import TCPViewerIPC
import Testing
@testable import TCPViewerOverview

@Suite("CaptureOverview")
struct CaptureOverviewTests {
    // MARK: Fixtures

    private func makeSummary(
        id: UInt64 = 1,
        packetNumber: UInt64? = nil,
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000),
        transportHint: TransportProtocolHint = .tcp,
        protocolSummary: String? = nil,
        sourceAddress: String? = "10.0.0.2",
        sourcePort: UInt16? = 52_000,
        destinationAddress: String? = "93.184.216.34",
        destinationPort: UInt16? = 443,
        originalLength: Int = 100,
        direction: PacketDirection? = nil,
        tcpFlags: String? = nil,
        infoSummary: String = "",
        decodeKind: PacketDecodeStatus.Kind = .complete,
        layers: [PacketLayer] = [],
        sniDomainName: String? = nil,
        dnsDomainName: String? = nil,
        client: PacketClient? = nil,
        followStreamID: FollowStreamID? = nil
    ) -> PacketSummary {
        PacketSummary(
            id: id,
            packetNumber: packetNumber ?? id,
            timestamp: timestamp,
            source: .offline,
            transportHint: transportHint,
            protocolSummary: protocolSummary,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: sourceAddress, port: sourcePort),
                destination: PacketEndpoint(address: destinationAddress, port: destinationPort)
            ),
            originalLength: originalLength,
            capturedLength: originalLength,
            followStreamID: followStreamID,
            direction: direction,
            tcpFlags: tcpFlags,
            infoSummary: infoSummary,
            layers: layers,
            decodeStatus: PacketDecodeStatus(kind: decodeKind),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false),
            sniDomainName: sniDomainName,
            dnsDomainName: dnsDomainName,
            client: client
        )
    }

    private func packet(
        id: UInt64,
        epochSeconds: Double,
        length: Int,
        direction: PacketDirection?,
        flags: String? = nil,
        info: String = "",
        hint: TransportProtocolHint = .tcp
    ) -> PacketSummary {
        makeSummary(
            id: id,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + epochSeconds),
            transportHint: hint,
            originalLength: length,
            direction: direction,
            tcpFlags: flags,
            infoSummary: info
        )
    }

    // MARK: Classifier pins

    @Test("Packet length buckets match Wireshark Statistics ranges")
    func packetLengthBuckets() {
        #expect(CaptureOverviewClassifier.packetLengthBucketCount == 7)
        #expect(CaptureOverviewClassifier.packetLengthBucket(for: 0) == 0)
        #expect(CaptureOverviewClassifier.packetLengthBucket(for: 79) == 0)
        #expect(CaptureOverviewClassifier.packetLengthBucket(for: 80) == 1)
        #expect(CaptureOverviewClassifier.packetLengthBucket(for: 159) == 1)
        #expect(CaptureOverviewClassifier.packetLengthBucket(for: 639) == 3)
        #expect(CaptureOverviewClassifier.packetLengthBucket(for: 2_559) == 5)
        #expect(CaptureOverviewClassifier.packetLengthBucket(for: 2_560) == 6)
        #expect(CaptureOverviewClassifier.packetLengthBucket(for: 65_400) == 6)
    }

    @Test("isTCP: flags win, then the TCP-family transport hint")
    func isTCPRules() {
        #expect(!CaptureOverviewClassifier.isTCP(makeSummary(transportHint: .udp, tcpFlags: nil)))
        #expect(CaptureOverviewClassifier.isTCP(makeSummary(transportHint: .tcp, tcpFlags: nil)))
        #expect(CaptureOverviewClassifier.isTCP(makeSummary(transportHint: .tls)))
        #expect(CaptureOverviewClassifier.isTCP(makeSummary(transportHint: .http1)))
        #expect(CaptureOverviewClassifier.isTCP(makeSummary(transportHint: .websocket)))
        #expect(CaptureOverviewClassifier.isTCP(makeSummary(transportHint: .udp, tcpFlags: "SYN")))
        #expect(!CaptureOverviewClassifier.isTCP(makeSummary(transportHint: .icmp, tcpFlags: nil)))
    }

    @Test("TCP analysis markers follow the vendored Info column text")
    func tcpIssueMarkers() {
        let lost = CaptureOverviewClassifier.tcpIssues(
            for: makeSummary(infoSummary: "[TCP Previous segment not captured] 1234 > 443 Dat"),
            isTCP: true
        )
        #expect(lost == [.lostSegment])

        let retrans = CaptureOverviewClassifier.tcpIssues(
            for: makeSummary(infoSummary: "[TCP Fast Retransmission] 1234 > 443"),
            isTCP: true
        )
        #expect(retrans == [.retransmission])

        let dup = CaptureOverviewClassifier.tcpIssues(
            for: makeSummary(infoSummary: "[TCP Dup ACK 1#1] 443 > 1234"),
            isTCP: true
        )
        #expect(dup == [.duplicateAck])

        let zero = CaptureOverviewClassifier.tcpIssues(
            for: makeSummary(infoSummary: "[TCP ZeroWindow] 443 > 1234"),
            isTCP: true
        )
        #expect(zero == [.zeroWindow])

        let ooo = CaptureOverviewClassifier.tcpIssues(
            for: makeSummary(infoSummary: "[TCP Out-Of-Order] 1234 > 443"),
            isTCP: true
        )
        #expect(ooo == [.outOfOrder])

        // Non-TCP packets only carry malformed; the reset flag counts for TCP only.
        #expect(CaptureOverviewClassifier.tcpIssues(for: makeSummary(tcpFlags: nil), isTCP: false).isEmpty)
        #expect(
            CaptureOverviewClassifier.tcpIssues(for: makeSummary(tcpFlags: "RST, ACK"), isTCP: false).isEmpty
        )
        let reset = CaptureOverviewClassifier.tcpIssues(
            for: makeSummary(tcpFlags: "RST, ACK", infoSummary: ""),
            isTCP: true
        )
        #expect(reset == [.reset])
    }

    @Test("Malformed detection scans the Info tail only")
    func malformedMarker() {
        let malformed = CaptureOverviewClassifier.tcpIssues(
            for: makeSummary(transportHint: .udp, infoSummary: "GET /x [Malformed Packet]"),
            isTCP: false
        )
        #expect(malformed == [.malformed])

        // Without the trailing bracket it is not Wireshark's malformed marker.
        let notMalformed = CaptureOverviewClassifier.tcpIssues(
            for: makeSummary(transportHint: .udp, infoSummary: "GET /x [Malformed Packet"),
            isTCP: false
        )
        #expect(notMalformed.isEmpty)
    }

    @Test("Display filters are fixed expressions per issue")
    func displayFilters() {
        #expect(CaptureOverviewClassifier.displayFilter(for: .retransmission)
            .contains("tcp.analysis.retransmission"))
        #expect(CaptureOverviewClassifier.displayFilter(for: .duplicateAck) == "tcp.analysis.duplicate_ack")
        #expect(CaptureOverviewClassifier.displayFilter(for: .reset) == "tcp.flags.reset == 1")
    }

    @Test("Service keys take the lower port; names include QUIC over UDP 443")
    func serviceKeys() {
        let https = CaptureOverviewClassifier.serviceKey(
            for: makeSummary(sourcePort: 52_000, destinationPort: 443), isTCP: true
        )
        #expect(https == OverviewServiceKey(transport: .tcp, port: 443))
        #expect(CaptureOverviewClassifier.serviceName(for: https!) == "HTTPS")

        let dns = CaptureOverviewClassifier.serviceKey(
            for: makeSummary(transportHint: .dns, sourcePort: 52_000, destinationPort: 53), isTCP: false
        )
        #expect(dns == OverviewServiceKey(transport: .udp, port: 53))
        #expect(CaptureOverviewClassifier.serviceName(for: dns!) == "DNS")

        let udp443 = CaptureOverviewClassifier.serviceKey(
            for: makeSummary(transportHint: .payload, sourcePort: 8_080, destinationPort: 443), isTCP: false
        )
        #expect(udp443 == OverviewServiceKey(transport: .udp, port: 443))
        #expect(CaptureOverviewClassifier.serviceName(for: udp443!) == "QUIC")
    }

    @Test("Conversation client side: lower-port guess, SYN confirmation")
    func conversationSides() {
        // Higher client ephemeral port to the server: client guessed right.
        let guessed = CaptureOverviewClassifier.conversation(
            for: makeSummary(sourcePort: 52_000, destinationPort: 443),
            isTCP: true
        )!
        #expect(guessed.clientAddress == "10.0.0.2")
        #expect(guessed.clientPort == 52_000)
        #expect(guessed.serverAddress == "93.184.216.34")
        #expect(guessed.serverPort == 443)
        #expect(!guessed.isClientConfirmed)

        // A SYN from the source side confirms it as the client.
        let syn = CaptureOverviewClassifier.conversation(
            for: makeSummary(tcpFlags: "SYN"),
            isTCP: true
        )!
        #expect(syn.isClientConfirmed)
        #expect(syn.clientAddress == "10.0.0.2")

        // SYN,ACK comes from the server: the client is the other side.
        let synack = CaptureOverviewClassifier.conversation(
            for: makeSummary(tcpFlags: "SYN, ACK"),
            isTCP: true
        )!
        #expect(synack.isClientConfirmed)
        #expect(synack.clientAddress == "93.184.216.34")
        #expect(synack.serverAddress == "10.0.0.2")

        // Wrong-port guess (server ephemeral lower than client) still holds
        // without a handshake.
        // Wrong-port guess (server ephemeral lower than client) still holds
        // without a handshake.
        let oddLowerPort = CaptureOverviewClassifier.conversation(
            for: makeSummary(sourcePort: 522, destinationPort: 37_555),
            isTCP: true
        )!
        #expect(oddLowerPort.clientAddress == "93.184.216.34")
        #expect(oddLowerPort.serverAddress == "10.0.0.2")

        // Stream key wins over endpoints when Wireshark numbered the stream.
        let stream = CaptureOverviewClassifier.conversation(
            for: makeSummary(sourcePort: 52_000, destinationPort: 443, followStreamID: FollowStreamID(streamProtocol: .tcp, streamID: 7)),
            isTCP: true
        )!
        #expect(stream.key == "tcp.stream:7")
        #expect(CaptureOverviewClassifier.streamKey(FollowStreamID(streamProtocol: .udp, streamID: 3)) == "udp.stream:3")

        // No endpoints → no conversation sample, but the packet still lands
        // in totals and the timeline.
        let noPorts = CaptureOverviewClassifier.conversation(
            for: makeSummary(transportHint: .arp, sourcePort: nil, destinationPort: nil),
            isTCP: false
        )
        #expect(noPorts == nil)
    }

    @Test("Filter-safe guard rejects crafted SNI values")
    func filterSafe() {
        #expect(CaptureOverviewClassifier.isFilterSafe(value: "example.com"))
        #expect(CaptureOverviewClassifier.isFilterSafe(value: "192.168.10.4"))
        #expect(!CaptureOverviewClassifier.isFilterSafe(value: "bad domain\nip.addr == evil"))
        #expect(!CaptureOverviewClassifier.isFilterSafe(value: ""))
    }

    // MARK: Snapshot math

    @Test("Direction splits, issue counts, and length histogram")
    func totalsMath() {
        let packets = [
            packet(id: 1, epochSeconds: 0, length: 100, direction: .outbound),
            packet(id: 2, epochSeconds: 0.5, length: 200, direction: .inbound),
            packet(id: 3, epochSeconds: 1.0, length: 300, direction: nil),
            packet(id: 4, epochSeconds: 1.2, length: 640, direction: .outbound, info: "[TCP Retransmission] 1234 > 443"),
        ]
        let snapshot = CaptureOverviewBuilder.snapshot(for: packets)

        #expect(snapshot.totals.packets == 4)
        #expect(snapshot.totals.bytes == 1_240)
        #expect(snapshot.totals.sentPackets == 2)
        #expect(snapshot.totals.sentBytes == 740)
        #expect(snapshot.totals.receivedPackets == 1)
        #expect(snapshot.totals.receivedBytes == 200)
        #expect(snapshot.totals.unclassifiedPackets == 1)
        #expect(snapshot.totals.unclassifiedBytes == 300)
        #expect(snapshot.totals.issuePackets == 1)

        #expect(snapshot.tcpPacketCount == 4)
        #expect(snapshot.malformedPacketCount == 0)
        #expect(snapshot.tcpIssues == [OverviewTCPIssueRow(kind: .retransmission, packets: 1)])

        #expect(snapshot.packetLengthCounts[1] == 1)  // 100
        #expect(snapshot.packetLengthCounts[2] == 2)  // 200/300
        #expect(snapshot.packetLengthCounts[4] == 1)  // 640

        #expect(snapshot.firstPacketDate == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(snapshot.lastPacketDate == Date(timeIntervalSince1970: 1_700_000_001.2))
    }

    @Test("Offline packets with local-less direction land unclassified")
    func unclassifiedWithoutDirection() {
        let snapshot = CaptureOverviewBuilder.snapshot(for: [
            packet(id: 1, epochSeconds: 0, length: 10, direction: .local),
            packet(id: 2, epochSeconds: 0, length: 20, direction: .unknown),
        ])
        #expect(snapshot.totals.unclassifiedPackets == 2)
        #expect(snapshot.totals.unclassifiedBytes == 30)
        #expect(snapshot.totals.sentPackets == 0)
        #expect(snapshot.totals.receivedPackets == 0)
    }

    @Test("Timeline: 1 s slots under the budget with round rendering")
    func timelineRendering() {
        let packets = (0..<10).map { i in
            packet(id: UInt64(i + 1), epochSeconds: Double(i), length: 60, direction: .outbound)
        }
        let snapshot = CaptureOverviewBuilder.snapshot(for: packets)
        #expect(snapshot.timelineInterval == 1)
        #expect(snapshot.timeline.count == 10)
        #expect(snapshot.timeline.allSatisfy { $0.totals.packets == 1 })
        #expect(snapshot.timeline.first?.date == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("Timeline compacts into wider storage slots past 1_024 buckets")
    func timelineCompaction() {
        // A span over 1_024 seconds must compact from 1 s storage width to a
        // slot whose rendered point count stays in budget.
        var packets: [PacketSummary] = []
        for index in 0..<1_500 {
            packets.append(packet(id: UInt64(index + 1), epochSeconds: Double(index) * 2, length: 10, direction: .outbound))
        }
        let snapshot = CaptureOverviewBuilder.snapshot(for: packets)
        #expect(snapshot.timeline.count <= CaptureOverviewBuilder.maximumRenderedTimelinePointCount)
        #expect(snapshot.timelineInterval > 1)
        let pointTotal = snapshot.timeline.reduce(0) { $0 + $1.totals.packets }
        #expect(pointTotal == 1_500)
    }

    @Test("Top rows cap at ten with upstream tie-breakers")
    func topRowCapsAndOrder() {
        var packets: [PacketSummary] = []
        for index in 0..<12 {
            packets.append(makeSummary(
                id: UInt64(index + 1),
                originalLength: index == 0 ? 100 : 50,
                tcpFlags: nil,
                sniDomainName: "\(index).example.com"
            ))
        }
        let snapshot = CaptureOverviewBuilder.snapshot(for: packets)

        #expect(snapshot.domainCount == 12)
        #expect(snapshot.topDestinations.count == 10)
        #expect(snapshot.topDestinations.first?.key == "0.example.com")
        #expect(snapshot.topDestinations.first?.kind == "domain")
        #expect(snapshot.topDestinations.first?.id == "domain:0.example.com")
        #expect(snapshot.topDestinations.first?.totals.bytes == 100)
        // Ties resolve by title ascending after 0.example.com.
        #expect(snapshot.topDestinations[1].key == "1.example.com")
    }

    @Test("Domains own traffic; domain-less packets contribute IPs destination-first")
    func destinationIdentityRules() {
        let dotted = makeSummary(
            sourceAddress: "10.0.0.2",
            sourcePort: 52_000,
            destinationAddress: "1.2.3.4",
            destinationPort: 443,
            sniDomainName: "  EXAMPLE.COM. "
        )
        let domain = CaptureOverviewBuilder.domainIdentity(for: dotted)
        #expect(domain.kind == .domain)
        #expect(domain.key == "example.com")
        #expect(CaptureOverviewBuilder.ipAddressIdentities(for: dotted).isEmpty)

        let bare = makeSummary()
        let ips = CaptureOverviewBuilder.ipAddressIdentities(for: bare)
        #expect(ips.map(\.key) == ["93.184.216.34", "10.0.0.2"])
        #expect(ips.first?.displayName == "93.184.216.34")

        #expect(String(repeating: "a", count: 254).utf8.count == 254)
        let tooLong = CaptureOverviewBuilder.canonicalDomainName(String(repeating: "a", count: 254))
        #expect(tooLong == nil)
    }

    @Test("App identity matches the GUI clientKey: executable path first")
    func clientIdentity() {
        let named = makeSummary(client: PacketClient(
            pid: 42, name: "python3", displayName: "Python", executablePath: "/usr/bin/python3"
        ))
        let identity = CaptureOverviewBuilder.clientIdentity(for: named)
        #expect(identity?.key == "/usr/bin/python3")
        #expect(identity?.displayName == "Python")

        let fallback = makeSummary(client: PacketClient(pid: 43, name: "python3", displayName: "Python"))
        #expect(CaptureOverviewBuilder.clientIdentity(for: fallback)?.key == "Python")
        #expect(CaptureOverviewBuilder.clientIdentity(for: makeSummary(client: nil)) == nil)
    }

    @Test("Protocol labels follow the table column, with one Other bucket")
    func protocolRows() {
        var packets: [PacketSummary] = []
        let hints: [(TransportProtocolHint, String?)] = [
            (.tls, "TLS 1.3"), (.tls, "TLS 1.2"), (.dns, "DNS"), (.http1, "HTTP"),
            (.websocket, "WebSocket"), (.tcp, nil), (.udp, nil), (.arp, nil),
        ]
        var id: UInt64 = 1
        for (hint, summary) in hints {
            packets.append(makeSummary(
                id: id, transportHint: hint, protocolSummary: summary,
                sourcePort: hint == .udp ? 53 : nil, destinationPort: nil,
                tcpFlags: nil
            ))
            id += 1
        }
        let snapshot = CaptureOverviewBuilder.snapshot(for: packets)
        #expect(snapshot.protocols.count <= CaptureOverviewBuilder.maximumProtocolRowCount + 1)
        #expect(snapshot.protocols.last?.title == "Other")

        let two = CaptureOverviewBuilder.snapshot(for: [
            makeSummary(id: 1, transportHint: .dns, tcpFlags: nil),
            makeSummary(id: 2, transportHint: .dns, tcpFlags: nil),
        ])
        #expect(two.protocols.count == 1)
        #expect(two.protocols.first?.title == "DNS")
        #expect(two.protocols.first?.totals.packets == 2)
    }

    @Test("Files with no packets yield the empty snapshot")
    func emptySnapshot() {
        let snapshot = CaptureOverviewBuilder.snapshot(for: [])
        #expect(snapshot.totals.packets == 0)
        #expect(snapshot.topApps.isEmpty)
        #expect(snapshot.timeline.isEmpty)
        #expect(snapshot.packetLengthCounts.count == CaptureOverviewClassifier.packetLengthBucketCount)
        #expect(snapshot.packetLengthCounts.allSatisfy { $0 == 0 })
    }

    // MARK: IPC shape

    @Test("capture.overview payload carries the schema_version 1 fields")
    func ipcShape() {
        let snapshot = CaptureOverviewBuilder.snapshot(for: [
            packet(id: 1, epochSeconds: 0, length: 300, direction: .outbound, info: "[TCP Retransmission] 1 > 443"),
        ])
        let data = CaptureOverviewIPC.snapshotData(snapshot, sourceID: "abc123", revision: (count: 1, updateSeq: 4))
        #expect(data["source_id"] == .string("abc123"))
        #expect(data["revision"] == .object(["count": .int(1), "update_seq": .int(4)]))
        #expect(data["app_count"] == .int(0))
        #expect(data["tcp_packet_count"] == .int(1))
        guard case .object(let totals)? = data["totals"] else {
            Issue.record("totals missing")
            return
        }
        #expect(totals["packets"] == .int(1))
        #expect(totals["bytes"] == .int(300))
        #expect(totals["issue_packets"] == .int(1))
        #expect(data["timeline_interval_ms"] == .int(1000))
        guard case .array(let timeline)? = data["timeline"], timeline.count == 1,
              case .object(let point)? = timeline.first,
              case .object(let pointTotals)? = point["totals"] else {
            Issue.record("timeline missing")
            return
        }
        #expect(pointTotals["packets"] == .int(1))
        guard case .array(let issues)? = data["tcp_issues"] else {
            Issue.record("tcp_issues missing")
            return
        }
        #expect(issues.count == 1)
    }
}
