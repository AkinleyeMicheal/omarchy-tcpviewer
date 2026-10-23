//
//  PacketClientResolver.swift
//  tcpviewerd
//
//  Linux port of upstream's MacOSPacketClientResolver (ADR-4). Maps a packet's
//  local TCP/UDP endpoint to the process that owns the socket by joining
//  /proc/net/{tcp,tcp6,udp,udp6} socket inodes with /proc/<pid>/fd links.
//

import Foundation
import Glibc

public final class PacketClientResolver: @unchecked Sendable {
    public struct Resolution {
        public let client: PacketClient
        public let direction: PacketDirection

        public init(client: PacketClient, direction: PacketDirection) {
            self.client = client
            self.direction = direction
        }
    }

    fileprivate enum SocketTransport: Hashable {
        case tcp
        case udp
    }

    fileprivate struct SocketEndpoint: Hashable {
        let address: String
        let port: UInt16
    }

    private struct SocketKey: Hashable {
        let transport: SocketTransport
        let local: SocketEndpoint
        let remote: SocketEndpoint
    }

    private struct LocalEndpointKey: Hashable {
        let transport: SocketTransport
        let endpoint: SocketEndpoint
    }

    private struct LocalPortKey: Hashable {
        let transport: SocketTransport
        let port: UInt16
    }

    private struct PacketLookupKey: Hashable {
        let transport: SocketTransport
        let source: SocketEndpoint
        let destination: SocketEndpoint

        init?(packet: PacketSummary) {
            guard let transport = SocketTransport(packet: packet),
                  let source = SocketEndpoint(packet.endpoints.source),
                  let destination = SocketEndpoint(packet.endpoints.destination) else {
                return nil
            }
            self.transport = transport
            self.source = source
            self.destination = destination
        }
    }

    private struct SocketRecord {
        let transport: SocketTransport
        let local: SocketEndpoint
        let remote: SocketEndpoint?
    }

    private struct Snapshot {
        let builtAt: Date
        let bySocket: [SocketKey: PacketClient]
        let byLocalEndpoint: [LocalEndpointKey: PacketClient]
        let byLocalPort: [LocalPortKey: PacketClient]

        static let empty = Snapshot(
            builtAt: .distantPast,
            bySocket: [:],
            byLocalEndpoint: [:],
            byLocalPort: [:]
        )
    }

    private let procRoot: String
    private let snapshotTTL: TimeInterval
    private let scanQueue = DispatchQueue(label: "org.omarchy.tcpviewerd.client-resolver")
    private let lock = NSLock()
    private var snapshot: Snapshot?
    private var refreshInFlight = false

    // Bounds keep a pathological /proc from stalling the capture queue.
    private let maximumScannedFileDescriptors = 200_000

    public init(procRoot: String = "/proc", snapshotTTL: TimeInterval = 0.5) {
        self.procRoot = procRoot
        self.snapshotTTL = max(snapshotTTL, 0.05)
    }

    /// Build the first snapshot synchronously; call once before capture starts.
    public func prime() {
        let built = buildSnapshot()
        lock.lock()
        snapshot = built
        lock.unlock()
    }

    /// Resolve a packet to the process that owns its local socket. Cheap after
    /// the first snapshot; a stale snapshot is refreshed in the background.
    public func resolution(for packet: PacketSummary) -> Resolution? {
        guard let lookupKey = PacketLookupKey(packet: packet) else {
            return nil
        }

        var current: Snapshot?
        var shouldRefresh = false
        lock.lock()
        current = snapshot
        if snapshot == nil || Date().timeIntervalSince(snapshot!.builtAt) >= snapshotTTL {
            if !refreshInFlight {
                refreshInFlight = true
                shouldRefresh = true
            }
        }
        lock.unlock()

        if shouldRefresh {
            scanQueue.async { [weak self] in
                self?.refresh()
            }
        }

        guard let snapshot = current else {
            return nil
        }
        return resolve(lookupKey, in: snapshot)
    }

    private func refresh() {
        let built = buildSnapshot()
        lock.lock()
        snapshot = built
        refreshInFlight = false
        lock.unlock()
    }

    private func resolve(_ lookupKey: PacketLookupKey, in snapshot: Snapshot) -> Resolution? {
        // Exact 4-tuple first: source→destination is outbound, reverse inbound.
        if let client = snapshot.bySocket[SocketKey(
            transport: lookupKey.transport,
            local: lookupKey.source,
            remote: lookupKey.destination
        )] {
            return Resolution(client: client, direction: .outbound)
        }

        if let client = snapshot.bySocket[SocketKey(
            transport: lookupKey.transport,
            local: lookupKey.destination,
            remote: lookupKey.source
        )] {
            return Resolution(client: client, direction: .inbound)
        }

        let sourceClient = snapshot.byLocalEndpoint[LocalEndpointKey(
            transport: lookupKey.transport,
            endpoint: lookupKey.source
        )]
        let destinationClient = snapshot.byLocalEndpoint[LocalEndpointKey(
            transport: lookupKey.transport,
            endpoint: lookupKey.destination
        )]

        if let sourceClient, destinationClient != nil {
            return Resolution(client: sourceClient, direction: .local)
        }
        if let sourceClient {
            return Resolution(client: sourceClient, direction: .outbound)
        }
        if let destinationClient {
            return Resolution(client: destinationClient, direction: .inbound)
        }

        // Wildcard binds (0.0.0.0/::) do not match the packet's concrete local
        // address, so fall back to the unique local port when possible.
        if let client = snapshot.byLocalPort[LocalPortKey(
            transport: lookupKey.transport,
            port: lookupKey.source.port
        )] {
            return Resolution(client: client, direction: .outbound)
        }
        if let client = snapshot.byLocalPort[LocalPortKey(
            transport: lookupKey.transport,
            port: lookupKey.destination.port
        )] {
            return Resolution(client: client, direction: .inbound)
        }

        return nil
    }

    private func buildSnapshot() -> Snapshot {
        let records = loadSocketRecords()
        guard !records.isEmpty else {
            return .empty
        }

        var bySocket: [SocketKey: PacketClient] = [:]
        var byLocalEndpoint: [LocalEndpointKey: PacketClient] = [:]
        var localPortPIDs: [LocalPortKey: Set<pid_t>] = [:]
        var localPortClients: [LocalPortKey: PacketClient] = [:]
        var clientsByPID: [pid_t: PacketClient] = [:]
        var scannedFileDescriptors = 0

        scanLoop: for pid in processIdentifiers() {
            let fdDirectory = "\(procRoot)/\(pid)/fd"
            guard let descriptors = try? FileManager.default.contentsOfDirectory(atPath: fdDirectory) else {
                continue
            }

            for descriptor in descriptors {
                scannedFileDescriptors += 1
                if scannedFileDescriptors > maximumScannedFileDescriptors {
                    break scanLoop
                }

                let linkPath = "\(fdDirectory)/\(descriptor)"
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath),
                      target.hasPrefix("socket:["),
                      target.hasSuffix("]"),
                      let inode = UInt64(target.dropFirst("socket:[".count).dropLast()),
                      let record = records[inode] else {
                    continue
                }

                let client: PacketClient
                if let cached = clientsByPID[pid] {
                    client = cached
                } else {
                    client = makeClient(pid: pid)
                    clientsByPID[pid] = client
                }

                byLocalEndpoint[LocalEndpointKey(transport: record.transport, endpoint: record.local)] = client
                let portKey = LocalPortKey(transport: record.transport, port: record.local.port)
                localPortPIDs[portKey, default: []].insert(pid)
                localPortClients[portKey] = client
                if let remote = record.remote, remote.port > 0 {
                    bySocket[SocketKey(transport: record.transport, local: record.local, remote: remote)] = client
                }
            }
        }

        // Port fallback is only safe when exactly one process owns the port;
        // SO_REUSEPORT listeners otherwise produce arbitrary attribution.
        var byLocalPort: [LocalPortKey: PacketClient] = [:]
        for (key, pids) in localPortPIDs where pids.count == 1 {
            if let client = localPortClients[key] {
                byLocalPort[key] = client
            }
        }

        return Snapshot(
            builtAt: Date(),
            bySocket: bySocket,
            byLocalEndpoint: byLocalEndpoint,
            byLocalPort: byLocalPort
        )
    }

    private func loadSocketRecords() -> [UInt64: SocketRecord] {
        var records: [UInt64: SocketRecord] = [:]
        let files: [(String, SocketTransport)] = [
            ("tcp", .tcp),
            ("tcp6", .tcp),
            ("udp", .udp),
            ("udp6", .udp),
        ]

        for (file, transport) in files {
            guard let contents = try? String(
                contentsOfFile: "\(procRoot)/net/\(file)",
                encoding: .utf8
            ) else {
                continue
            }

            for line in contents.split(separator: "\n").dropFirst() {
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard fields.count > 9,
                      let local = SocketEndpoint(String(fields[1])),
                      let inode = UInt64(fields[9]),
                      inode > 0 else {
                    continue
                }

                records[inode] = SocketRecord(
                    transport: transport,
                    local: local,
                    remote: SocketEndpoint(String(fields[2]))
                )
            }
        }

        return records
    }

    private func processIdentifiers() -> [pid_t] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: procRoot) else {
            return []
        }
        return entries.compactMap { entry in
            guard let pid = pid_t(entry), pid > 0 else {
                return nil
            }
            return pid
        }
    }

    private func makeClient(pid: pid_t) -> PacketClient {
        let comm = (try? String(contentsOfFile: "\(procRoot)/\(pid)/comm", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let executablePath = (try? FileManager.default.destinationOfSymbolicLink(
            atPath: "\(procRoot)/\(pid)/exe"
        ))?.replacingOccurrences(of: " (deleted)", with: "")

        let executableName = executablePath.flatMap { path -> String? in
            let name = URL(fileURLWithPath: path).lastPathComponent
            return name.isEmpty ? nil : name
        }
        let name = firstNonEmpty([comm, executableName]) ?? "PID \(pid)"
        let displayName = firstNonEmpty([executableName, comm]) ?? name

        return PacketClient(
            pid: pid,
            name: String(name.prefix(128)),
            displayName: String(displayName.prefix(128)),
            executablePath: executablePath.map { String($0.prefix(1_024)) }
        )
    }

    private func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values {
            if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

private extension PacketClientResolver.SocketEndpoint {
    init?(_ endpoint: PacketEndpoint) {
        guard let address = endpoint.address, let port = endpoint.port else {
            return nil
        }
        self.init(address: PacketClientResolver.normalizedAddress(address), port: port)
    }

    init?(_ field: String) {
        let parts = field.split(separator: ":")
        guard parts.count == 2,
              let port = UInt16(parts[1], radix: 16),
              let address = PacketClientResolver.addressFromProcHex(String(parts[0])) else {
            return nil
        }
        self.init(address: PacketClientResolver.normalizedAddress(address), port: port)
    }
}

private extension PacketClientResolver {
    // /proc/net stores IPv4 as one little-endian word and IPv6 as four.
    static func addressFromProcHex(_ hex: String) -> String? {
        if hex.count == 8, let value = UInt32(hex, radix: 16) {
            return inetNtop(AF_INET, [
                UInt8(value & 0xff),
                UInt8((value >> 8) & 0xff),
                UInt8((value >> 16) & 0xff),
                UInt8((value >> 24) & 0xff),
            ])
        }

        if hex.count == 32 {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(16)
            var index = hex.startIndex
            for _ in 0..<4 {
                let end = hex.index(index, offsetBy: 8)
                guard let value = UInt32(String(hex[index..<end]), radix: 16) else {
                    return nil
                }
                bytes.append(UInt8(value & 0xff))
                bytes.append(UInt8((value >> 8) & 0xff))
                bytes.append(UInt8((value >> 16) & 0xff))
                bytes.append(UInt8((value >> 24) & 0xff))
                index = end
            }
            return inetNtop(AF_INET6, bytes)
        }

        return nil
    }

    static func normalizedAddress(_ value: String) -> String {
        let address = value.trimmingCharacters(in: .whitespacesAndNewlines)

        var ipv4 = in_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(buffer.count)) != nil {
                return String(cString: buffer).lowercased()
            }
        }

        var ipv6 = in6_addr()
        if address.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if inet_ntop(AF_INET6, &ipv6, &buffer, socklen_t(buffer.count)) != nil {
                let canonical = String(cString: buffer).lowercased()
                // IPv4-mapped IPv6 and IPv4 packets must share a key.
                if canonical.hasPrefix("::ffff:"), canonical.contains(".") {
                    return String(canonical.dropFirst("::ffff:".count))
                }
                return canonical
            }
        }

        return address.lowercased()
    }

    static func inetNtop(_ family: Int32, _ bytes: [UInt8]) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let converted = bytes.withUnsafeBytes { rawBuffer in
            inet_ntop(family, rawBuffer.baseAddress, &buffer, socklen_t(buffer.count))
        }
        guard converted != nil else {
            return nil
        }
        return String(cString: buffer).lowercased()
    }
}

private extension PacketClientResolver.SocketTransport {
    init?(packet: PacketSummary) {
        let layerNames = Set(packet.layers.map { $0.name.lowercased() })
        if layerNames.contains("tcp") {
            self = .tcp
            return
        }
        if layerNames.contains("udp") {
            self = .udp
            return
        }

        switch packet.transportHint {
        case .tcp, .http1, .tls, .websocket:
            self = .tcp
        case .udp, .dns:
            self = .udp
        default:
            return nil
        }
    }
}
