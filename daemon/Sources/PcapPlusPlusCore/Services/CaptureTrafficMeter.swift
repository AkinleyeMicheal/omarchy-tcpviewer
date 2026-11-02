//
//  CaptureTrafficMeter.swift
//  PcapPlusPlusCore
//
//  Port of upstream TCPViewerStatusMetricsService's traffic half, moved
//  daemon-side: in upstream the app process owns both the packet workspace
//  and the meter, and the strip shows "• <memory> ↑ <up> ↓ <down>". The port's
//  daemon owns the workspace, so it accumulates the directional bytes; the
//  process footprint reading stays in tcpviewerd (/proc/self/statm) and
//  capture.status carries both, with the app's status strip formatting them.
//
//  Classification mirrors upstream endpointTrafficDirection: local-address
//  membership decides; packets that resolve nowhere fall back to their own
//  direction metadata when present, and local-to-local/unresolvable bytes
//  stay uncounted like upstream.
//

import Foundation

public enum CaptureTrafficClassifier {
    /// Snapshot-local addresses for one interface, normalized.
    public static func localAddresses(_ interface: CaptureInterfaceSummary) -> Set<String> {
        Set(interface.addresses.map { normalizedAddress($0.value) }.compactMap { $0 })
    }

    /// The packet counts toward the meter only when it belongs to the
    /// monitored capture interface (upstream packetMatchesMonitoredInterface).
    public static func packetMatchesInterface(_ packet: PacketSummary, interfaceID: String) -> Bool {
        packet.interfaceID == interfaceID || packet.captureMetadata.interfaceName == interfaceID
    }

    /// Upstream trafficDirection: endpoint membership first, packet metadata
    /// as the fallback when the endpoints resolve against nothing.
    public static func trafficDirection(_ packet: PacketSummary, localAddresses: Set<String>) -> PacketDirection {
        guard !localAddresses.isEmpty else {
            return packet.direction ?? .unknown
        }

        let sourceIsLocal = normalizedAddress(packet.endpoints.source.address)
            .map(localAddresses.contains) ?? false
        let destinationIsLocal = normalizedAddress(packet.endpoints.destination.address)
            .map(localAddresses.contains) ?? false

        switch (sourceIsLocal, destinationIsLocal) {
        case (true, false):
            return .outbound
        case (false, true):
            return .inbound
        case (true, true):
            return .local
        case (false, false):
            return packet.direction ?? .unknown
        }
    }

    /// Upstream normalizedAddress: strip brackets and zone indices, lowercase.
    static func normalizedAddress(_ address: String?) -> String? {
        var value = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty {
            return nil
        }

        if value.hasPrefix("["), let closing = value.firstIndex(of: "]") {
            value = String(value[value.index(after: value.startIndex)..<closing])
        }

        if let zone = value.firstIndex(of: "%") {
            value = String(value[..<zone])
        }

        return value.isEmpty ? nil : value.lowercased()
    }
}

/// One appended batch's directional bytes. Sample rows are chronological;
/// `rates` integrates the trailing window.
public struct CaptureTrafficSample {
    let date: Date
    let uploadBytes: UInt64
    let downloadBytes: UInt64
}

public struct CaptureTrafficMeter {
    /// Upstream samples at a fixed 2 s cadence; the daemon only sees status
    /// requests, so it keeps a trailing window and integrates on demand.
    /// The window must exceed the app's 1 s poll so bursts do not fall out
    /// between polls.
    public static let window: TimeInterval = 4

    /// Floor on the integration span: upstream's fixed cadence guarantees
    /// elapsed >= timerInterval; without a floor a burst landing a millisecond
    /// before a status call would scale its rate enormously.
    public static let minimumElapsed: TimeInterval = 0.35

    /// Hard safety cap — 4 s of bursts cannot reasonably exceed this.
    public static let maxSamples = 512

    private let clock: () -> Date
    private(set) var samples: [CaptureTrafficSample] = []

    public init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    /// Record one appended (or reclassified) batch. Runs on the manager
    /// queue; callers hold the source. Byte-less batches are skipped: they
    /// would dilute the integration span without contributing bytes.
    public mutating func record(_ batch: [PacketSummary], interfaceID: String, localAddresses: Set<String>) {
        var upload: UInt64 = 0
        var download: UInt64 = 0
        for packet in batch {
            guard CaptureTrafficClassifier.packetMatchesInterface(packet, interfaceID: interfaceID) else {
                continue
            }
            let bytes = UInt64(max(packet.originalLength, 0))
            guard bytes > 0 else { continue }
            switch CaptureTrafficClassifier.trafficDirection(packet, localAddresses: localAddresses) {
            case .outbound:
                upload += bytes
            case .inbound:
                download += bytes
            case .local, .unknown:
                break  // uncounted, like upstream
            }
        }

        guard upload > 0 || download > 0 else {
            return
        }

        let date = clock()
        samples.append(CaptureTrafficSample(date: date, uploadBytes: upload, downloadBytes: download))
        if samples.count > Self.maxSamples {
            samples.removeFirst(samples.count - Self.maxSamples)
        }
        prune(oldestAllowed: date.addingTimeInterval(-Self.window * 2))
    }

    /// Bytes per second over the trailing window. Zero while nothing was
    /// appended recently (a paused capture simply ages out).
    public mutating func rates(now: Date = Date()) -> (upload: UInt64, download: UInt64) {
        prune(oldestAllowed: now.addingTimeInterval(-Self.window))
        guard !samples.isEmpty else { return (0, 0) }

        // Upstream samples at a fixed cadence, so elapsed never under-runs
        // the timer interval. The daemon integrates on demand instead:
        // measure from the oldest sample at least `minimumElapsed` old; when
        // the whole ring is younger (a burst landing right before the poll),
        // publish 0 for this reading like upstream's first baseline sample.
        var floorIndex: Int?
        for (index, sample) in samples.enumerated() {
            if now.timeIntervalSince(sample.date) >= Self.minimumElapsed {
                floorIndex = index
                break
            }
        }

        let start = floorIndex ?? 0
        let elapsed = now.timeIntervalSince(samples[start].date)
        guard elapsed >= Self.minimumElapsed else {
            return (0, 0)
        }

        var upload: UInt64 = 0
        var download: UInt64 = 0
        for index in start..<samples.count {
            upload += samples[index].uploadBytes
            download += samples[index].downloadBytes
        }

        return (Self.bytesPerSecond(upload, elapsed: elapsed),
                Self.bytesPerSecond(download, elapsed: elapsed))
    }

    /// Upstream bytesPerSecond math: ceil(bytes / elapsed).
    private static func bytesPerSecond(_ bytes: UInt64, elapsed: TimeInterval) -> UInt64 {
        guard bytes > 0, elapsed > 0 else {
            return 0
        }
        return UInt64(ceil(Double(bytes) / elapsed))
    }

    private mutating func prune(oldestAllowed: Date) {
        guard let first = samples.first, first.date < oldestAllowed else {
            return
        }
        samples.removeAll { $0.date < oldestAllowed }
    }
}

