//
//  CaptureTrafficMeterTests.swift
//  PcapPlusPlusCoreTests
//
//  Round-trip gate for the status-strip metrics port: directional
//  classification (upstream endpointTrafficDirection), the trailing-window
//  rate math with its minimum-elapsed floor, and the synthesized `any`
//  pseudo-interface (upstream "All Interfaces").
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

@Suite struct CaptureTrafficMeterTests {

    // MARK: - Helpers

    private func makePacket(
        id: UInt64,
        sourceIP: String,
        destinationIP: String,
        originalLength: Int = 100,
        interfaceID: String? = "wlp3s0",
        direction: PacketDirection? = nil
    ) -> PacketSummary {
        PacketSummary(
            id: id,
            packetNumber: id,
            timestamp: Date(timeIntervalSince1970: 1_000),
            source: .live,
            interfaceID: interfaceID,
            transportHint: .tcp,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: sourceIP, port: 44_000),
                destination: PacketEndpoint(address: destinationIP, port: 443)
            ),
            originalLength: originalLength,
            capturedLength: originalLength,
            direction: direction,
            infoSummary: "test",
            layers: [PacketLayer(name: "tcp")],
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false)
        )
    }

    private let localAddress = "192.168.1.10"

    // MARK: - Classification

    @Test func classificationMirrorsUpstreamEndpointRules() {
        let local: Set<String> = [localAddress]

        let outbound = makePacket(id: 1, sourceIP: localAddress, destinationIP: "8.8.8.8")
        #expect(CaptureTrafficClassifier.trafficDirection(outbound, localAddresses: local) == .outbound)

        let inbound = makePacket(id: 2, sourceIP: "8.8.8.8", destinationIP: localAddress)
        #expect(CaptureTrafficClassifier.trafficDirection(inbound, localAddresses: local) == .inbound)

        // Local-to-local stays uncounted.
        let localOnly = makePacket(id: 3, sourceIP: localAddress, destinationIP: localAddress)
        #expect(CaptureTrafficClassifier.trafficDirection(localOnly, localAddresses: local) == .local)

        // Neither endpoint local: fall back to the packet's own direction.
        let fallback = makePacket(id: 4, sourceIP: "10.0.0.1", destinationIP: "10.0.0.2", direction: .outbound)
        #expect(CaptureTrafficClassifier.trafficDirection(fallback, localAddresses: local) == .outbound)

        // No fallback available: upstream's nil becomes unknown (uncounted).
        let unknown = makePacket(id: 5, sourceIP: "10.0.0.1", destinationIP: "10.0.0.2")
        #expect(CaptureTrafficClassifier.trafficDirection(unknown, localAddresses: local) == .unknown)

        // Empty monitor set: packet metadata alone decides.
        let metadataOnly = makePacket(id: 6, sourceIP: "10.0.0.1", destinationIP: "10.0.0.2", direction: .inbound)
        #expect(CaptureTrafficClassifier.trafficDirection(metadataOnly, localAddresses: []) == .inbound)
    }

    @Test func addressNormalizationStripsBracketsAndZones() {
        #expect(CaptureTrafficClassifier.normalizedAddress("[fe80::12:44]%wlp3s0") == "fe80::12:44")
        #expect(CaptureTrafficClassifier.normalizedAddress("[2001:DB8::1]") == "2001:db8::1")
        #expect(CaptureTrafficClassifier.normalizedAddress(" 192.168.1.10 ") == "192.168.1.10")
        #expect(CaptureTrafficClassifier.normalizedAddress("") == nil)
        #expect(CaptureTrafficClassifier.normalizedAddress(nil) == nil)
    }

    // MARK: - Rates

    @Test func meterIntegratesTheTrailingWindowWithFloor() {
        let base = Date(timeIntervalSince1970: 1_000)
        var now = base
        var meter = CaptureTrafficMeter(clock: { now })

        // Batch 1 at t0: 1000 bytes out, 500 bytes in.
        meter.record(
            [
                makePacket(id: 1, sourceIP: localAddress, destinationIP: "8.8.8.8", originalLength: 1_000),
                makePacket(id: 2, sourceIP: "8.8.8.8", destinationIP: localAddress, originalLength: 500),
            ],
            interfaceID: "wlp3s0",
            localAddresses: [localAddress]
        )

        // Fresh burst (age under the floor): publish 0 like upstream's
        // first baseline sample.
        let flush = meter.rates(now: base.addingTimeInterval(0.2))
        #expect(flush.upload == 0 && flush.download == 0)

        // Past the floor: ceil over the whole span.
        let rates = meter.rates(now: base.addingTimeInterval(2.0))
        #expect(rates.upload == 500)   // ceil(1000/2)
        #expect(rates.download == 250) // ceil(500/2)

        // Batch 2 at +3.5 s: another 300 download bytes; both samples
        // integrate together.
        now = base.addingTimeInterval(3.5)
        meter.record(
            [makePacket(id: 3, sourceIP: "8.8.8.8", destinationIP: localAddress, originalLength: 300)],
            interfaceID: "wlp3s0",
            localAddresses: [localAddress]
        )
        now = base.addingTimeInterval(4.0)
        let combined = meter.rates(now: now)
        #expect(combined.upload == 250)     // ceil(1000/4)
        #expect(combined.download == 200)   // ceil((500 + 300)/4)
    }

    @Test func meterAgesOutIdleSamples() {
        let base = Date(timeIntervalSince1970: 1_000)
        var meter = CaptureTrafficMeter(clock: { base })

        let outbound = makePacket(id: 1, sourceIP: localAddress, destinationIP: "8.8.8.8", originalLength: 1_000)
        meter.record([outbound], interfaceID: "wlp3s0", localAddresses: [localAddress])

        // Nothing appended since: the window empties and the rate is 0 —
        // a paused capture ages out without bookkeeping.
        let idle = meter.rates(now: base.addingTimeInterval(4.5))
        #expect(idle.upload == 0 && idle.download == 0)
    }

    @Test func meterSkipsForeignAndBytelessPackets() {
        let base = Date(timeIntervalSince1970: 1_000)
        var meter = CaptureTrafficMeter(clock: { base })

        let foreign = makePacket(id: 1, sourceIP: localAddress, destinationIP: "8.8.8.8", interfaceID: "o2")
        let byteless = makePacket(id: 2, sourceIP: localAddress, destinationIP: "8.8.8.8", originalLength: 0)
        let mixed = makePacket(id: 3, sourceIP: "8.8.8.8", destinationIP: localAddress, originalLength: 200)
        meter.record([foreign, byteless, mixed], interfaceID: "wlp3s0", localAddresses: [localAddress])

        let rates = meter.rates(now: base.addingTimeInterval(1.0))
        #expect(rates.upload == 0)
        #expect(rates.download == 200)
    }

    // MARK: - All Interfaces

    @Test func interfaceDiscoverySynthesizesAllInterfacesPseudoDevice() async throws {
        let core = NativeTCPViewerCore()
        let interfaces = try await core.listInterfaces()
        let allInterfaces = interfaces.first(where: { $0.id == "any" })
        #expect(allInterfaces != nil)
        #expect(allInterfaces?.isLoopback == false)
        #expect(allInterfaces?.availability == .available)
        #expect(allInterfaces?.capabilities.canCapture == true)
        // The naming pipeline renders the upstream row label.
        #expect(allInterfaces?.displayName == "All Interfaces (any)")
    }
}
