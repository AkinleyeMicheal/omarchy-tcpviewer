//
//  CommandRouter.swift
//  tcpviewerd
//
//  Maps schema_version 1 commands onto SourceManager operations and
//  serializes core models to the wire format (decimal-string packet IDs,
//  ISO 8601 timestamps, lowercase snake_case, per upstream CLI.md).
//

import Foundation
import PcapPlusPlusCore
import TCPViewerIPC

final class CommandRouter: @unchecked Sendable {
    private let manager: SourceManager
    private let socketPath: String
    private let startedAt = Date()

    init(manager: SourceManager, socketPath: String) {
        self.manager = manager
        self.socketPath = socketPath
    }

    /// `setSubscription` lets `events.subscribe` reach the owning connection
    /// without the router holding server/connection references.
    func handle(
        request: IPCRequest,
        setSubscription: @escaping (Bool) -> Void,
        completion: @escaping (IPCResponse) -> Void
    ) {
        let respond: (Result<[String: IPCValue], Error>) -> Void = { result in
            switch result {
            case .success(let data):
                completion(.success(requestID: request.requestID, command: request.command.rawValue, data: data))
            case .failure(let error):
                let mapped = self.wireError(error)
                // Payload errors (e.g. partial imports) keep their data field.
                let data = (error as? PayloadError)?.data
                completion(.failure(
                    requestID: request.requestID,
                    command: request.command.rawValue,
                    code: mapped.code,
                    message: mapped.message,
                    data: data
                ))
            }
        }

        switch request.command {
        case .appStatus:
            respond(.success(appStatus()))

        case .interfacesList:
            manager.listInterfaces { result in
                respond(result.map { interfaces in
                    ["interfaces": .array(interfaces.map { Self.interfaceData($0) })]
                })
            }

        case .captureStart:
            do {
                let interface = try request.requireString("interface")
                let bpf = request.optionalString("bpf")
                let promiscuous = request.optionalBool("promiscuous")
                manager.startCapture(interfaceID: interface, bpf: bpf, promiscuous: promiscuous) { result in
                    respond(result.map { self.manager.statusData(for: $0) })
                }
            } catch {
                respond(.failure(error))
            }

        case .capturePause, .captureResume, .captureStop:
            let action: String
            switch request.command {
            case .capturePause: action = "pause"
            case .captureResume: action = "resume"
            default: action = "stop"
            }
            manager.controlCapture(id: request.optionalString("source_id"), action: action) { result in
                respond(result.map { self.manager.statusData(for: $0) })
            }

        case .captureStatus:
            manager.captureStatus(sourceID: request.optionalString("source_id")) { result in
                respond(result)
            }

        case .sourcesList:
            manager.sourcesSnapshot { sources in
                respond(.success([
                    "count": .int(sources.count),
                    "sources": .array(sources.map { .object(self.manager.statusData(for: $0)) }),
                ]))
            }

        case .sourceClose:
            do {
                let id = try request.requireString("source_id")
                manager.closeSource(id: id) { result in
                    respond(result.map { _ in ["source_id": .string(id), "closed": .bool(true)] })
                }
            } catch {
                respond(.failure(error))
            }

        case .packetsList, .packetsSummary:
            do {
                let query = try PacketQueryParams(request: request)
                manager.queryPackets(
                    sourceID: query.sourceID,
                    sinceID: query.sinceID,
                    offset: query.offset,
                    limit: query.limit,
                    filter: query.filter,
                    quickFilters: query.quick,
                    updatesSince: query.updatesSince
                ) { result in
                    respond(result.map { Self.queryData($0) })
                }
            } catch {
                respond(.failure(error))
            }

        case .packetsDetails:
            do {
                let packetID = try request.requirePacketID()
                let maxDepth = try request.requireBoundedInt("max_depth", default: 12, range: 0...12)
                let maxNodes = try request.requireBoundedInt("max_nodes", default: 5_000, range: 1...5_000)
                manager.inspectPacket(
                    sourceID: request.optionalString("source_id"),
                    packetID: packetID,
                    maxDepth: maxDepth,
                    maxNodes: maxNodes
                ) { result in
                    respond(result.map { inspection, sourceID in
                        var budget = maxNodes
                        return [
                            "packet_id": .string(String(packetID)),
                            "source_id": .string(sourceID),
                            "decode_status": .string(inspection.decodeStatus.kind.rawValue),
                            "nodes": .array(Self.detailNodes(
                                inspection.detailNodes,
                                depthLeft: maxDepth,
                                budget: &budget
                            )),
                            "nodes_truncated": .bool(budget <= 0),
                            "byte_length": .int(inspection.rawBytes.count),
                        ]
                    })
                }
            } catch {
                respond(.failure(error))
            }

        case .packetsBytes:
            do {
                let packetID = try request.requirePacketID()
                let offset = try request.requireBoundedInt("offset", default: 0, range: 0...Int(Int32.max))
                let length = try request.requireBoundedInt("length", default: 0, range: 0...65_536)
                let encoding = request.optionalString("encoding") ?? "base64"
                guard ["base64", "hex"].contains(encoding) else {
                    throw SourceError(code: IPCError.invalidParams, message: "encoding must be base64 or hex")
                }
                manager.inspectPacket(
                    sourceID: request.optionalString("source_id"),
                    packetID: packetID,
                    maxDepth: 0,
                    maxNodes: 1
                ) { result in
                    do {
                        let inspection = try result.get()
                        let raw = inspection.inspection.rawBytes
                        guard offset <= raw.count else {
                            throw SourceError(code: IPCError.invalidParams, message: "offset beyond packet end (\(raw.count) bytes)")
                        }
                        // length 0 (default) = from offset to end, capped 65536.
                        let sliceEnd = length == 0 ? raw.count : min(offset + length, raw.count)
                        let slice = raw.subdata(in: offset..<sliceEnd)
                        respond(.success([
                            "packet_id": .string(String(packetID)),
                            "offset": .int(offset),
                            "length": .int(slice.count),
                            "total_length": .int(raw.count),
                            "encoding": .string(encoding),
                            "data": .string(Self.encodeBytes(slice, encoding: encoding)),
                        ]))
                    } catch {
                        respond(.failure(error))
                    }
                }
            } catch {
                respond(.failure(error))
            }

        case .packetsClear:
            guard request.bool("yes") == true else {
                return respond(.failure(SourceError(
                    code: IPCError.invalidParams,
                    message: "packets.clear requires yes=true (--yes)"
                )))
            }
            manager.clearPackets(sourceID: request.optionalString("source_id")) { result in
                respond(result.map { _ in ["cleared": .bool(true)] })
            }

        case .streamPackets:
            do {
                let streamID = try request.requireString("stream_id")
                let offset = try request.requireBoundedInt("offset", default: 0, range: 0...Int(Int32.max))
                let limit = try request.requireBoundedInt("limit", default: 500, range: 1...5_000)
                manager.streamPackets(
                    sourceID: request.optionalString("source_id"),
                    streamKey: streamID,
                    offset: offset,
                    limit: limit
                ) { result in
                    respond(result.map { packets, total, nextOffset, sourceID in
                        [
                            "stream_id": .string(streamID),
                            "source_id": .string(sourceID),
                            "packets": .array(packets.map { Self.packetData($0, full: false) }),
                            "total_count": .int(total),
                            "next_offset": .int(nextOffset),
                        ]
                    })
                }
            } catch {
                respond(.failure(error))
            }

        case .streamFollow:
            do {
                let packetID = try request.requirePacketID()
                let encoding = request.optionalString("encoding") ?? "text"
                guard ["text", "hex", "base64"].contains(encoding) else {
                    throw SourceError(code: IPCError.invalidParams, message: "encoding must be text, hex, or base64")
                }
                manager.followStream(
                    sourceID: request.optionalString("source_id"),
                    packetID: packetID,
                    direction: request.optionalString("direction")
                ) { result in
                    switch result {
                    case .failure(let error):
                        respond(.failure(error))
                    case .success(let payload):
                        respond(.success(Self.followData(
                            stream: payload.stream,
                            packetID: packetID,
                            sourceID: payload.sourceID,
                            followID: payload.followID,
                            encoding: encoding
                        )))
                    }
                }
            } catch {
                respond(.failure(error))
            }

        case .fileImport:
            do {
                let paths = try request.requirePathList()
                importSequentially(paths: paths, index: 0, imported: [], completion: respond)
            } catch {
                respond(.failure(error))
            }

        case .fileExport:
            do {
                let path = try request.requireString("path")
                let format = request.optionalString("format") ?? "pcapng"
                guard ["pcap", "pcapng"].contains(format) else {
                    throw SourceError(code: IPCError.invalidParams, message: "format must be pcap or pcapng")
                }
                let all = request.bool("all") ?? false
                let ids = try request.optionalPacketIDArray("packet_ids")
                manager.exportPackets(
                    sourceID: request.optionalString("source_id"),
                    path: path,
                    format: format,
                    all: all,
                    packetIDs: ids,
                    overwrite: request.bool("overwrite") ?? false
                ) { result in
                    respond(result)
                }
            } catch {
                respond(.failure(error))
            }

        case .fileExportSession:
            do {
                let path = try request.requireString("path")
                manager.exportSession(
                    sourceID: request.optionalString("source_id"),
                    path: path,
                    overwrite: request.bool("overwrite") ?? false
                ) { result in
                    respond(result)
                }
            } catch {
                respond(.failure(error))
            }

        case .eventsSubscribe:
            let enabled = request.bool("enabled") ?? true
            setSubscription(enabled)
            respond(.success(["events": .bool(enabled)]))
        }
    }

    // MARK: - Sequential import (partial results reported in error data)

    private func importSequentially(
        paths: [String],
        index: Int,
        imported: [String],
        completion: @escaping (Result<[String: IPCValue], Error>) -> Void
    ) {
        guard index < paths.count else {
            return completion(.success([
                "imported": .array(imported.map { .string($0) }),
                "source_count": .int(imported.count),
            ]))
        }
        manager.importFile(path: paths[index]) { result in
            switch result {
            case .success:
                var rows = imported
                rows.append(paths[index])
                self.importSequentially(paths: paths, index: index + 1, imported: rows, completion: completion)
            case .failure(let error):
                // Upstream parity: partial imports keep their file info in the
                // error response so clients know what did make it in.
                var data = [String: IPCValue]()
                if !imported.isEmpty {
                    data["imported"] = .array(imported.map { .string($0) })
                }
                data["failed_path"] = .string(paths[index])
                let mapped = self.wireError(error)
                completion(.failure(PayloadError(code: mapped.code, message: mapped.message, data: data)))
            }
        }
    }

    // MARK: - Status / data builders

    private func appStatus() -> [String: IPCValue] {
        var capabilities: [String: IPCValue] = [:]
        // Effective capability bits from /proc/self/status (CapEff hex):
        // CAP_NET_ADMIN=12, CAP_NET_RAW=13 — needed for live capture.
        if let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8),
            let line = status.split(separator: "\n").first(where: { $0.hasPrefix("CapEff:") }),
            let hex = line.split(separator: "\t").last,
            let mask = UInt64(hex.trimmingCharacters(in: .whitespaces), radix: 16) {
            capabilities["net_admin"] = .bool((mask >> 12) & 1 == 1)
            capabilities["net_raw"] = .bool((mask >> 13) & 1 == 1)
        } else {
            capabilities["net_admin"] = .bool(false)
            capabilities["net_raw"] = .bool(false)
        }

        return [
            "version": .string(SourceManager.daemonVersion),
            "schema_version": .int(IPCRequest.schemaVersion),
            "pid": .int(Int(getpid())),
            "uptime_seconds": .int(Int(Date().timeIntervalSince(startedAt))),
            "socket_path": .string(socketPath),
            "commands": .array(IPCCommand.allCases.map { .string($0.rawValue) }),
            "capabilities": .object(capabilities),
            "wireshark": .object(["built_against": .string(Self.builtAgainstWiresharkVersion())]),
        ]
    }

    /// Compile-time headers version — runtime libwireshark comes from the
    /// same Arch package (wireshark-cli), so this is the honest pairing.
    private static func builtAgainstWiresharkVersion() -> String {
        guard let header = try? String(contentsOfFile: "/usr/include/wireshark/ws_version.h", encoding: .utf8) else {
            return "unknown"
        }
        var parts: [String] = []
        for key in ["WIRESHARK_VERSION_MAJOR", "WIRESHARK_VERSION_MINOR", "WIRESHARK_VERSION_MICRO"] {
            guard let line = header.split(separator: "\n").first(where: { $0.contains("#define \(key)") }) else { continue }
            let tokens = line.split(separator: " ")
            if let value = tokens.last, Int(value) != nil {
                parts.append(String(value))
            }
        }
        return parts.isEmpty ? "unknown" : parts.joined(separator: ".")
    }

    static func interfaceData(_ interface: CaptureInterfaceSummary) -> IPCValue {
        var data: [String: IPCValue] = [
            "id": .string(interface.id),
            "technical_name": .string(interface.technicalName),
            "display_name": .string(interface.displayName),
            "is_loopback": .bool(interface.isLoopback),
            "link_type": .string(interface.linkType.rawValue),
            "availability": .string(interface.availability.rawValue),
            "addresses": .array(interface.addresses.map {
                .object(["family": .string($0.family.rawValue), "value": .string($0.value)])
            }),
            "capabilities": .object([
                "can_capture": .bool(interface.capabilities.canCapture),
                "supports_promiscuous_mode": .bool(interface.capabilities.supportsPromiscuousMode),
            ]),
        ]
        if let friendly = interface.friendlyName {
            data["friendly_name"] = .string(friendly)
        }
        if let description = interface.interfaceDescription {
            data["description"] = .string(description)
        }
        if let reason = interface.availabilityReason {
            data["availability_reason"] = .string(reason)
        }
        return .object(data)
    }

    /// Schema: packet ids are decimal strings; timestamps ISO 8601.
    static func packetData(_ packet: PacketSummary, full: Bool) -> IPCValue {
        var data: [String: IPCValue] = [
            "packet_id": .string(String(packet.id)),
            "packet_number": .string(String(packet.packetNumber)),
            "timestamp": .string(isoTimestamp(packet.timestamp)),
            "source_kind": .string(packet.source.rawValue),
            "transport": .string(packet.transportHint.rawValue),
            "source": .object(endpointData(packet.endpoints.source)),
            "destination": .object(endpointData(packet.endpoints.destination)),
            "length": .int(packet.capturedLength),
            "original_length": .int(packet.originalLength),
            "info": .string(packet.infoSummary),
            "decode_status": .string(packet.decodeStatus.kind.rawValue),
        ]
        if let protocolSummary = packet.protocolSummary {
            data["protocol"] = .string(protocolSummary)
        }
        if let interfaceID = packet.interfaceID {
            data["interface"] = .string(interfaceID)
        }
        if let follow = packet.followStreamID {
            data["stream_id"] = .string("\(follow.streamProtocol.rawValue):\(follow.streamID)")
        } else if let streamID = packet.streamID {
            data["stream_id"] = .string(String(streamID))
        }
        if let flags = packet.tcpFlags {
            data["tcp_flags"] = .string(flags)
        }
        if let payloadLength = packet.tcpPayloadLength {
            data["tcp_payload_length"] = .int(payloadLength)
        }
        if let direction = packet.direction {
            data["direction"] = .string(direction.rawValue)
        }
        if let sni = packet.sniDomainName {
            data["sni"] = .string(sni)
        }
        if let dns = packet.dnsDomainName {
            data["dns_name"] = .string(dns)
        }
        if full {
            if !packet.layers.isEmpty {
                data["layers"] = .array(packet.layers.map {
                    .object([
                        "name": .string($0.name),
                        "detail": $0.detailSummary.map { .string($0) } ?? .null,
                    ])
                })
            }
            if let client = packet.client {
                data["client"] = .object([
                    "pid": .int(Int(client.pid)),
                    "name": .string(client.name),
                    "display_name": .string(client.displayName),
                ])
            }
            if let comment = packet.customComment {
                data["comment"] = .string(comment)
            }
        }
        return .object(data)
    }

    static func endpointData(_ endpoint: PacketEndpoint) -> [String: IPCValue] {
        [
            "address": endpoint.address.map { .string($0) } ?? .null,
            "port": endpoint.port.map { .int(Int($0)) } ?? .null,
        ]
    }

    static func queryData(_ result: SourceManager.PacketQueryResult) -> [String: IPCValue] {
        var data: [String: IPCValue] = [
            "source_id": .string(result.sourceID),
            "packets": .array(result.packets.map { packetData($0, full: false) }),
            "total_count": .int(result.totalCount),
            "next_offset": .int(result.nextOffset),
            "complete": .bool(result.complete),
            "update_seq": .string(String(result.updateSeq)),
            "updates_overflow": .bool(result.updatesOverflow),
        ]
        if let filter = result.appliedFilter {
            data["display_filter"] = .string(filter)
        }
        if let quick = result.appliedQuick, !quick.isEmpty {
            data["quick_filters"] = .array(quick.map { .string($0) })
        }
        if !result.updates.isEmpty {
            data["updates"] = .array(result.updates.map { update in
                .object([
                    "seq": .string(String(update.seq)),
                    "packet_ids": .array(update.ids.map { .string(String($0)) }),
                ])
            })
        }
        return data
    }

    /// stream.follow payload — separate builder keeps the response literal
    /// small enough for the type checker (huge nested literals time out).
    static func followData(
        stream: FollowStream,
        packetID: UInt64,
        sourceID: String,
        followID: FollowStreamID?,
        encoding: String
    ) -> [String: IPCValue] {
        var data: [String: IPCValue] = [
            "packet_id": .string(String(packetID)),
            "source_id": .string(sourceID),
            "protocol": .string(stream.streamProtocol.rawValue),
            "client": .object(endpointData(stream.client)),
            "server": .object(endpointData(stream.server)),
            "client_bytes": .int(stream.clientByteCount),
            "server_bytes": .int(stream.serverByteCount),
            "captured_through_packet_id": .string(String(stream.capturedThroughPacketID)),
            "is_truncated": .bool(stream.isTruncated),
            "record_count": .int(stream.records.count),
            "records": .array(stream.records.map { record in
                .object([
                    "direction": .string(record.direction.rawValue),
                    "packet_id": .string(String(record.packetID)),
                    "timestamp": .string(isoTimestamp(record.timestamp)),
                    "sequence": record.sequenceNumber.map { .int(Int($0)) } ?? .null,
                    "data": .string(encodeBytes(record.data, encoding: encoding)),
                ])
            }),
        ]
        if let followID {
            data["stream_id"] = .string("\(followID.streamProtocol.rawValue):\(followID.streamID)")
        }
        return data
    }

    /// Depth- and node-budgeted protocol-tree serialization.
    static func detailNodes(_ nodes: [PacketDetailNode], depthLeft: Int, budget: inout Int) -> [IPCValue] {
        guard depthLeft >= 0, budget > 0 else { return [] }
        var result: [IPCValue] = []
        for node in nodes {
            guard budget > 0 else { break }
            budget -= 1
            var data: [String: IPCValue] = [
                "id": .string(node.id),
                "name": .string(node.name),
                "kind": .string(node.kind.rawValue),
                "severity": .string(node.severity.rawValue),
            ]
            if !node.fieldName.isEmpty {
                data["field"] = .string(node.fieldName)
            }
            if let value = node.value {
                data["value"] = .string(value)
            }
            if let rawValue = node.rawValue {
                data["raw_value"] = .string(rawValue)
            }
            if let filter = node.displayFilterExpression {
                data["filter"] = .string(filter)
            }
            if let range = node.byteRange {
                data["byte_range"] = .object([
                    "offset": .int(range.offset),
                    "length": .int(range.length),
                ])
            }
            if let jump = node.jumpTargetPacketID {
                data["jump_packet_id"] = .string(String(jump))
            }
            if !node.children.isEmpty, depthLeft > 0 {
                data["children"] = .array(detailNodes(node.children, depthLeft: depthLeft - 1, budget: &budget))
            }
            result.append(.object(data))
        }
        return result
    }

    static func encodeBytes(_ data: Data, encoding: String) -> String {
        switch encoding {
        case "hex":
            return data.map { String(format: "%02x", $0) }.joined()
        default:
            return data.base64EncodedString()
        }
    }

    static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: - Error mapping

    struct PayloadError: Error {
        let code: String
        let message: String
        let data: [String: IPCValue]?
    }

    private func wireError(_ error: Error) -> (code: String, message: String) {
        if let error = error as? PayloadError {
            return (error.code, error.message)
        }
        if let error = error as? SourceError {
            return (error.code, error.message)
        }
        if let error = error as? IPCFramingError {
            return (error.code, error.message)
        }
        if let error = error as? TCPViewerCoreError {
            switch error.code {
            case .capturePermissionDenied:
                return (IPCError.permissionDenied, error.message)
            case .invalidCaptureFilter, .invalidCaptureOptions, .malformedCapture:
                return (IPCError.invalidParams, error.message)
            case .unsupportedInterface:
                return (IPCError.notFound, error.message)
            default:
                return (IPCError.appCommandFailed, error.message)
            }
        }
        return (IPCError.appCommandFailed, String(describing: error))
    }
}

// MARK: - Request parameter helpers (validate untrusted input)

/// Query parameters shared by packets.list / packets.summary — bounded per
/// upstream CLI.md (pages ≤ 5000 rows; ids are decimal strings).
struct PacketQueryParams {
    let sourceID: String?
    let sinceID: UInt64?
    let offset: Int
    let limit: Int
    let filter: String?
    let quick: [String]
    let updatesSince: UInt64?

    init(request: IPCRequest) throws {
        sourceID = request.optionalString("source_id")
        sinceID = try request.optionalDecimalID("since_id")
        offset = try request.requireBoundedInt("offset", default: 0, range: 0...Int(Int32.max))
        limit = try request.requireBoundedInt("limit", default: 500, range: 1...5_000)
        filter = request.optionalString("filter")
        quick = request.array("quick_filters")?.compactMap { $0.stringValue } ?? []
        updatesSince = try request.optionalDecimalID("updates_since")
    }
}

extension IPCRequest {
    func requireString(_ key: String) throws -> String {
        guard let value = params[key]?.stringValue, !value.isEmpty else {
            throw SourceError(code: IPCError.invalidParams, message: "missing string param: \(key)")
        }
        return value
    }

    func optionalString(_ key: String) -> String? { params[key]?.stringValue }

    func optionalBool(_ key: String) -> Bool? { params[key]?.boolValue }

    func requireBoundedInt(_ key: String, default defaultValue: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value = params[key] else { return defaultValue }
        guard let intValue = value.intValue, range.contains(intValue) else {
            throw SourceError(
                code: IPCError.invalidParams,
                message: "\(key) must be an integer in \(range.lowerBound)...\(range.upperBound)"
            )
        }
        return intValue
    }

    /// Packet IDs arrive as decimal strings per schema_version 1 (ints accepted).
    func requirePacketID() throws -> UInt64 {
        guard let value = params["packet_id"] else {
            throw SourceError(code: IPCError.invalidParams, message: "missing param: packet_id")
        }
        if let string = value.stringValue, let id = UInt64(string) { return id }
        if let intValue = value.intValue, intValue >= 0 { return UInt64(intValue) }
        throw SourceError(code: IPCError.invalidParams, message: "packet_id must be a decimal string")
    }

    /// Decimal cursor ids (since_id / updates_since): schema says strings,
    /// ints accepted.
    func optionalDecimalID(_ key: String) throws -> UInt64? {
        guard let value = params[key] else { return nil }
        if case .null = value { return nil }
        if let string = value.stringValue, let id = UInt64(string) { return id }
        if let intValue = value.intValue, intValue >= 0 { return UInt64(intValue) }
        throw SourceError(code: IPCError.invalidParams, message: "\(key) must be a decimal id")
    }

    func optionalPacketIDArray(_ key: String) throws -> [UInt64]? {
        guard let array = params[key]?.arrayValue else { return nil }
        var ids: [UInt64] = []
        for element in array {
            if let string = element.stringValue, let id = UInt64(string) {
                ids.append(id)
            } else if let intValue = element.intValue, intValue >= 0 {
                ids.append(UInt64(intValue))
            } else {
                throw SourceError(code: IPCError.invalidParams, message: "\(key) must contain decimal packet ids")
            }
        }
        return ids
    }

    func requirePathList() throws -> [String] {
        if let paths = params["paths"]?.arrayValue {
            let values = paths.compactMap { $0.stringValue }
            guard values.count == paths.count, !values.isEmpty else {
                throw SourceError(code: IPCError.invalidParams, message: "paths must be non-empty strings")
            }
            return values
        }
        if let path = params["path"]?.stringValue {
            return [path]
        }
        throw SourceError(code: IPCError.invalidParams, message: "missing param: paths")
    }
}
