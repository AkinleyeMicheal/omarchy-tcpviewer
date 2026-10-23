//
//  DNSResolutionCache.swift
//  tcpviewerd
//
//  Bounded DNS observation cache ported from upstream. A packet carries the
//  observations seen while dissecting it; later packets to the same address
//  inherit the newest unexpired domain.
//

import Foundation
import Glibc

public struct DNSResolutionCache {
    private struct Entry {
        let domainName: String
        let observedAt: Date
        let expiresAt: Date
    }

    private let maximumIPAddressCount: Int
    private let maximumDomainsPerIPAddress: Int
    private let maximumRetention: TimeInterval
    private var entriesByIPAddress: [String: [Entry]] = [:]
    private var insertionOrder: [String] = []
    private var evictionIndex = 0

    public init(
        maximumIPAddressCount: Int = 50_000,
        maximumDomainsPerIPAddress: Int = 4,
        maximumRetention: TimeInterval = 86_400
    ) {
        self.maximumIPAddressCount = max(maximumIPAddressCount, 1)
        self.maximumDomainsPerIPAddress = max(maximumDomainsPerIPAddress, 1)
        self.maximumRetention = max(maximumRetention, 0)
    }

    public mutating func observe(_ observations: [DNSResolutionObservation], at timestamp: Date) {
        for observation in observations {
            guard observation.timeToLive > 0,
                  maximumRetention > 0,
                  let ipAddress = Self.normalizedIPAddress(observation.ipAddress),
                  let domainName = Self.normalizedDomain(observation.domainName) else {
                continue
            }

            let lifetime = min(TimeInterval(observation.timeToLive), maximumRetention)
            let entry = Entry(
                domainName: domainName,
                observedAt: timestamp,
                expiresAt: timestamp.addingTimeInterval(lifetime)
            )
            let isNewAddress = entriesByIPAddress[ipAddress] == nil
            var entries = entriesByIPAddress[ipAddress] ?? []
            entries.removeAll { $0.expiresAt <= timestamp || $0.domainName == domainName }
            entries.append(entry)
            if entries.count > maximumDomainsPerIPAddress {
                entries.removeFirst(entries.count - maximumDomainsPerIPAddress)
            }

            if isNewAddress {
                insertionOrder.append(ipAddress)
            }
            entriesByIPAddress[ipAddress] = entries
        }

        evictIfNeeded()
    }

    // Newest observation valid at lookup time; expired entries are dropped.
    public mutating func domain(forIPAddress address: String, at timestamp: Date) -> String? {
        guard let ipAddress = Self.normalizedIPAddress(address),
              var entries = entriesByIPAddress[ipAddress] else {
            return nil
        }

        entries.removeAll { $0.expiresAt <= timestamp }
        guard !entries.isEmpty else {
            // Keep the bounded key slot so reinsertion cannot duplicate FIFO entries.
            entriesByIPAddress[ipAddress] = []
            return nil
        }
        entriesByIPAddress[ipAddress] = entries
        var newest: Entry?
        for entry in entries where entry.observedAt <= timestamp {
            // Later observations win timestamp ties; they are the most recent
            // records in the same DNS packet.
            if newest == nil || entry.observedAt >= newest!.observedAt {
                newest = entry
            }
        }
        return newest?.domainName
    }

    public mutating func reset() {
        entriesByIPAddress.removeAll(keepingCapacity: false)
        insertionOrder.removeAll(keepingCapacity: false)
        evictionIndex = 0
    }

    private mutating func evictIfNeeded() {
        while entriesByIPAddress.count > maximumIPAddressCount, evictionIndex < insertionOrder.count {
            let ipAddress = insertionOrder[evictionIndex]
            evictionIndex += 1
            entriesByIPAddress.removeValue(forKey: ipAddress)
        }

        if evictionIndex > 4_096, evictionIndex * 2 > insertionOrder.count {
            insertionOrder.removeFirst(evictionIndex)
            evictionIndex = 0
        }
    }

    private static func normalizedDomain(_ value: String) -> String? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !normalized.isEmpty, normalized.utf8.count <= 253 else {
            return nil
        }
        return normalized
    }

    private static func normalizedIPAddress(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)

        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(buffer.count)) != nil else {
                return nil
            }
            return String(cString: buffer)
        }

        var ipv6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &ipv6, &buffer, socklen_t(buffer.count)) != nil else {
                return nil
            }
            let canonical = String(cString: buffer)
            if canonical.hasPrefix("::ffff:"), canonical.contains(".") {
                return String(canonical.dropFirst("::ffff:".count))
            }
            return canonical
        }

        return nil
    }
}
