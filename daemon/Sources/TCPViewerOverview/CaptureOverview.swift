//
//  CaptureOverview.swift
//  tcpviewerd
//  Omarchy TCP Viewer
//
//  Overview snapshot computed on demand from a source's buffered packet
//  summaries. Ported from upstream TCP Viewer (Proxyman LLC,
//  GPL-2.0-or-later): Features/NetworkInspector/Services/
//  CaptureOverviewService.swift, CaptureOverviewClassifier.swift, and the
//  identity helpers of PacketSourceListClassifier.swift. Upstream accumulates
//  ingest deltas continuously; the daemon holds full summary buffers, so this
//  port recomputes from a snapshot on request and caches by revision
//  (summary count + updateSeq). Bucketing, ordering, labels, and rounding
//  match upstream so charts and unit tests agree across both codebases.
//

import Foundation
import PcapPlusPlusCore
import TCPViewerIPC

// Traffic aggregates shared by every chart bucket. Direction unclassified
// means the packet has no local address (offline files), not an error.
struct OverviewTotals: Equatable, Sendable {
    var packets: UInt64 = 0
    var bytes: UInt64 = 0
    var sentPackets: UInt64 = 0
    var sentBytes: UInt64 = 0
    var receivedPackets: UInt64 = 0
    var receivedBytes: UInt64 = 0
    var unclassifiedPackets: UInt64 = 0
    var unclassifiedBytes: UInt64 = 0
    // Packets with at least one TCP analysis flag; malformed counted separately.
    var issuePackets: UInt64 = 0

    var isEmpty: Bool {
        packets == 0
    }

    mutating func add(_ value: OverviewTotals) {
        packets += value.packets
        bytes += value.bytes
        sentPackets += value.sentPackets
        sentBytes += value.sentBytes
        receivedPackets += value.receivedPackets
        receivedBytes += value.receivedBytes
        unclassifiedPackets += value.unclassifiedPackets
        unclassifiedBytes += value.unclassifiedBytes
        issuePackets += value.issuePackets
    }
}

enum OverviewTransport: String, Sendable {
    case tcp
    case udp
}

// Upstream CaptureOverviewTCPIssueKind; raw values order rows most severe first.
enum OverviewTCPIssueKind: Int, CaseIterable, Sendable {
    case malformed
    case lostSegment
    case retransmission
    case outOfOrder
    case zeroWindow
    case duplicateAck
    case reset
}

struct OverviewServiceKey: Hashable, Sendable {
    let transport: OverviewTransport
    let port: UInt16
}

// One packet's view of its conversation: the identity to group by and the
// sides to display.
struct OverviewConversationSample: Sendable {
    var key: String
    var clientAddress: String
    var clientPort: UInt16
    var serverAddress: String
    var serverPort: UInt16
    // True when a SYN shows which side opened the connection.
    var isClientConfirmed: Bool
}

// The classifier constants and infallible mappings from one PacketSummary.
// Wireshark expert text is dissected in NativeTCPViewerCore; overviews read
// the flags it surfaces.
enum CaptureOverviewClassifier {
    // The lowest transport port is almost always the server's service port.
    static func serviceKey(for packet: PacketSummary, isTCP: Bool) -> OverviewServiceKey? {
        guard let sourcePort = packet.endpoints.source.port,
              let destinationPort = packet.endpoints.destination.port,
              sourcePort > 0, destinationPort > 0 else {
            return nil
        }
        return OverviewServiceKey(transport: isTCP ? .tcp : .udp, port: min(sourcePort, destinationPort))
    }

    // TCP flags are the most reliable sign; the transport hint covers packets
    // the dissector summarized above TCP.
    static func isTCP(_ packet: PacketSummary) -> Bool {
        if packet.tcpFlags != nil {
            return true
        }
        switch packet.transportHint {
        case .tcp, .tls, .http1, .websocket:
            return true
        default:
            return false
        }
    }

    // Wireshark's Statistics › Packet Lengths ranges; the ranges below 80
    // bytes are merged.
    static let packetLengthUpperBounds = [80, 160, 320, 640, 1_280, 2_560]
    static let packetLengthBucketCount = packetLengthUpperBounds.count + 1

    static func packetLengthBucket(for length: Int) -> Int {
        packetLengthUpperBounds.firstIndex { length < $0 } ?? packetLengthUpperBounds.count
    }

    // Group by Wireshark's stream index when present; without one, the lower
    // port side is almost always the server (direction-independent).
    static func conversation(for packet: PacketSummary, isTCP: Bool) -> OverviewConversationSample? {
        guard let sourceAddress = packet.endpoints.source.address, !sourceAddress.isEmpty,
              let destinationAddress = packet.endpoints.destination.address, !destinationAddress.isEmpty,
              let sourcePort = packet.endpoints.source.port,
              let destinationPort = packet.endpoints.destination.port else {
            return nil
        }
        let transport = isTCP ? OverviewTransport.tcp : .udp
        let source = (address: sourceAddress, port: sourcePort)
        let destination = (address: destinationAddress, port: destinationPort)
        let sourceIsServer = (sourcePort, sourceAddress) < (destinationPort, destinationAddress)
        let guessed = sourceIsServer
            ? (client: destination, server: source)
            : (client: source, server: destination)

        // tcpFlags reads like "SYN, ACK"; no other flag name contains "SYN".
        var client = guessed.client
        var server = guessed.server
        var isClientConfirmed = false
        if isTCP, let flags = packet.tcpFlags, flags.contains("SYN") {
            // The SYN comes from the client and the SYN-ACK from the server.
            client = flags.contains("ACK") ? destination : source
            server = flags.contains("ACK") ? source : destination
            isClientConfirmed = true
        }
        let key = packet.followStreamID.map { streamKey($0) }
            ?? "\(transport.rawValue)|\(guessed.client.address)|\(guessed.client.port)|\(guessed.server.address)|\(guessed.server.port)"
        return OverviewConversationSample(
            key: key,
            clientAddress: client.address,
            clientPort: client.port,
            serverAddress: server.address,
            serverPort: server.port,
            isClientConfirmed: isClientConfirmed
        )
    }

    // Stable text identity for a stream-keyed conversation row.
    static func streamKey(_ stream: FollowStreamID) -> String {
        "\(stream.streamProtocol.rawValue).stream:\(stream.streamID)"
    }

    // Common port names; UDP 443 is QUIC rather than HTTPS.
    static func serviceName(for key: OverviewServiceKey) -> String? {
        if key.transport == .udp, key.port == 443 {
            return "QUIC"
        }
        return wellKnownServiceNames[key.port]
    }

    // The Info column text Wireshark's TCP analysis prepends for each flag
    // (epan/dissectors/packet-tcp.c). The EPAN summary pass exposes these
    // flags only as text; a unit test pins every marker to the vendored
    // Wireshark sources, so an upgrade that rewords one fails loudly instead
    // of silently zeroing a row.
    static let tcpInfoMarkers: [(kind: OverviewTCPIssueKind, markers: [String])] = [
        (.lostSegment, ["[TCP Previous segment not captured]", "[TCP ACKed unseen segment]"]),
        (.retransmission, ["[TCP Retransmission]", "[TCP Fast Retransmission]", "[TCP Spurious Retransmission]"]),
        (.outOfOrder, ["[TCP Out-Of-Order]"]),
        (.zeroWindow, ["[TCP ZeroWindow]", "[TCP ZeroWindowProbe]", "[TCP ZeroWindowProbeAck]", "[TCP Window Full]"]),
        (.duplicateAck, ["[TCP Dup ACK "]),
    ]
    // Appended by epan/show_exception.c whenever it also sets _ws.malformed.
    static let malformedInfoMarker = "[Malformed Packet"

    // Read the markers Wireshark writes to the Info column; each flag matches
    // its row's display filter.
    static func tcpIssues(for packet: PacketSummary, isTCP: Bool) -> [OverviewTCPIssueKind] {
        var issues: [OverviewTCPIssueKind] = []
        let info = packet.infoSummary
        if info.hasSuffix("]"), info.suffix(160).contains(malformedInfoMarker) {
            issues.append(.malformed)
        }
        guard isTCP else {
            return issues
        }
        // TCP markers are fenced at the start of the column, so long Info
        // text is never scanned.
        if info.hasPrefix("[TCP ") {
            let leadingText = info.prefix(200)
            for (kind, markers) in tcpInfoMarkers where markers.contains(where: { leadingText.contains($0) }) {
                issues.append(kind)
            }
        }
        if packet.tcpFlags?.contains("RST") == true {
            issues.append(.reset)
        }
        return issues
    }

    // The Wireshark filter that shows exactly the packets counted for this
    // flag. The GUI pastes these into its display-filter field; expressions
    // are fixed and carry no packet data.
    static func displayFilter(for issue: OverviewTCPIssueKind) -> String {
        switch issue {
        case .malformed:
            return "_ws.malformed"
        case .lostSegment:
            return "tcp.analysis.lost_segment || tcp.analysis.ack_lost_segment"
        case .retransmission:
            return "tcp.analysis.retransmission || tcp.analysis.fast_retransmission || " +
                "tcp.analysis.spurious_retransmission"
        case .outOfOrder:
            return "tcp.analysis.out_of_order"
        case .zeroWindow:
            return "tcp.analysis.zero_window || tcp.analysis.zero_window_probe || " +
                "tcp.analysis.zero_window_probe_ack || tcp.analysis.window_full"
        case .duplicateAck:
            return "tcp.analysis.duplicate_ack"
        case .reset:
            return "tcp.flags.reset == 1"
        }
    }

    // Domains and ports feed display-filter pastes; a value with characters
    // outside a hostname or IP is treated as unsafe, mirroring upstream's
    // isFilterSafeAddress guard against crafted SNI values.
    static func isFilterSafe(value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253 else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static let wellKnownServiceNames: [UInt16: String] = [
        20: "FTP Data", 21: "FTP", 22: "SSH", 23: "Telnet", 25: "SMTP", 53: "DNS", 67: "DHCP", 68: "DHCP",
        80: "HTTP", 88: "Kerberos", 110: "POP3", 123: "NTP", 137: "NetBIOS", 138: "NetBIOS", 139: "NetBIOS",
        143: "IMAP", 161: "SNMP", 389: "LDAP", 443: "HTTPS", 445: "SMB", 465: "SMTPS", 500: "IKE",
        514: "Syslog", 546: "DHCPv6", 547: "DHCPv6", 548: "AFP", 587: "SMTP", 636: "LDAPS", 853: "DNS over TLS",
        993: "IMAPS", 995: "POP3S", 1194: "OpenVPN", 1900: "SSDP", 3306: "MySQL", 3389: "RDP",
        3478: "STUN", 4500: "IPsec NAT-T", 5223: "Apple Push", 5228: "Google Play", 5353: "mDNS",
        5355: "LLMNR", 5432: "PostgreSQL", 5900: "VNC", 6379: "Redis", 7000: "AirPlay", 8080: "HTTP Alt",
        8443: "HTTPS Alt", 27017: "MongoDB", 51820: "WireGuard", 62078: "iPhone Sync",
    ]
}

// Sidebar identities for one packet, ported from PacketSourceListClassifier.
// The app keys apps by executable path (fallback display name) so Overview
// rows can drive the same tree scope filters.
struct OverviewClientIdentity: Hashable, Sendable {
    let key: String
    let displayName: String
}

struct OverviewDestinationIdentity: Hashable, Sendable {
    enum Kind: String, Sendable {
        case domain
        case ip
    }

    let kind: Kind
    let key: String
    let displayName: String
}

struct OverviewConversationBucket: Sendable {
    var clientAddress: String
    var clientPort: UInt16
    var serverAddress: String
    var serverPort: UInt16
    var domainName: String?
    var appName: String?
    var totals: OverviewTotals
}

public struct OverviewSnapshot: Sendable {
    var totals: OverviewTotals
    var firstPacketDate: Date?
    var lastPacketDate: Date?
    var appCount: Int
    var domainCount: Int
    var malformedPacketCount: UInt64
    var tcpPacketCount: UInt64
    var topApps: [OverviewTopRow]
    var topDestinations: [OverviewTopRow]
    var protocols: [OverviewProtocolRow]
    var tcpIssues: [OverviewTCPIssueRow]
    var topServices: [OverviewServiceRow]
    var topConversations: [OverviewConversationRow]
    var packetLengthCounts: [UInt64]
    var timeline: [OverviewTimelinePoint]
    var timelineInterval: Double

    public static let empty = OverviewSnapshot(
        totals: OverviewTotals(),
        firstPacketDate: nil,
        lastPacketDate: nil,
        appCount: 0,
        domainCount: 0,
        malformedPacketCount: 0,
        tcpPacketCount: 0,
        topApps: [],
        topDestinations: [],
        protocols: [],
        tcpIssues: [],
        topServices: [],
        topConversations: [],
        packetLengthCounts: Array(repeating: 0, count: CaptureOverviewClassifier.packetLengthBucketCount),
        timeline: [],
        timelineInterval: 1
    )
}

struct OverviewTopRow: Identifiable, Sendable {
    // Upstream row ids ("domain:<key>" / "ip:<key>") mirrored so GUI keys match.
    let id: String
    let title: String
    // App rows use the client key; IP and domain rows use kind + key. Nil for
    // future kinds, like upstream's optional selection.
    let kind: String?
    let key: String?
    let totals: OverviewTotals
}

struct OverviewProtocolRow: Identifiable, Sendable {
    let id: String
    let title: String
    let totals: OverviewTotals
}

struct OverviewTimelinePoint: Equatable, Sendable {
    let date: Date
    let totals: OverviewTotals
}

struct OverviewTCPIssueRow: Equatable, Sendable {
    let kind: OverviewTCPIssueKind
    let packets: UInt64

    var id: Int { kind.rawValue }
}

struct OverviewServiceRow: Identifiable, Sendable {
    let key: OverviewServiceKey
    let totals: OverviewTotals

    var id: OverviewServiceKey { key }
}

struct OverviewConversationRow: Identifiable, Sendable {
    let key: String
    let clientAddress: String
    let clientPort: UInt16
    let serverAddress: String
    let serverPort: UInt16
    let domainName: String?
    let appName: String?
    let totals: OverviewTotals

    var id: String { key }
}

public enum CaptureOverviewBuilder {
    static let maximumTimelineBucketCount = 1_024
    static let maximumRenderedTimelinePointCount = 60
    static let maximumTopRowCount = 10
    static let maximumProtocolRowCount = 5
    // DNS queries and scans open a conversation per packet, so only the
    // busiest ones are kept per upstream.
    static let maximumConversationBucketCount = 4_096
    // Each storage width divides the next one, so compaction merges whole
    // buckets.
    static let timelineStorageWidths: [Double] = [
        1, 2, 10, 30, 60, 300, 600, 1_800, 3_600, 7_200, 21_600, 43_200, 86_400,
    ]
    // Round chart steps; a step is used only when it is a multiple of the
    // storage width.
    static let timelineRenderWidths: [Double] = [
        1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1_800, 3_600, 7_200, 10_800, 21_600, 43_200, 86_400,
    ]

    // One full O(n) pass over the buffered summaries; requests are debounced
    // by the GUI and cached by revision, so cost stays bounded.
    public static func snapshot(for packets: [PacketSummary]) -> OverviewSnapshot {
        guard !packets.isEmpty else {
            return .empty
        }

        var totals = OverviewTotals()
        var firstPacketDate: Date?
        var lastPacketDate: Date?
        var malformedPacketCount: UInt64 = 0
        var tcpPacketCount: UInt64 = 0
        var tcpIssueCounts = [UInt64](repeating: 0, count: OverviewTCPIssueKind.allCases.count)
        var packetLengthCounts = [UInt64](repeating: 0, count: CaptureOverviewClassifier.packetLengthBucketCount)

        var appBuckets: [String: (identity: OverviewClientIdentity, totals: OverviewTotals)] = [:]
        var domainBuckets: [String: (identity: OverviewDestinationIdentity, totals: OverviewTotals)] = [:]
        var ipAddressBuckets: [String: (identity: OverviewDestinationIdentity, totals: OverviewTotals)] = [:]
        var protocolBuckets: [String: OverviewTotals] = [:]
        var serviceBuckets: [OverviewServiceKey: OverviewTotals] = [:]
        var conversationBuckets: [String: OverviewConversationBucket] = [:]
        var confirmedConversationKeys = Set<String>()

        // Timeline buckets keyed by floorDiv(unixSeconds, width), starting at
        // width 1 and compacting exactly like upstream.
        var timelineWidth = timelineStorageWidths[0]
        var timelineBuckets: [Int64: OverviewTotals] = [:]

        for packet in packets {
            let isTCP = CaptureOverviewClassifier.isTCP(packet)
            let issues = CaptureOverviewClassifier.tcpIssues(for: packet, isTCP: isTCP)
            let length = max(0, packet.originalLength)
            var packetTotals = trafficTotals(bytes: UInt64(length), direction: packet.direction)
            packetTotals.issuePackets = issues.isEmpty ? 0 : 1

            totals.add(packetTotals)
            if firstPacketDate == nil || packet.timestamp < firstPacketDate! {
                firstPacketDate = packet.timestamp
            }
            if packet.timestamp > (lastPacketDate ?? .distantPast) {
                lastPacketDate = packet.timestamp
            }
            if packet.decodeStatus.kind == .malformed {
                malformedPacketCount += 1
            }
            if isTCP {
                tcpPacketCount += 1
            }
            for issue in issues {
                tcpIssueCounts[issue.rawValue] += 1
            }
            packetLengthCounts[CaptureOverviewClassifier.packetLengthBucket(for: length)] += 1

            if let app = clientIdentity(for: packet) {
                if var bucket = appBuckets[app.key] {
                    bucket.totals.add(packetTotals)
                    appBuckets[app.key] = (app, bucket.totals)
                } else {
                    appBuckets[app.key] = (app, packetTotals)
                }
            }

            // Domains own the traffic when known; only domain-less packets
            // contribute their IP addresses (destination first).
            let domain = domainIdentity(for: packet)
            if domain.kind == .domain {
                if var bucket = domainBuckets[domain.key] {
                    bucket.totals.add(packetTotals)
                    domainBuckets[domain.key] = (domain, bucket.totals)
                } else {
                    domainBuckets[domain.key] = (domain, packetTotals)
                }
            } else {
                for ip in ipAddressIdentities(for: packet) {
                    if var bucket = ipAddressBuckets[ip.key] {
                        bucket.totals.add(packetTotals)
                        ipAddressBuckets[ip.key] = (ip, bucket.totals)
                    } else {
                        ipAddressBuckets[ip.key] = (ip, packetTotals)
                    }
                }
            }

            let protocolName = protocolLabel(for: packet)
            protocolBuckets[protocolName, default: OverviewTotals()].add(packetTotals)

            if let service = CaptureOverviewClassifier.serviceKey(for: packet, isTCP: isTCP) {
                serviceBuckets[service, default: OverviewTotals()].add(packetTotals)
            }

                if let conversation = CaptureOverviewClassifier.conversation(for: packet, isTCP: isTCP) {
                    if var bucket = conversationBuckets[conversation.key] {
                        bucket.totals.add(packetTotals)
                        // A handshake settles which side is the client.
                        if conversation.isClientConfirmed, !confirmedConversationKeys.contains(conversation.key) {
                            bucket.clientAddress = conversation.clientAddress
                            bucket.clientPort = conversation.clientPort
                            bucket.serverAddress = conversation.serverAddress
                            bucket.serverPort = conversation.serverPort
                            confirmedConversationKeys.insert(conversation.key)
                        }
                        // Keep the last known names; SNI and DNS arrive on some
                        // packets of a conversation only.
                        if let domainName = packet.domainName {
                            bucket.domainName = domainName
                        }
                        if let appName = clientIdentity(for: packet)?.displayName {
                            bucket.appName = appName
                        }
                        conversationBuckets[conversation.key] = bucket
                    } else if conversationBuckets.count < maximumConversationBucketCount {
                        conversationBuckets[conversation.key] = OverviewConversationBucket(
                            clientAddress: conversation.clientAddress,
                            clientPort: conversation.clientPort,
                            serverAddress: conversation.serverAddress,
                            serverPort: conversation.serverPort,
                            domainName: packet.domainName,
                            appName: clientIdentity(for: packet)?.displayName,
                            totals: packetTotals
                        )
                        if conversation.isClientConfirmed {
                            confirmedConversationKeys.insert(conversation.key)
                        }
                    }
                }

                // Timeline covers every packet, regardless of endpoints.
                let timelineKey = Int64(floor(packet.timestamp.timeIntervalSince1970 / timelineWidth))
                timelineBuckets[timelineKey, default: OverviewTotals()].add(packetTotals)
                while timelineBuckets.count > maximumTimelineBucketCount, timelineWidth < timelineStorageWidths.last! {
                    // Compact into the next storage width; merges whole buckets.
                    guard let index = timelineStorageWidths.firstIndex(of: timelineWidth) else { break }
                    let nextIndex = min(index + 1, timelineStorageWidths.count - 1)
                    let nextWidth = timelineStorageWidths[nextIndex]
                    var merged: [Int64: OverviewTotals] = [:]
                    merged.reserveCapacity(timelineBuckets.count)
                    for (key, value) in timelineBuckets {
                        let ratio = Int64(nextWidth / timelineWidth)
                        merged[floorDivide(key, by: ratio), default: OverviewTotals()].add(value)
                    }
                    timelineBuckets = merged
                    timelineWidth = nextWidth
                }
        }

        let rendered = timelineRender(timelineBuckets: timelineBuckets, width: timelineWidth)

        return OverviewSnapshot(
            totals: totals,
            firstPacketDate: firstPacketDate,
            lastPacketDate: lastPacketDate,
            appCount: appBuckets.count,
            domainCount: domainBuckets.count,
            malformedPacketCount: malformedPacketCount,
            tcpPacketCount: tcpPacketCount,
            topApps: topAppRows(appBuckets: appBuckets),
            topDestinations: topDestinationRows(
                domainBuckets: domainBuckets,
                ipAddressBuckets: ipAddressBuckets
            ),
            protocols: protocolRows(protocolBuckets: protocolBuckets),
            tcpIssues: tcpIssueRows(tcpIssueCounts: tcpIssueCounts),
            topServices: topServiceRows(serviceBuckets: serviceBuckets),
            topConversations: topConversationRows(conversationBuckets: conversationBuckets),
            packetLengthCounts: packetLengthCounts,
            timeline: rendered.points,
            timelineInterval: rendered.interval
        )
    }

    // Integer division rounded toward negative infinity, like floor().
    private static func floorDivide(_ value: Int64, by divisor: Int64) -> Int64 {
        let quotient = value / divisor
        return value % divisor < 0 ? quotient - 1 : quotient
    }

    private static func timelineRender(
        timelineBuckets: [Int64: OverviewTotals],
        width: Double
    ) -> (points: [OverviewTimelinePoint], interval: Double) {
        guard let minimumKey = timelineBuckets.keys.min(),
              let maximumKey = timelineBuckets.keys.max() else {
            return ([], 1)
        }
        let span = (Double(maximumKey - minimumKey + 1)) * width
        let interval = renderedTimelineWidth(span: span, storageWidth: width)
        let ratio = Int64((interval / width).rounded())
        let firstKey = floorDivide(minimumKey, by: ratio)
        let lastKey = floorDivide(maximumKey, by: ratio)
        let count = Int(lastKey - firstKey) + 1

        var renderedTotals = [OverviewTotals](repeating: OverviewTotals(), count: count)
        for (key, value) in timelineBuckets {
            renderedTotals[Int(floorDivide(key, by: ratio) - firstKey)].add(value)
        }
        let points = renderedTotals.enumerated().map { offset, totals in
            OverviewTimelinePoint(date: Date(timeIntervalSince1970: (Double(firstKey + Int64(offset))) * interval), totals: totals)
        }
        return (points, interval)
    }

    // The smallest round slot width that fits the span in the slot budget and
    // merges whole storage buckets.
    static func renderedTimelineWidth(span: Double, storageWidth: Double) -> Double {
        // Keep one spare slot because the first slot starts before the first packet.
        let maximumSlots = Double(maximumRenderedTimelinePointCount - 1)
        let roundWidth = timelineRenderWidths.first { width in
            width >= storageWidth &&
                width.truncatingRemainder(dividingBy: storageWidth) == 0 &&
                span / width <= maximumSlots
        }
        return roundWidth ?? (span / maximumSlots / storageWidth).rounded(.up) * storageWidth
    }

    private static func trafficTotals(bytes: UInt64, direction: PacketDirection?) -> OverviewTotals {
        var value = OverviewTotals(packets: 1, bytes: bytes)
        switch direction {
        case .outbound:
            value.sentPackets = 1
            value.sentBytes = bytes
        case .inbound:
            value.receivedPackets = 1
            value.receivedBytes = bytes
        case .local, .unknown, nil:
            value.unclassifiedPackets = 1
            value.unclassifiedBytes = bytes
        }
        return value
    }

    // The apps with the most bytes; ties follow upstream's precedes rule
    // (bytes, then packets, then display title, then id).
    private static func topAppRows(
        appBuckets: [String: (identity: OverviewClientIdentity, totals: OverviewTotals)]
    ) -> [OverviewTopRow] {
        var rows: [OverviewTopRow] = []
        rows.reserveCapacity(maximumTopRowCount)
        for (key, bucket) in appBuckets {
            insertTopRow(
                OverviewTopRow(
                    id: "app:\(key)",
                    title: bucket.identity.displayName,
                    kind: "app",
                    key: key,
                    totals: bucket.totals
                ),
                into: &rows
            )
        }
        return rows
    }

    private static func topDestinationRows(
        domainBuckets: [String: (identity: OverviewDestinationIdentity, totals: OverviewTotals)],
        ipAddressBuckets: [String: (identity: OverviewDestinationIdentity, totals: OverviewTotals)]
    ) -> [OverviewTopRow] {
        var rows: [OverviewTopRow] = []
        rows.reserveCapacity(maximumTopRowCount)
        for (_, bucket) in domainBuckets {
            insertTopRow(
                OverviewTopRow(
                    id: "domain:\(bucket.identity.key)",
                    title: bucket.identity.displayName,
                    kind: "domain",
                    key: bucket.identity.key,
                    totals: bucket.totals
                ),
                into: &rows
            )
        }
        for (_, bucket) in ipAddressBuckets {
            insertTopRow(
                OverviewTopRow(
                    id: "ip:\(bucket.identity.key)",
                    title: bucket.identity.displayName,
                    kind: "ip",
                    key: bucket.identity.key,
                    totals: bucket.totals
                ),
                into: &rows
            )
        }
        return rows
    }

    private static func protocolRows(protocolBuckets: [String: OverviewTotals]) -> [OverviewProtocolRow] {
        let rows = protocolBuckets.map { title, totals in
            OverviewProtocolRow(id: title, title: title, totals: totals)
        }
        let sorted = rows.sorted { lhs, rhs in
            if lhs.totals.bytes != rhs.totals.bytes {
                return lhs.totals.bytes > rhs.totals.bytes
            }
            if lhs.totals.packets != rhs.totals.packets {
                return lhs.totals.packets > rhs.totals.packets
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        // Top rows plus one "Other" bucket, like upstream.
        guard sorted.count > maximumProtocolRowCount else {
            return sorted
        }
        var remainder = OverviewTotals()
        for row in sorted[maximumProtocolRowCount...] {
            remainder.add(row.totals)
        }
        return Array(sorted[0..<maximumProtocolRowCount]) + [
            OverviewProtocolRow(id: "__other__", title: "Other", totals: remainder),
        ]
    }

    private static func tcpIssueRows(tcpIssueCounts: [UInt64]) -> [OverviewTCPIssueRow] {
        var rows: [OverviewTCPIssueRow] = []
        rows.reserveCapacity(tcpIssueCounts.count)
        for kind in OverviewTCPIssueKind.allCases where tcpIssueCounts[kind.rawValue] > 0 {
            rows.append(OverviewTCPIssueRow(kind: kind, packets: tcpIssueCounts[kind.rawValue]))
        }
        return rows
    }

    // The server ports with the most bytes; ties keep well-known low ports
    // first, then alphabetical transports.
    private static func topServiceRows(serviceBuckets: [OverviewServiceKey: OverviewTotals]) -> [OverviewServiceRow] {
        var rows: [OverviewServiceRow] = []
        rows.reserveCapacity(maximumTopRowCount)
        for (key, totals) in serviceBuckets {
            insertRow(
                OverviewServiceRow(key: key, totals: totals),
                into: &rows
            ) { lhs, rhs in
                if lhs.totals.bytes != rhs.totals.bytes {
                    return lhs.totals.bytes > rhs.totals.bytes
                }
                if lhs.key.port != rhs.key.port {
                    return lhs.key.port < rhs.key.port
                }
                return lhs.key.transport.rawValue < rhs.key.transport.rawValue
            }
        }
        return rows
    }

    private static func topConversationRows(
        conversationBuckets: [String: OverviewConversationBucket]
    ) -> [OverviewConversationRow] {
        var rows: [OverviewConversationRow] = []
        rows.reserveCapacity(maximumTopRowCount)
        for (key, bucket) in conversationBuckets {
            insertRow(
                OverviewConversationRow(
                    key: key,
                    clientAddress: bucket.clientAddress,
                    clientPort: bucket.clientPort,
                    serverAddress: bucket.serverAddress,
                    serverPort: bucket.serverPort,
                    domainName: bucket.domainName,
                    appName: bucket.appName,
                    totals: bucket.totals
                ),
                into: &rows
            ) { lhs, rhs in
                if lhs.totals.bytes != rhs.totals.bytes {
                    return lhs.totals.bytes > rhs.totals.bytes
                }
                if lhs.totals.packets != rhs.totals.packets {
                    return lhs.totals.packets > rhs.totals.packets
                }
                return lhs.key < rhs.key
            }
        }
        return rows
    }

    // Bounded top rows: better rows displace the tail, and rows that would
    // land past the budget are dropped (upstream insertTopRow).
    private static func insertTopRow(_ row: OverviewTopRow, into rows: inout [OverviewTopRow]) {
        insertRow(row, into: &rows) { lhs, rhs in
            if lhs.totals.bytes != rhs.totals.bytes {
                return lhs.totals.bytes > rhs.totals.bytes
            }
            if lhs.totals.packets != rhs.totals.packets {
                return lhs.totals.packets > rhs.totals.packets
            }
            let titleComparison = lhs.title.caseInsensitiveCompare(rhs.title)
            if titleComparison != .orderedSame {
                return titleComparison == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    private static func insertRow<Row>(_ row: Row, into result: inout [Row], precedes: (Row, Row) -> Bool) {
        let insertionIndex = result.firstIndex { precedes(row, $0) } ?? result.endIndex
        if insertionIndex < maximumTopRowCount {
            result.insert(row, at: insertionIndex)
            if result.count > maximumTopRowCount {
                result.removeLast()
            }
        } else if result.count < maximumTopRowCount {
            result.append(row)
        }
    }

    // MARK: Identity helpers (PacketSourceListClassifier port)

    // Must match the GUI's clientKey: executable path first, display name as
    // fallback, so "app:<key>" tree nodes line up with Overview rows.
    static func clientIdentity(for packet: PacketSummary) -> OverviewClientIdentity? {
        guard let client = packet.client else {
            return nil
        }
        let trimmedExecutable = client.executablePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let executable = trimmedExecutable, !executable.isEmpty {
            return OverviewClientIdentity(key: executable, displayName: client.displayName)
        }
        let display = client.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !display.isEmpty {
            return OverviewClientIdentity(key: display, displayName: display)
        }
        let name = client.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            return OverviewClientIdentity(key: name, displayName: name)
        }
        return nil
    }

    static func canonicalDomainName(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard let normalized, !normalized.isEmpty, normalized.utf8.count <= 253 else {
            return nil
        }
        return normalized
    }

    static func domainIdentity(for packet: PacketSummary) -> OverviewDestinationIdentity {
        guard let domainName = canonicalDomainName(packet.domainName) else {
            return OverviewDestinationIdentity(kind: .ip, key: "", displayName: "IP Addresses")
        }
        return OverviewDestinationIdentity(kind: .domain, key: domainName, displayName: domainName)
    }

    static func ipAddressIdentities(for packet: PacketSummary) -> [OverviewDestinationIdentity] {
        // A known domain owns the packet entirely; only without one do the
        // raw addresses count toward Top Destinations.
        guard canonicalDomainName(packet.domainName) == nil else {
            return []
        }
        var seenKeys = Set<String>()
        var result: [OverviewDestinationIdentity] = []
        for address in [packet.endpoints.destination.address, packet.endpoints.source.address] {
            let trimmed = address?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else {
                continue
            }
            let key = trimmed.lowercased()
            guard seenKeys.insert(key).inserted else {
                continue
            }
            result.append(OverviewDestinationIdentity(kind: .ip, key: key, displayName: trimmed))
        }
        return result
    }

    // Protocol label match for the packet table's Protocol column.
    static func protocolLabel(for packet: PacketSummary) -> String {
        if let protocolSummary = packet.protocolSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines), !protocolSummary.isEmpty {
            return protocolSummary
        }

        if packet.transportHint == .tls {
            return packet.layers.reversed()
                .map(\.name)
                .first { name in
                    let uppercasedName = name.uppercased()
                    return uppercasedName.hasPrefix("TLS") || uppercasedName.hasPrefix("SSL")
                } ?? "TLS"
        }

        if packet.transportHint != .unknown {
            return packet.transportHint.rawValue.uppercased()
        }

        if let lastLayer = packet.layers.last?.name, !lastLayer.isEmpty {
            return lastLayer.uppercased()
        }

        return "UNKNOWN"
    }
}

// MARK: - IPC serialization (schema_version 1)

// JSON payload for capture.overview. UI strings live in the Qt Quick client;
// only intrinsic data (titles derived from packet data, well-known port
// names) is emitted here.
public enum CaptureOverviewIPC {
    static func totalsData(_ totals: OverviewTotals) -> [String: IPCValue] {
        var data: [String: IPCValue] = [:]
        data["packets"] = .int(Int(totals.packets))
        data["bytes"] = .int(Int(totals.bytes))
        if totals.sentPackets > 0 {
            data["sent_packets"] = .int(Int(totals.sentPackets))
            data["sent_bytes"] = .int(Int(totals.sentBytes))
        }
        if totals.receivedPackets > 0 {
            data["received_packets"] = .int(Int(totals.receivedPackets))
            data["received_bytes"] = .int(Int(totals.receivedBytes))
        }
        if totals.unclassifiedPackets > 0 {
            data["unclassified_packets"] = .int(Int(totals.unclassifiedPackets))
            data["unclassified_bytes"] = .int(Int(totals.unclassifiedBytes))
        }
        if totals.issuePackets > 0 {
            data["issue_packets"] = .int(Int(totals.issuePackets))
        }
        return data
    }

    static func topRowData(_ row: OverviewTopRow) -> IPCValue {
        .object([
            "id": .string(row.id),
            "title": .string(row.title),
            "kind": row.kind.map { IPCValue.string($0) } ?? .null,
            "key": row.key.map { IPCValue.string($0) } ?? .null,
            "totals": .object(totalsData(row.totals)),
        ])
    }

    public static func snapshotData(_ snapshot: OverviewSnapshot, sourceID: String, revision: (count: Int, updateSeq: UInt64)) -> [String: IPCValue] {
        var data: [String: IPCValue] = [:]
        data["source_id"] = .string(sourceID)
        data["revision"] = .object([
            "count": .int(revision.count),
            "update_seq": .int(Int(revision.updateSeq)),
        ])
        data["totals"] = .object(totalsData(snapshot.totals))
        data["first_packet_ms"] = snapshot.firstPacketDate.map {
            IPCValue.int(Int(($0.timeIntervalSince1970 * 1000).rounded()))
        } ?? .null
        data["last_packet_ms"] = snapshot.lastPacketDate.map {
            IPCValue.int(Int(($0.timeIntervalSince1970 * 1000).rounded()))
        } ?? .null
        data["app_count"] = .int(snapshot.appCount)
        data["domain_count"] = .int(snapshot.domainCount)
        data["malformed_packet_count"] = .int(Int(snapshot.malformedPacketCount))
        data["tcp_packet_count"] = .int(Int(snapshot.tcpPacketCount))
        data["top_apps"] = .array(snapshot.topApps.map(topRowData))
        data["top_destinations"] = .array(snapshot.topDestinations.map(topRowData))
        data["protocols"] = .array(snapshot.protocols.map { row in
            .object([
                "title": .string(row.title),
                "totals": .object(totalsData(row.totals)),
            ])
        })
        data["tcp_issues"] = .array(snapshot.tcpIssues.map { row in
            .object([
                "kind": .string(overviewIssueName(row.kind)),
                "severity": .int(row.kind.rawValue),
                "packets": .int(Int(row.packets)),
                "filter": .string(CaptureOverviewClassifier.displayFilter(for: row.kind)),
            ])
        })
        data["top_services"] = .array(snapshot.topServices.map { row in
            .object([
                "transport": .string(row.key.transport.rawValue),
                "port": .int(Int(row.key.port)),
                "service_name": CaptureOverviewClassifier.serviceName(for: row.key).map { IPCValue.string($0) } ?? .null,
                "totals": .object(totalsData(row.totals)),
            ])
        })
        data["top_conversations"] = .array(snapshot.topConversations.map { row in
            .object([
                "key": .string(row.key),
                "client_address": .string(row.clientAddress),
                "client_port": .int(Int(row.clientPort)),
                "server_address": .string(row.serverAddress),
                "server_port": .int(Int(row.serverPort)),
                "domain_name": row.domainName.map { IPCValue.string($0) } ?? .null,
                "app_name": row.appName.map { IPCValue.string($0) } ?? .null,
                "totals": .object(totalsData(row.totals)),
            ])
        })
        data["packet_lengths"] = .array(snapshot.packetLengthCounts.map { .int(Int($0)) })
        data["timeline_interval_ms"] = .int(Int((snapshot.timelineInterval * 1000).rounded()))
        data["timeline"] = .array(snapshot.timeline.map { point in
            .object([
                "date_ms": .int(Int((point.date.timeIntervalSince1970 * 1000).rounded())),
                "totals": .object(totalsData(point.totals)),
            ])
        })
        return data
    }

    static func overviewIssueName(_ kind: OverviewTCPIssueKind) -> String {
        switch kind {
        case .malformed: "malformed"
        case .lostSegment: "lost_segment"
        case .retransmission: "retransmission"
        case .outOfOrder: "out_of_order"
        case .zeroWindow: "zero_window"
        case .duplicateAck: "duplicate_ack"
        case .reset: "reset"
        }
    }
}
