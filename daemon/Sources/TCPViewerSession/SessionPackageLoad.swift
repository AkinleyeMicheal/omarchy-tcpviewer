//
//  SessionPackageLoad.swift
//  TCPViewerSession
//
//  Ported from upstream TCPViewSessionImportService: validates the ZIP
//  package before extraction, decodes the sidecars, sanitizes the records
//  and rehydrates packet summaries. Errors surface as
//  TCPViewerCoreError(.offlineFileOpenFailed) like upstream's invalidPackage.
//

import Foundation
import PcapPlusPlusCore

public struct SessionImportReport: Codable, Equatable {
    public let importedFlowCount: Int
    public let failedFlowCount: Int

    public init(importedFlowCount: Int, failedFlowCount: Int) {
        self.importedFlowCount = importedFlowCount
        self.failedFlowCount = failedFlowCount
    }
}

public struct SessionPackageContents {
    public let manifest: TCPViewSessionManifest
    /// Path of the extracted capture.pcapng; stays valid until cleanup.
    public let captureFileURL: URL
    public let extractionDirectoryURL: URL
    public let sourceFilePath: String
    public let sourceFileName: String
    public let packetRecords: [TCPViewSessionPacketRecord]
    public let clientStore: TCPViewSessionClientStore
    public let annotations: TCPViewSessionAnnotations
    public let state: TCPViewSessionState
    public let packets: [PacketSummary]
    public let importReport: SessionImportReport
}

public enum SessionPackage {
    // MARK: - Load

    public static func loadPackage(at url: URL) throws -> SessionPackageContents {
        let archiveData: Data
        do {
            archiveData = try Data(contentsOf: url)
        } catch {
            throw invalidPackage("The TCPViewer session file could not be read.")
        }

        let entries: [ZIPEntry]
        do {
            entries = try ZIPArchiveReader.readDirectory(archiveData)
        } catch {
            throw invalidPackage((error as? ZIPError)?.description
                ?? "The TCPViewer session file is not a readable ZIP archive.")
        }

        // Extract to a private staging directory; sidecars are read from it,
        // and capture.pcapng stays for the inner offline document.
        let extractionRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TCPViewSessionImport-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
            let packageDirectoryURL = extractionRoot
                .appendingPathComponent(TCPViewSessionFormat.packageDirectoryName, isDirectory: true)
            let files = try extractEntries(entries, from: archiveData, to: packageDirectoryURL)

            let manifest = try TCPViewSessionCodec.decodeJSON(
                TCPViewSessionManifest.self,
                from: try fileData(files, TCPViewSessionFormat.manifestPath)
            )
            try validateManifest(manifest)

            let decodedPacketRecords = try TCPViewSessionCodec.decodePacketRecords(
                from: try fileData(files, TCPViewSessionFormat.packetsPath)
            )
            let clients = try TCPViewSessionCodec.decodeJSON(
                TCPViewSessionClientStore.self,
                from: try fileData(files, TCPViewSessionFormat.clientsPath)
            )
            let annotations = try TCPViewSessionCodec.decodeJSON(
                TCPViewSessionAnnotations.self,
                from: try fileData(files, TCPViewSessionFormat.annotationsPath)
            )
            let state = try TCPViewSessionCodec.decodeJSON(
                TCPViewSessionState.self,
                from: try fileData(files, TCPViewSessionFormat.statePath)
            )

            let sidecars = try sanitizeSidecars(
                decodedPacketRecords: decodedPacketRecords,
                clients: clients,
                annotations: annotations,
                state: state,
                packetCount: manifest.packetCount
            )
            let packets = TCPViewSessionClientStoreBuilder.rehydratePackets(
                records: sidecars.packetRecords,
                clients: sidecars.clientStore
            ).map { packet -> PacketSummary in
                guard let annotation = sidecars.annotations.annotations
                    .first(where: { $0.packetID == packet.id }) else {
                    return packet
                }
                let styledPacket = annotation.textStyle.map(packet.applying(textStyle:)) ?? packet
                return annotation.customComment.map(styledPacket.applying(customComment:)) ?? styledPacket
            }

            return SessionPackageContents(
                manifest: manifest,
                captureFileURL: packageDirectoryURL.appendingPathComponent(TCPViewSessionFormat.capturePath),
                extractionDirectoryURL: extractionRoot,
                sourceFilePath: url.path,
                sourceFileName: url.lastPathComponent,
                packetRecords: sidecars.packetRecords,
                clientStore: sidecars.clientStore,
                annotations: sidecars.annotations,
                state: sidecars.state,
                packets: packets,
                importReport: sidecars.importReport
            )
        } catch {
            cleanup(extractionRoot)
            throw error
        }
    }

    // MARK: - Archive validation (upstream validateArchive parity)

    private static func extractEntries(
        _ entries: [ZIPEntry],
        from archiveData: Data,
        to packageDirectoryURL: URL
    ) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let rootPrefix = "\(TCPViewSessionFormat.packageDirectoryName)/"

        for entry in entries {
            guard !entry.isSymlink else {
                throw invalidPackage("The TCPViewer session file contains an unsupported symbolic link.")
            }
            let path = entry.path
            guard !path.hasPrefix("/"),
                  path == TCPViewSessionFormat.packageDirectoryName || path.hasPrefix(rootPrefix),
                  !path.split(separator: "/").contains("..") else {
                throw invalidPackage("The TCPViewer session file contains an unsafe path.")
            }

            let relativePath = String(path.dropFirst(rootPrefix.count))
            guard !relativePath.isEmpty else { continue }
            guard entry.isDirectory else {
                let payload = try ZIPArchiveReader.readFile(entry, from: archiveData)
                files[relativePath] = payload
                try FileManager.default.createDirectory(
                    at: packageDirectoryURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let fileURL = packageDirectoryURL.appendingPathComponent(relativePath)
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try payload.write(to: fileURL, options: .atomic)
                continue
            }
            // Directory entries only contribute their on-disk shape.
            try FileManager.default.createDirectory(
                at: packageDirectoryURL.appendingPathComponent(relativePath),
                withIntermediateDirectories: true
            )
        }

        for requiredFile in TCPViewSessionFormat.requiredFiles {
            guard files.keys.contains(requiredFile) else {
                throw invalidPackage("The TCPViewer session file is missing \(requiredFile).")
            }
        }
        return files
    }

    private static func fileData(_ files: [String: Data], _ relativePath: String) throws -> Data {
        guard let data = files[relativePath] else {
            throw invalidPackage("The TCPViewer session file is missing \(relativePath).")
        }
        return data
    }

    private static func validateManifest(_ manifest: TCPViewSessionManifest) throws {
        guard manifest.magic == TCPViewSessionFormat.magic else {
            throw invalidPackage("The selected file is not a TCPViewer session.")
        }
        guard manifest.schemaVersion <= TCPViewSessionFormat.schemaVersion,
              manifest.minimumCompatibleSchemaVersion <= TCPViewSessionFormat.schemaVersion else {
            throw invalidPackage("This TCPViewer session uses an unsupported schema version.")
        }
        guard manifest.packetCount >= 0 else {
            throw invalidPackage("The session manifest contains an invalid packet count.")
        }
    }

    private static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func invalidPackage(_ message: String) -> TCPViewerCoreError {
        TCPViewerCoreError(code: .offlineFileOpenFailed, message: message)
    }

    // MARK: - Record sanitization (upstream parity)

    struct SanitizedSidecars {
        let packetRecords: [TCPViewSessionPacketRecord]
        let clientStore: TCPViewSessionClientStore
        let annotations: TCPViewSessionAnnotations
        let state: TCPViewSessionState
        let importReport: SessionImportReport
    }

    private static func sanitizeSidecars(
        decodedPacketRecords: (records: [TCPViewSessionPacketRecord], failedLineCount: Int),
        clients: TCPViewSessionClientStore,
        annotations: TCPViewSessionAnnotations,
        state: TCPViewSessionState,
        packetCount: Int
    ) throws -> SanitizedSidecars {
        let clientStore = sanitizedClientStore(clients)
        let clientIDs = Set(clientStore.clients.map(\.id))
        var packetIDs = Set<PacketSummary.ID>()
        var ordinals = Set<Int>()
        var validRecords: [TCPViewSessionPacketRecord] = []
        validRecords.reserveCapacity(decodedPacketRecords.records.count)
        var skippedDecodedRecordCount = 0

        for record in decodedPacketRecords.records {
            guard isValidPacketRecord(
                record,
                packetCount: packetCount,
                clientIDs: clientIDs,
                packetIDs: &packetIDs,
                ordinals: &ordinals
            ) else {
                skippedDecodedRecordCount += 1
                continue
            }
            validRecords.append(record)
        }

        let validPacketIDs = Set(validRecords.map(\.packetID))
        let failedFlowCount = max(
            decodedPacketRecords.failedLineCount + skippedDecodedRecordCount,
            max(0, packetCount - validRecords.count)
        )
        return SanitizedSidecars(
            packetRecords: validRecords,
            clientStore: clientStore,
            annotations: sanitizeAnnotations(annotations, validPacketIDs: validPacketIDs),
            // state.json passes through unsanitized for now: the daemon never
            // authors imported files/pins yet, and the app-state round-trip
            // (with field-wise sanitization) is a later phase.
            state: state,
            importReport: SessionImportReport(
                importedFlowCount: validRecords.count,
                failedFlowCount: failedFlowCount
            )
        )
    }

    private static func isValidPacketRecord(
        _ record: TCPViewSessionPacketRecord,
        packetCount: Int,
        clientIDs: Set<String>,
        packetIDs: inout Set<PacketSummary.ID>,
        ordinals: inout Set<Int>
    ) -> Bool {
        guard record.packetID == record.packet.id else { return false }
        guard record.captureOrdinal >= 0, record.captureOrdinal < packetCount else { return false }
        guard !packetIDs.contains(record.packetID) else { return false }
        guard !ordinals.contains(record.captureOrdinal) else { return false }
        if let clientID = record.clientID, !clientIDs.contains(clientID) {
            return false
        }
        packetIDs.insert(record.packetID)
        ordinals.insert(record.captureOrdinal)
        return true
    }

    private static func sanitizedClientStore(_ clients: TCPViewSessionClientStore) -> TCPViewSessionClientStore {
        var seenClientIDs = Set<String>()
        var sanitizedClients: [TCPViewSessionClientRecord] = []
        sanitizedClients.reserveCapacity(clients.clients.count)
        for client in clients.clients {
            guard !client.id.isEmpty, seenClientIDs.insert(client.id).inserted else {
                continue
            }
            sanitizedClients.append(TCPViewSessionClientRecord(
                id: client.id,
                client: client.client,
                iconID: client.iconID.flatMap { isValidIconID($0) ? $0 : nil }
            ))
        }
        return TCPViewSessionClientStore(clients: sanitizedClients)
    }

    private static func isValidIconID(_ iconID: String) -> Bool {
        !iconID.isEmpty &&
            iconID.utf8.allSatisfy { byte in
                (48...57).contains(Int(byte)) ||
                    (65...90).contains(Int(byte)) ||
                    (97...122).contains(Int(byte)) ||
                    byte == 45 ||
                    byte == 95
            }
    }

    private static func sanitizeAnnotations(
        _ annotations: TCPViewSessionAnnotations,
        validPacketIDs: Set<PacketSummary.ID>
    ) -> TCPViewSessionAnnotations {
        var seenPacketIDs = Set<PacketSummary.ID>()
        let sanitized = annotations.annotations.compactMap { annotation -> TCPViewSessionPacketAnnotation? in
            guard validPacketIDs.contains(annotation.packetID),
                  seenPacketIDs.insert(annotation.packetID).inserted else {
                return nil
            }
            let customComment = annotation.customComment
                .map(PacketComment.sanitized)
                .flatMap { $0.isEmpty ? nil : $0 }
            return TCPViewSessionPacketAnnotation(
                packetID: annotation.packetID,
                packetComment: annotation.packetComment,
                customComment: customComment,
                colorHex: annotation.colorHex,
                textStyle: annotation.textStyle
            )
        }
        return TCPViewSessionAnnotations(annotations: sanitized)
    }
}
