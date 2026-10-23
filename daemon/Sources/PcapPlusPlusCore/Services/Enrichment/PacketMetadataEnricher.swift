//
//  PacketMetadataEnricher.swift
//  tcpviewerd
//
//  Applies upstream PacketMetadataEnrichmentService semantics to a source's
//  packet stream: live client attribution plus DNS-derived domain names.
//

import Foundation

public final class PacketMetadataEnricher {
    private let clientResolver: PacketClientResolver?
    private var dnsResolutionCache = DNSResolutionCache()

    public init(resolveClients: Bool) {
        clientResolver = resolveClients ? PacketClientResolver() : nil
    }

    /// Prime the /proc snapshot before the capture starts so the first packets
    /// can already be attributed.
    public func prime() {
        clientResolver?.prime()
    }

    public func enrich(_ packets: [PacketSummary]) -> [PacketSummary] {
        packets.map { packet in
            dnsResolutionCache.observe(packet.dnsResolutions ?? [], at: packet.timestamp)

            let resolution = clientResolver?.resolution(for: packet)
            let direction = resolution?.direction ?? packet.direction
            let dnsDomainName = resolvedDNSDomain(for: packet, direction: direction)

            return packet.applying(
                client: resolution?.client,
                direction: direction,
                dnsDomainName: dnsDomainName
            )
        }
    }

    private func resolvedDNSDomain(for packet: PacketSummary, direction: PacketDirection?) -> String? {
        // The DNS packet itself carries the observation, not a destination domain.
        guard packet.transportHint != .dns else {
            return nil
        }

        switch direction {
        case .outbound:
            return domain(for: packet.endpoints.destination, at: packet.timestamp)
        case .inbound:
            return domain(for: packet.endpoints.source, at: packet.timestamp)
        case .local, .unknown, nil:
            let sourceDomain = domain(for: packet.endpoints.source, at: packet.timestamp)
            let destinationDomain = domain(for: packet.endpoints.destination, at: packet.timestamp)
            if let sourceDomain, destinationDomain == nil {
                return sourceDomain
            }
            if let destinationDomain, sourceDomain == nil {
                return destinationDomain
            }
            if sourceDomain == destinationDomain {
                return sourceDomain
            }
            return nil
        }
    }

    private func domain(for endpoint: PacketEndpoint, at timestamp: Date) -> String? {
        guard let address = endpoint.address else {
            return nil
        }
        return dnsResolutionCache.domain(forIPAddress: address, at: timestamp)
    }
}

private extension PacketSummary {
    // Copy with enrichment fields; all other identity and dissection fields
    // stay untouched so indexes remain stable.
    func applying(
        client: PacketClient?,
        direction: PacketDirection?,
        dnsDomainName: String?
    ) -> PacketSummary {
        PacketSummary(
            id: id,
            packetNumber: packetNumber,
            timestamp: timestamp,
            source: source,
            interfaceID: interfaceID,
            transportHint: transportHint,
            protocolSummary: protocolSummary,
            endpoints: endpoints,
            originalLength: originalLength,
            capturedLength: capturedLength,
            streamID: streamID,
            followStreamID: followStreamID,
            direction: direction ?? self.direction,
            tcpFlags: tcpFlags,
            tcpPayloadLength: tcpPayloadLength,
            infoSummary: infoSummary,
            layers: layers,
            decodeStatus: decodeStatus,
            captureMetadata: captureMetadata,
            sniDomainName: sniDomainName,
            dnsDomainName: dnsDomainName ?? self.dnsDomainName,
            dnsResolutions: dnsResolutions,
            client: client ?? self.client,
            textStyle: textStyle,
            customComment: customComment
        )
    }
}
