//
//  SessionBundleDocument.swift
//  tcpviewerd
//
//  Port of upstream TCPViewSessionOfflineDocument: an offline capture
//  document backed by an imported .tcpviewsession bundle. Session packet
//  summaries come from the sidecars; the inner pcapng document serves
//  inspect/follow/export with session↔inner packet-ID remapping.
//

import Foundation
import PcapPlusPlusCore
import TCPViewerSession

final class SessionBundleDocument: OfflineCaptureDocumentProviding, @unchecked Sendable {
    private struct MutableState {
        var innerDocument: (any OfflineCaptureDocumentProviding)?
        var innerPacketIDBySessionID: [PacketSummary.ID: PacketSummary.ID] = [:]
        var sessionPacketByID: [PacketSummary.ID: PacketSummary] = [:]
        var openedPackets: [PacketSummary]
        var progress: PacketLoadProgress
        var metadata: CaptureDocumentMetadata
        var importReport: SessionImportReport
    }

    let contents: SessionPackageContents
    private let core: TCPViewerCoreProviding
    private let state: Protected<MutableState>
    private let eventState: Protected<PacketIngestEventHandler?> = Protected(nil)

    var eventHandler: PacketIngestEventHandler? {
        get { eventState.wrappedValue }
        set { eventState.wrappedValue = newValue }
    }

    init(contents: SessionPackageContents, core: TCPViewerCoreProviding) {
        self.contents = contents
        self.core = core
        self.state = Protected(MutableState(
            openedPackets: contents.packets,
            progress: PacketLoadProgress(
                phase: .idle,
                loadedPacketCount: 0,
                message: "TCPViewer session is ready to open."
            ),
            metadata: CaptureDocumentMetadata(
                format: .pcapng,
                captureApplication: contents.manifest.applicationName,
                fileComment: "TCPViewer Session"
            ),
            importReport: contents.importReport
        ))
    }

    deinit {
        try? FileManager.default.removeItem(at: contents.extractionDirectoryURL)
    }

    // MARK: - Open

    func open(completion: @escaping TCPViewerCompletion<[PacketSummary]>) {
        let loadProgress = PacketLoadProgress(
            phase: .loading,
            loadedPacketCount: 0,
            message: "Opening \(contents.sourceFileName)..."
        )
        state.write { mutable in
            mutable.progress = loadProgress
        }
        emit(.loadProgressChanged(loadProgress))

        core.openOfflineCaptureDocument(at: contents.captureFileURL) { [weak self] result in
            guard let self else {
                completion(.failure(Self.cancelledError()))
                return
            }
            switch result {
            case .success(let document):
                self.state.write { mutable in
                    mutable.innerDocument = document
                }
                document.open { [weak self] openResult in
                    guard let self else {
                        completion(.failure(Self.cancelledError()))
                        return
                    }
                    self.finishInnerOpen(openResult, completion: completion)
                }
            case .failure(let error):
                let message = Self.errorMessage(error)
                self.state.write { mutable in
                    mutable.progress = PacketLoadProgress(
                        phase: .failed,
                        loadedPacketCount: 0,
                        message: message
                    )
                }
                completion(.failure(error))
            }
        }
    }

    func reopen(completion: @escaping TCPViewerCompletion<[PacketSummary]>) {
        let inner = state.wrappedValue.innerDocument
        guard let inner else {
            open(completion: completion)
            return
        }
        inner.reopen { [weak self] result in
            guard let self else {
                completion(.failure(Self.cancelledError()))
                return
            }
            self.finishInnerOpen(result, completion: completion)
        }
    }

    func cancelLoading(completion: (() -> Void)?) {
        let inner = state.wrappedValue.innerDocument
        guard let inner else {
            completion?()
            return
        }
        inner.cancelLoading(completion: completion)
    }

    /// Shutdown barrier: quiesce the inner document's load machinery before
    /// the process tears down (epan/wmem ordering).
    func waitUnload(completion: @escaping () -> Void) {
        let inner = state.wrappedValue.innerDocument
        guard let inner else {
            completion()
            return
        }
        inner.waitUnload(completion: completion)
    }

    /// Stages the backing capture.pcapng bytes (used by session re-export).
    func stageInnerCapture(to url: URL, completion: @escaping TCPViewerVoidCompletion) {
        let inner = state.wrappedValue.innerDocument
        guard let inner else {
            completion(.failure(Self.unavailableBackingError()))
            return
        }
        inner.save(to: url, format: .pcapng, completion: completion)
    }

    // MARK: - Packet access

    func inspectPacket(id: PacketSummary.ID, completion: @escaping TCPViewerCompletion<PacketInspection>) {
        let mapping = state.wrappedValue
        guard let innerDocument = mapping.innerDocument,
              let innerID = mapping.innerPacketIDBySessionID[id] else {
            completion(.failure(Self.unavailableBackingError()))
            return
        }
        innerDocument.inspectPacket(id: innerID) { [weak self] result in
            guard let self else {
                completion(.failure(Self.cancelledError()))
                return
            }
            let sessionPacket = self.state.wrappedValue.sessionPacketByID[id]
            completion(result.map { inspection in
                PacketInspection(
                    packetID: id,
                    packetNumber: sessionPacket?.packetNumber ?? inspection.packetNumber,
                    rawBytes: inspection.rawBytes,
                    byteViews: inspection.byteViews,
                    detailNodes: inspection.detailNodes,
                    decodeStatus: inspection.decodeStatus
                )
            })
        }
    }

    // MARK: - Display filters (forwarded to the inner document)

    func validateDisplayFilter(_ expression: String, completion: @escaping (DisplayFilterValidation) -> Void) {
        forwardDisplayFilter(expression, completion: completion)
    }

    func activateDisplayFilter(
        _ expression: String,
        generation: UInt64,
        completion: @escaping (DisplayFilterValidation) -> Void
    ) {
        let inner = state.wrappedValue.innerDocument
        guard let inner else {
            return forwardDisplayFilter(expression, completion: completion)
        }
        inner.activateDisplayFilter(expression, generation: generation, completion: completion)
    }

    private func forwardDisplayFilter(
        _ expression: String,
        completion: @escaping (DisplayFilterValidation) -> Void
    ) {
        let inner = state.wrappedValue.innerDocument
        guard let inner else {
            completion(DisplayFilterValidation(
                normalizedExpression: expression,
                status: .unavailable,
                diagnostics: [DisplayFilterDiagnostic(
                    severity: .error,
                    message: "The TCPViewer session backing pcapng is not available."
                )]
            ))
            return
        }
        inner.validateDisplayFilter(expression, completion: completion)
    }

    /// Session packet IDs are translated to the inner document's IDs before
    /// evaluation, and matches are translated back (upstream parity: the
    /// workspace routes filter evaluation to the backing capture).
    func evaluateDisplayFilter(
        packetIDs: [PacketSummary.ID],
        generation: UInt64,
        completion: @escaping TCPViewerCompletion<DisplayFilterMatchBatch>
    ) {
        let mapping = state.wrappedValue
        guard let innerDocument = mapping.innerDocument else {
            completion(.failure(Self.unavailableBackingError()))
            return
        }
        let innerIDs = packetIDs.compactMap { mapping.innerPacketIDBySessionID[$0] }
        guard innerIDs.count == packetIDs.count else {
            completion(.failure(Self.unavailableBackingError()))
            return
        }
        let innerToSession = Dictionary(
            mapping.innerPacketIDBySessionID.map { ($1, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
        innerDocument.evaluateDisplayFilter(packetIDs: innerIDs, generation: generation) { result in
            completion(result.map { batch in
                DisplayFilterMatchBatch(
                    generation: batch.generation,
                    evaluatedPacketIDs: packetIDs,
                    matchingPacketIDs: batch.matchingPacketIDs.map { innerToSession[$0] ?? $0 }
                )
            })
        }
    }

    func clearDisplayFilter(completion: @escaping TCPViewerVoidCompletion) {
        let inner = state.wrappedValue.innerDocument
        guard let inner else {
            completion(.success(()))
            return
        }
        inner.clearDisplayFilter(completion: completion)
    }

    // MARK: - Stream following

    /// Inner packet IDs are translated back to stable session IDs in the
    /// returned stream (upstream tcpviewerRemapping parity).
    func followStream(
        containing packetID: PacketSummary.ID,
        streamProtocol: FollowStreamProtocol? = nil,
        limits: FollowStreamLimits,
        progress: FollowStreamProgressHandler?,
        shouldCancel: FollowStreamCancellationCheck?,
        completion: @escaping TCPViewerCompletion<FollowStream>
    ) {
        let mapping = state.wrappedValue
        guard let innerDocument = mapping.innerDocument,
              let innerID = mapping.innerPacketIDBySessionID[packetID] else {
            completion(.failure(Self.unavailableBackingError()))
            return
        }
        let packetIDMapping = mapping.innerPacketIDBySessionID
        innerDocument.followStream(
            containing: innerID,
            streamProtocol: streamProtocol,
            limits: limits,
            progress: progress,
            shouldCancel: shouldCancel
        ) { result in
            completion(result.map { stream in
                let relevantInnerIDs = Set(stream.records.map(\.packetID) + [stream.capturedThroughPacketID])
                let sessionIDByInnerID = Dictionary(
                    packetIDMapping.compactMap { sessionID, innerID in
                        relevantInnerIDs.contains(innerID) ? (innerID, sessionID) : nil
                    },
                    uniquingKeysWith: { existing, _ in existing }
                )
                return stream.remappingPacketIDs(
                    packetIDByOriginalID: sessionIDByInnerID,
                    fallbackPacketID: packetID
                )
            })
        }
    }

    // MARK: - Save / export

    func save(completion: @escaping TCPViewerVoidCompletion) {
        completion(.failure(Self.readOnlyError()))
    }

    func save(to url: URL, format: CaptureFileFormat, completion: @escaping TCPViewerVoidCompletion) {
        _ = url
        _ = format
        completion(.failure(Self.readOnlyError()))
    }

    func exportPackets(
        withIDs identifiers: [PacketSummary.ID],
        to url: URL,
        format: CaptureFileFormat,
        progress: PacketExportProgressHandler?,
        shouldCancel: PacketExportCancellationCheck?,
        completion: @escaping TCPViewerVoidCompletion
    ) {
        let mapping = state.wrappedValue
        guard let innerDocument = mapping.innerDocument else {
            completion(.failure(Self.unavailableBackingError()))
            return
        }
        let innerIDs = identifiers.compactMap { mapping.innerPacketIDBySessionID[$0] }
        guard innerIDs.count == identifiers.count else {
            completion(.failure(Self.unavailableBackingError()))
            return
        }
        innerDocument.exportPackets(
            withIDs: innerIDs,
            to: url,
            format: format,
            progress: progress,
            shouldCancel: shouldCancel,
            completion: completion
        )
    }

    func exportPackets(
        withIDs identifiers: [PacketSummary.ID],
        to url: URL,
        format: CaptureFileFormat,
        metadata: PacketExportMetadata,
        progress: PacketExportProgressHandler?,
        shouldCancel: PacketExportCancellationCheck?,
        completion: @escaping TCPViewerVoidCompletion
    ) {
        let mapping = state.wrappedValue
        guard let innerDocument = mapping.innerDocument else {
            completion(.failure(Self.unavailableBackingError()))
            return
        }
        let innerIDs = identifiers.compactMap { mapping.innerPacketIDBySessionID[$0] }
        guard innerIDs.count == identifiers.count else {
            completion(.failure(Self.unavailableBackingError()))
            return
        }

        var remappedStyles: [PacketSummary.ID: PacketTextStyle] = [:]
        var remappedComments: [PacketSummary.ID: String] = [:]
        for (sessionID, innerID) in zip(identifiers, innerIDs) {
            if let style = metadata.textStylesByPacketID[sessionID] {
                remappedStyles[innerID] = style
            }
            if let comment = metadata.commentsByPacketID[sessionID] {
                remappedComments[innerID] = comment
            }
        }
        innerDocument.exportPackets(
            withIDs: innerIDs,
            to: url,
            format: format,
            metadata: PacketExportMetadata(
                textStylesByPacketID: remappedStyles,
                commentsByPacketID: remappedComments
            ),
            progress: progress,
            shouldCancel: shouldCancel,
            completion: completion
        )
    }

    // MARK: - Snapshots

    func currentURL() -> URL {
        URL(fileURLWithPath: contents.sourceFilePath)
    }

    func currentMetadata() -> CaptureDocumentMetadata {
        state.wrappedValue.metadata
    }

    func packetSummaries() -> [PacketSummary] {
        state.wrappedValue.openedPackets
    }

    func loadProgress() -> PacketLoadProgress {
        state.wrappedValue.progress
    }

    // MARK: - Inner open completion

    private func finishInnerOpen(
        _ result: Result<[PacketSummary], Error>,
        completion: @escaping TCPViewerCompletion<[PacketSummary]>
    ) {
        switch result {
        case .success(let innerPackets):
            let mapping: (packets: [PacketSummary], failedFlowCount: Int) = state.write { mutable in
                let mapping = Self.rebuildPacketMapping(
                    contents: contents,
                    innerPackets: innerPackets,
                    mutable: &mutable
                )
                mutable.openedPackets = mapping.packets
                mutable.importReport = mutable.importReport.addingFailedFlows(mapping.failedFlowCount)
                if let innerDocument = mutable.innerDocument {
                    let innerMetadata = innerDocument.currentMetadata()
                    mutable.metadata = CaptureDocumentMetadata(
                        format: .pcapng,
                        operatingSystem: innerMetadata.operatingSystem,
                        hardware: innerMetadata.hardware,
                        captureApplication: contents.manifest.applicationName,
                        fileComment: innerMetadata.fileComment ?? "TCPViewer Session"
                    )
                }
                mutable.progress = PacketLoadProgress(
                    phase: .completed,
                    loadedPacketCount: mutable.openedPackets.count,
                    message: Self.progressMessage(
                        sourceFileName: contents.sourceFileName,
                        loadedPacketCount: mutable.openedPackets.count,
                        importReport: mutable.importReport
                    )
                )
                return mapping
            }

            let current = state.wrappedValue
            emit(.documentMetadataChanged(current.metadata))
            emit(.packetBatch(current.openedPackets, disposition: .replace))
            emit(.loadProgressChanged(current.progress))
            emit(.documentStateChanged(phase: .loaded, message: current.progress.message))
            completion(.success(mapping.packets))
        case .failure(let error):
            state.write { mutable in
                mutable.progress = PacketLoadProgress(
                    phase: .failed,
                    loadedPacketCount: 0,
                    message: Self.errorMessage(error)
                )
            }
            completion(.failure(error))
        }
    }

    /// Upstream rebuildPacketMapping: position-based session↔inner identity,
    /// with the inner capture's follow stream IDs carried onto the session
    /// packets. Records that no longer line up count as failed flows.
    private static func rebuildPacketMapping(
        contents: SessionPackageContents,
        innerPackets: [PacketSummary],
        mutable: inout MutableState
    ) -> (packets: [PacketSummary], failedFlowCount: Int) {
        mutable.innerPacketIDBySessionID.removeAll(keepingCapacity: true)
        mutable.sessionPacketByID.removeAll(keepingCapacity: true)
        var sessionPacketByRecordID: [PacketSummary.ID: PacketSummary] = [:]
        for packet in contents.packets where sessionPacketByRecordID[packet.id] == nil {
            sessionPacketByRecordID[packet.id] = packet
        }

        var mappedPackets: [PacketSummary] = []
        mappedPackets.reserveCapacity(contents.packets.count)
        var failedFlowCount = 0
        for record in contents.packetRecords.sorted(by: { $0.captureOrdinal < $1.captureOrdinal }) {
            guard innerPackets.indices.contains(record.captureOrdinal),
                  let sessionPacket = sessionPacketByRecordID[record.packetID] else {
                failedFlowCount += 1
                continue
            }

            let innerPacket = innerPackets[record.captureOrdinal]
            mutable.innerPacketIDBySessionID[sessionPacket.id] = innerPacket.id
            let mappedPacket = sessionPacket.applying(followStreamID: innerPacket.followStreamID)
            mutable.sessionPacketByID[sessionPacket.id] = mappedPacket
            mappedPackets.append(mappedPacket)
        }
        return (mappedPackets, failedFlowCount)
    }

    // MARK: - Events / helpers

    private func emit(_ event: PacketIngestEvent) {
        eventState.wrappedValue?(.success(event))
    }

    static func readOnlyError() -> TCPViewerCoreError {
        TCPViewerCoreError(
            code: .offlineFileSaveFailed,
            message: "TCPViewer sessions are read-only. Export the packets or create a new session file instead."
        )
    }

    static func unavailableBackingError() -> TCPViewerCoreError {
        TCPViewerCoreError(
            code: .offlineFileOpenFailed,
            message: "The TCPViewer session backing pcapng is not available."
        )
    }

    static func cancelledError() -> TCPViewerCoreError {
        TCPViewerCoreError(code: .operationCancelled, message: "The TCPViewer session operation was cancelled.")
    }

    static func errorMessage(_ error: Error) -> String {
        if let tcpviewerError = error as? TCPViewerCoreError {
            return tcpviewerError.message
        }
        return error.localizedDescription
    }

    static func progressMessage(
        sourceFileName: String,
        loadedPacketCount: Int,
        importReport: SessionImportReport
    ) -> String {
        let baseMessage = "Loaded \(loadedPacketCount) packets from \(sourceFileName)."
        guard importReport.failedFlowCount > 0 else {
            return baseMessage
        }
        let reason = importReport.failedFlowCount == 1 ? "it was malformed" : "they were malformed"
        let flowText = importReport.failedFlowCount == 1 ? "flow" : "flows"
        return "\(baseMessage) Skipped \(importReport.failedFlowCount) \(flowText) because \(reason)."
    }
}

// MARK: - Local remap helpers (upstream WorkspaceFoundation extensions)

extension PacketSummary {
    /// Packet copy with Wireshark's connection-specific follow stream ID.
    func applying(followStreamID: FollowStreamID?) -> PacketSummary {
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
            direction: direction,
            tcpFlags: tcpFlags,
            tcpPayloadLength: tcpPayloadLength,
            infoSummary: infoSummary,
            layers: layers,
            decodeStatus: decodeStatus,
            captureMetadata: captureMetadata,
            sniDomainName: sniDomainName,
            dnsDomainName: dnsDomainName,
            dnsResolutions: dnsResolutions,
            client: client,
            textStyle: textStyle,
            customComment: customComment
        )
    }
}

extension FollowStream {
    /// Translates inner packet IDs to their stable session IDs.
    func remappingPacketIDs(
        packetIDByOriginalID: [PacketSummary.ID: PacketSummary.ID],
        fallbackPacketID: PacketSummary.ID
    ) -> FollowStream {
        FollowStream(
            streamProtocol: streamProtocol,
            client: client,
            server: server,
            records: records.map { record in
                FollowStreamRecord(
                    direction: record.direction,
                    packetID: packetIDByOriginalID[record.packetID] ?? fallbackPacketID,
                    timestamp: record.timestamp,
                    sequenceNumber: record.sequenceNumber,
                    data: record.data
                )
            },
            clientByteCount: clientByteCount,
            serverByteCount: serverByteCount,
            capturedThroughPacketID: packetIDByOriginalID[capturedThroughPacketID] ?? fallbackPacketID,
            capturedAt: capturedAt,
            isTruncated: isTruncated
        )
    }
}

extension SessionImportReport {
    func addingFailedFlows(_ count: Int) -> SessionImportReport {
        guard count > 0 else { return self }
        return SessionImportReport(
            importedFlowCount: importedFlowCount,
            failedFlowCount: failedFlowCount + count
        )
    }
}
