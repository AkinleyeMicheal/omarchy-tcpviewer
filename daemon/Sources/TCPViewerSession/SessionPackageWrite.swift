//
//  SessionPackageWrite.swift
//  TCPViewerSession
//
//  Ported from upstream TCPViewSessionExportService: builds the ZIP package
//  (manifest + pcapng + JSON sidecars) and writes it atomically. Sidecar JSON
//  is compact with sorted keys and ISO-8601 dates so files stay
//  interchangeable with the macOS app.
//

import Foundation
import PcapPlusPlusCore

extension PacketHighlightColor {
    /// Upstream's sessionColorHex — stable hex strings in the sidecars.
    var sessionColorHex: String {
        switch self {
        case .red: "#FF453A"
        case .orange: "#FF9F0A"
        case .yellow: "#FFD60A"
        case .green: "#30D158"
        case .teal: "#40C8E0"
        case .blue: "#0A84FF"
        case .indigo: "#5E5CE6"
        case .purple: "#BF5AF2"
        case .pink: "#FF375F"
        case .brown: "#AC8E68"
        case .gray: "#8E8E93"
        }
    }
}

extension SessionPackage {
    /// Writes a `.tcpviewsession` bundle. `captureFileData` is the staged
    /// pcapng payload (document.save(to:format:) output). The ZIP writer
    /// stages a temporary file and replaces the destination atomically.
    public static func writePackage(
        packets: [PacketSummary],
        captureFileData: Data,
        state: TCPViewSessionState,
        to destinationURL: URL,
        now: Date = Date()
    ) throws {
        guard !captureFileData.isEmpty else {
            throw TCPViewerCoreError(
                code: .offlineFileSaveFailed,
                message: "The temporary pcapng file could not be found."
            )
        }

        let storeResult = TCPViewSessionClientStoreBuilder.buildClientStore(packets: packets)
        let manifest = TCPViewSessionManifest(
            createdAt: now,
            applicationName: "TCPViewer",
            applicationVersion: "1.0",
            applicationBuild: "1",
            packetCount: packets.count
        )

        var recordsJSON = Data()
        recordsJSON.reserveCapacity(storeResult.records.count * 512)
        for record in storeResult.records {
            recordsJSON.append(try TCPViewSessionCodec.encodeJSON(record))
            recordsJSON.append(0x0A)
        }

        let entries: [ZIPArchiveWriter.Entry] = [
            ZIPArchiveWriter.Entry(path: "TCPViewerSession/"),
            ZIPArchiveWriter.Entry(path: "TCPViewerSession/\(TCPViewSessionFormat.capturePath)", payload: captureFileData),
            ZIPArchiveWriter.Entry(path: "TCPViewerSession/\(TCPViewSessionFormat.packetsPath)", payload: recordsJSON),
            ZIPArchiveWriter.Entry(path: "TCPViewerSession/\(TCPViewSessionFormat.clientsPath)",
                                   payload: try TCPViewSessionCodec.encodeJSON(storeResult.clients)),
            ZIPArchiveWriter.Entry(path: "TCPViewerSession/\(TCPViewSessionFormat.annotationsPath)",
                                   payload: try TCPViewSessionCodec.encodeJSON(annotations(for: packets))),
            ZIPArchiveWriter.Entry(path: "TCPViewerSession/\(TCPViewSessionFormat.statePath)",
                                   payload: try TCPViewSessionCodec.encodeJSON(state)),
            ZIPArchiveWriter.Entry(path: "TCPViewerSession/\(TCPViewSessionFormat.manifestPath)",
                                   payload: try TCPViewSessionCodec.encodeJSON(manifest)),
            ZIPArchiveWriter.Entry(path: "TCPViewerSession/\(TCPViewSessionFormat.iconsDirectoryPath)/"),
        ]
        try ZIPArchiveWriter.write(entries, to: destinationURL)
    }

    /// Upstream annotations(for:): one entry per commented/restyled packet.
    private static func annotations(for packets: [PacketSummary]) -> TCPViewSessionAnnotations {
        TCPViewSessionAnnotations(
            annotations: packets.compactMap { packet in
                let textStyle = packet.resolvedTextStyle
                guard packet.captureMetadata.packetComment != nil ||
                        packet.customComment != nil ||
                        !textStyle.isPlain else {
                    return nil
                }
                return TCPViewSessionPacketAnnotation(
                    packetID: packet.id,
                    packetComment: packet.captureMetadata.packetComment,
                    customComment: packet.customComment,
                    colorHex: textStyle.highlightColor?.sessionColorHex,
                    textStyle: textStyle.isPlain ? nil : textStyle
                )
            }
        )
    }
}
