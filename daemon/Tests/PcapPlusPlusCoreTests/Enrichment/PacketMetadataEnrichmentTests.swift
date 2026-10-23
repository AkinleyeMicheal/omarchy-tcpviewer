//
//  PacketMetadataEnrichmentTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 23/10/26.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

struct PacketClientResolverTests {
    @Test func resolvesExactSocketDirectionAndProcessIdentity() throws {
        let proc = try FakeProc()
        defer { proc.remove() }
        try proc.writeNet("tcp", """
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 0100007F:D431 22D8B85D:01BB 01 00000000:00000000 00:00000000 00000000  1000        0 12345 1 0000000000000000 100 0 0 10 0
        """)
        try proc.addSocket(pid: 4242, descriptor: "3", inode: 12345)
        try proc.setProcess(pid: 4242, name: "curl", executablePath: "/usr/bin/curl")

        let resolver = PacketClientResolver(procRoot: proc.root.path, snapshotTTL: 60)
        resolver.prime()

        let outbound = makePacket(
            source: PacketEndpoint(address: "127.0.0.1", port: 54321),
            destination: PacketEndpoint(address: "93.184.216.34", port: 443)
        )
        let outboundResolution = try #require(resolver.resolution(for: outbound))
        #expect(outboundResolution.direction == .outbound)
        #expect(outboundResolution.client.pid == 4242)
        #expect(outboundResolution.client.name == "curl")
        #expect(outboundResolution.client.displayName == "curl")
        #expect(outboundResolution.client.executablePath == "/usr/bin/curl")

        let inbound = makePacket(
            source: PacketEndpoint(address: "93.184.216.34", port: 443),
            destination: PacketEndpoint(address: "127.0.0.1", port: 54321)
        )
        #expect(resolver.resolution(for: inbound)?.direction == .inbound)

        let mapped = makePacket(
            source: PacketEndpoint(address: "::ffff:127.0.0.1", port: 54321),
            destination: PacketEndpoint(address: "93.184.216.34", port: 443)
        )
        #expect(resolver.resolution(for: mapped)?.direction == .outbound)
    }

    @Test func fallsBackToLocalPortForWildcardAndUnknownAddresses() throws {
        let proc = try FakeProc()
        defer { proc.remove() }
        try proc.writeNet("tcp", """
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 23456 1 0000000000000000 100 0 0 10 0
        """)
        try proc.addSocket(pid: 4242, descriptor: "4", inode: 23456)
        try proc.setProcess(pid: 4242, name: "server", executablePath: "/usr/bin/server")

        let resolver = PacketClientResolver(procRoot: proc.root.path, snapshotTTL: 60)
        resolver.prime()

        let outbound = makePacket(
            source: PacketEndpoint(address: "10.0.0.5", port: 8080),
            destination: PacketEndpoint(address: "1.1.1.1", port: 80)
        )
        let outboundResolution = try #require(resolver.resolution(for: outbound))
        #expect(outboundResolution.direction == .outbound)
        #expect(outboundResolution.client.displayName == "server")

        let inbound = makePacket(
            source: PacketEndpoint(address: "1.1.1.1", port: 80),
            destination: PacketEndpoint(address: "10.0.0.5", port: 8080)
        )
        #expect(resolver.resolution(for: inbound)?.direction == .inbound)
    }

    @Test func refusesAmbiguousLocalPortFallback() throws {
        let proc = try FakeProc()
        defer { proc.remove() }
        try proc.writeNet("tcp", """
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 11111 1 0000000000000000 100 0 0 10 0
           1: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 22222 1 0000000000000000 100 0 0 10 0
        """)
        try proc.addSocket(pid: 4242, descriptor: "6", inode: 11111)
        try proc.addSocket(pid: 4343, descriptor: "6", inode: 22222)
        try proc.setProcess(pid: 4242, name: "one", executablePath: "/usr/bin/one")
        try proc.setProcess(pid: 4343, name: "two", executablePath: "/usr/bin/two")

        let resolver = PacketClientResolver(procRoot: proc.root.path, snapshotTTL: 60)
        resolver.prime()

        let packet = makePacket(
            source: PacketEndpoint(address: "10.0.0.5", port: 8080),
            destination: PacketEndpoint(address: "1.1.1.1", port: 80)
        )
        #expect(resolver.resolution(for: packet) == nil)
    }

    @Test func parsesIPv6ProcAddresses() throws {
        let proc = try FakeProc()
        defer { proc.remove() }
        try proc.writeNet("tcp6", """
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 00000000000000000000000001000000:1F90 00000000000000000000000002000000:01BB 01 00000000:00000000 00:00000000 00000000  1000        0 34567 1 0000000000000000 100 0 0 10 0
        """)
        try proc.addSocket(pid: 4242, descriptor: "5", inode: 34567)
        try proc.setProcess(pid: 4242, name: "curl", executablePath: "/usr/bin/curl")

        let resolver = PacketClientResolver(procRoot: proc.root.path, snapshotTTL: 60)
        resolver.prime()

        let packet = makePacket(
            source: PacketEndpoint(address: "0:0:0:0:0:0:0:1", port: 8080),
            destination: PacketEndpoint(address: "0:0:0:0:0:0:0:2", port: 443)
        )
        let resolution = try #require(resolver.resolution(for: packet))
        #expect(resolution.direction == .outbound)
        #expect(resolution.client.displayName == "curl")
    }

    @Test func ignoresUnknownSocketsAndMalformedProcLines() throws {
        let proc = try FakeProc()
        defer { proc.remove() }
        try proc.writeNet("tcp", """
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           not-a-socket
        """)
        try proc.setProcess(pid: 4242, name: "curl", executablePath: "/usr/bin/curl")

        let resolver = PacketClientResolver(procRoot: proc.root.path, snapshotTTL: 60)
        resolver.prime()

        let packet = makePacket(
            source: PacketEndpoint(address: "127.0.0.1", port: 9999),
            destination: PacketEndpoint(address: "93.184.216.34", port: 443)
        )
        #expect(resolver.resolution(for: packet) == nil)
    }
}

struct DNSResolutionCacheTests {
    @Test func normalizesAndExpiresObservations() {
        var cache = DNSResolutionCache()
        let start = Date(timeIntervalSince1970: 1_000)
        cache.observe([
            DNSResolutionObservation(domainName: "Example.COM.", ipAddress: "1.2.3.4", timeToLive: 60),
        ], at: start)

        #expect(cache.domain(forIPAddress: "1.2.3.4", at: start.addingTimeInterval(1)) == "example.com")
        #expect(cache.domain(forIPAddress: "1.2.3.4", at: start.addingTimeInterval(60)) == nil)
        #expect(cache.domain(forIPAddress: "not-an-ip", at: start) == nil)
    }

    @Test func newestObservationWinsAndIPv6IsCanonicalized() {
        var cache = DNSResolutionCache()
        let start = Date(timeIntervalSince1970: 1_000)
        cache.observe([
            DNSResolutionObservation(domainName: "old.example", ipAddress: "2001:0db8::1", timeToLive: 300),
        ], at: start)
        cache.observe([
            DNSResolutionObservation(domainName: "new.example", ipAddress: "2001:db8::1", timeToLive: 300),
        ], at: start.addingTimeInterval(1))

        #expect(cache.domain(forIPAddress: "2001:db8::1", at: start.addingTimeInterval(2)) == "new.example")
    }

    @Test func canonicalizesIPv4MappedAddresses() {
        var cache = DNSResolutionCache()
        let start = Date(timeIntervalSince1970: 1_000)
        cache.observe([
            DNSResolutionObservation(domainName: "mapped.example", ipAddress: "::ffff:1.2.3.4", timeToLive: 60),
        ], at: start)

        #expect(cache.domain(forIPAddress: "1.2.3.4", at: start) == "mapped.example")
    }

    @Test func ignoresZeroTTLAndInvalidDomains() {
        var cache = DNSResolutionCache()
        let start = Date(timeIntervalSince1970: 1_000)
        cache.observe([
            DNSResolutionObservation(domainName: "zero.example", ipAddress: "1.2.3.4", timeToLive: 0),
            DNSResolutionObservation(domainName: " ", ipAddress: "5.6.7.8", timeToLive: 60),
        ], at: start)

        #expect(cache.domain(forIPAddress: "1.2.3.4", at: start) == nil)
        #expect(cache.domain(forIPAddress: "5.6.7.8", at: start) == nil)
    }

    @Test func evictsOldestAddressesAndCapsDomainsPerAddress() {
        var cache = DNSResolutionCache(maximumIPAddressCount: 2, maximumDomainsPerIPAddress: 2)
        let start = Date(timeIntervalSince1970: 1_000)
        cache.observe([
            DNSResolutionObservation(domainName: "one.example", ipAddress: "1.1.1.1", timeToLive: 300),
            DNSResolutionObservation(domainName: "two.example", ipAddress: "2.2.2.2", timeToLive: 300),
            DNSResolutionObservation(domainName: "three.example", ipAddress: "3.3.3.3", timeToLive: 300),
        ], at: start)

        #expect(cache.domain(forIPAddress: "1.1.1.1", at: start) == nil)
        #expect(cache.domain(forIPAddress: "2.2.2.2", at: start) == "two.example")
        #expect(cache.domain(forIPAddress: "3.3.3.3", at: start) == "three.example")

        cache.observe([
            DNSResolutionObservation(domainName: "a.example", ipAddress: "4.4.4.4", timeToLive: 300),
            DNSResolutionObservation(domainName: "b.example", ipAddress: "4.4.4.4", timeToLive: 300),
            DNSResolutionObservation(domainName: "c.example", ipAddress: "4.4.4.4", timeToLive: 300),
        ], at: start)
        #expect(cache.domain(forIPAddress: "4.4.4.4", at: start) == "c.example")
    }
}

struct PacketMetadataEnricherTests {
    @Test func dnsObservationAppliesToFollowingPacketsOnly() {
        let enricher = PacketMetadataEnricher(resolveClients: false)
        let start = Date(timeIntervalSince1970: 1_000)
        let resolution = DNSResolutionObservation(
            domainName: "example.com",
            ipAddress: "93.184.216.34",
            timeToLive: 300
        )

        let dnsPacket = makePacket(
            id: 1,
            source: PacketEndpoint(address: "10.0.0.2", port: 5353),
            destination: PacketEndpoint(address: "10.0.0.1", port: 53),
            transport: .dns,
            timestamp: start,
            dnsResolutions: [resolution]
        )
        let enrichedDNS = enricher.enrich([dnsPacket])
        #expect(enrichedDNS.first?.dnsDomainName == nil)

        let outbound = makePacket(
            id: 2,
            source: PacketEndpoint(address: "10.0.0.2", port: 50000),
            destination: PacketEndpoint(address: "93.184.216.34", port: 443),
            direction: .outbound,
            timestamp: start.addingTimeInterval(1)
        )
        #expect(enricher.enrich([outbound]).first?.dnsDomainName == "example.com")

        let inbound = makePacket(
            id: 3,
            source: PacketEndpoint(address: "93.184.216.34", port: 443),
            destination: PacketEndpoint(address: "10.0.0.2", port: 50000),
            direction: .inbound,
            timestamp: start.addingTimeInterval(2)
        )
        #expect(enricher.enrich([inbound]).first?.dnsDomainName == "example.com")
    }

    @Test func ambiguousLocalPacketDoesNotGuess() {
        let enricher = PacketMetadataEnricher(resolveClients: false)
        let start = Date(timeIntervalSince1970: 1_000)
        _ = enricher.enrich([
            makePacket(
                id: 1,
                source: PacketEndpoint(address: "1.1.1.1", port: 1000),
                destination: PacketEndpoint(address: "2.2.2.2", port: 2000),
                transport: .dns,
                timestamp: start,
                dnsResolutions: [
                    DNSResolutionObservation(domainName: "one.example", ipAddress: "1.1.1.1", timeToLive: 300),
                    DNSResolutionObservation(domainName: "two.example", ipAddress: "2.2.2.2", timeToLive: 300),
                ]
            ),
        ])

        let ambiguous = makePacket(
            id: 2,
            source: PacketEndpoint(address: "1.1.1.1", port: 1000),
            destination: PacketEndpoint(address: "2.2.2.2", port: 2000),
            direction: .unknown,
            timestamp: start.addingTimeInterval(1)
        )
        #expect(enricher.enrich([ambiguous]).first?.dnsDomainName == nil)

        let oneSided = makePacket(
            id: 3,
            source: PacketEndpoint(address: "3.3.3.3", port: 1000),
            destination: PacketEndpoint(address: "2.2.2.2", port: 2000),
            direction: .unknown,
            timestamp: start.addingTimeInterval(2)
        )
        #expect(enricher.enrich([oneSided]).first?.dnsDomainName == "two.example")
    }
}

// MARK: - Fixtures

private func makePacket(
    id: UInt64 = 1,
    source: PacketEndpoint,
    destination: PacketEndpoint,
    transport: TransportProtocolHint = .tcp,
    direction: PacketDirection? = nil,
    timestamp: Date = Date(timeIntervalSince1970: 1_000),
    dnsResolutions: [DNSResolutionObservation]? = nil
) -> PacketSummary {
    PacketSummary(
        id: id,
        packetNumber: id,
        timestamp: timestamp,
        source: .live,
        transportHint: transport,
        endpoints: PacketEndpoints(source: source, destination: destination),
        originalLength: 100,
        capturedLength: 100,
        direction: direction,
        infoSummary: "test",
        layers: [PacketLayer(name: transport == .dns ? "dns" : "tcp")],
        decodeStatus: PacketDecodeStatus(kind: .complete),
        captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false),
        dnsResolutions: dnsResolutions
    )
}

private struct FakeProc {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tcpviewer-proc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("net"),
            withIntermediateDirectories: true
        )
    }

    func writeNet(_ name: String, _ contents: String) throws {
        try contents.write(
            to: root.appendingPathComponent("net").appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    func addSocket(pid: pid_t, descriptor: String, inode: UInt64) throws {
        let fdDirectory = root.appendingPathComponent(String(pid)).appendingPathComponent("fd")
        try FileManager.default.createDirectory(at: fdDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: fdDirectory.appendingPathComponent(descriptor).path,
            withDestinationPath: "socket:[\(inode)]"
        )
    }

    func setProcess(pid: pid_t, name: String, executablePath: String) throws {
        let directory = root.appendingPathComponent(String(pid))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "\(name)\n".write(
            to: directory.appendingPathComponent("comm"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            atPath: directory.appendingPathComponent("exe").path,
            withDestinationPath: executablePath
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
