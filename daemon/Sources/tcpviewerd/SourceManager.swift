//
//  SourceManager.swift
//  tcpviewerd
//
//  Owns every capture source (live + offline), applies upstream event
//  semantics (TCPViewer WorkspaceFoundation.applyPacketIngestEvent),
//  maintains bounded incremental query indexes, and fans out daemon events.
//  All state mutates on the serial `queue`, per upstream AGENTS.md:
//  no async/await, callbacks + DispatchQueues, only-new-ID work on append
//  paths, capped batches.
//

import Foundation
import PcapPlusPlusCore
import TCPViewerIPC

/// Error that already carries a wire error code + client-safe message.
struct SourceError: Error {
    let code: String
    let message: String
}

final class SourceManager: @unchecked Sendable {
    static let daemonVersion = "0.1.0"

    // MARK: - Source record

    enum Kind: String {
        case live
        case offline
    }

    final class Source {
        let id: String
        let kind: Kind
        let createdAt = Date()
        let interfaceID: String?
        let filePath: String?
        let liveSession: (any LiveCaptureSessionProviding)?
        let offlineDocument: (any OfflineCaptureDocumentProviding)?
        var phase: String
        var statusMessage: String?
        var summaries: [PacketSummary] = []
        var health: CaptureHealthSnapshot?
        var loadProgress: PacketLoadProgress?
        var isOfflineLoading = false

        // Display-filter index: activated expression + ascending matching IDs.
        // Incremental: `evaluatedCount` = prefix of `summaries` already scanned.
        var displayFilter: String?
        var filterGeneration: UInt64 = 0
        var filterIDs: [UInt64] = []
        var filterEvaluatedCount = 0
        var filterEvalInFlight = false
        var filterEvalPending = false

        // Combined display+quick cache (key = filter + quick set).
        var combinedKey: String?
        var combinedIDs: [UInt64] = []

        // Bounded log of late summary updates (id-only batches) for cursor pulls.
        var updateBatches: [(seq: UInt64, ids: [UInt64])] = []
        var updateSeq: UInt64 = 0
        var evictedUpdateSeq: UInt64 = 0
        var lastStateEmit = Date.distantPast

        init(
            id: String,
            kind: Kind,
            liveSession: (any LiveCaptureSessionProviding)? = nil,
            offlineDocument: (any OfflineCaptureDocumentProviding)? = nil,
            interfaceID: String? = nil,
            filePath: String? = nil,
            phase: String
        ) {
            self.id = id
            self.kind = kind
            self.liveSession = liveSession
            self.offlineDocument = offlineDocument
            self.interfaceID = interfaceID
            self.filePath = filePath
            self.phase = phase
        }

        // MARK: Session facade (one source = exactly one of the two kinds)

        /// Multiplexed ingest handler — attaches to whichever session exists.
        var eventHandler: PacketIngestEventHandler? {
            get { liveSession?.eventHandler ?? offlineDocument?.eventHandler }
            set {
                if let liveSession { liveSession.eventHandler = newValue }
                if let offlineDocument { offlineDocument.eventHandler = newValue }
            }
        }

        func inspectPacket(id: PacketSummary.ID, completion: @escaping TCPViewerCompletion<PacketInspection>) {
            if let liveSession {
                liveSession.inspectPacket(id: id, completion: completion)
            } else {
                offlineDocument?.inspectPacket(id: id, completion: completion)
            }
        }

        func exportPackets(
            withIDs identifiers: [PacketSummary.ID],
            to url: URL,
            format: CaptureFileFormat,
            progress: PacketExportProgressHandler?,
            shouldCancel: PacketExportCancellationCheck?,
            completion: @escaping TCPViewerVoidCompletion
        ) {
            if let liveSession {
                liveSession.exportPackets(
                    withIDs: identifiers, to: url, format: format,
                    progress: progress, shouldCancel: shouldCancel, completion: completion
                )
            } else {
                offlineDocument?.exportPackets(
                    withIDs: identifiers, to: url, format: format,
                    progress: progress, shouldCancel: shouldCancel, completion: completion
                )
            }
        }

        func activateDisplayFilter(
            _ expression: String,
            generation: UInt64,
            completion: @escaping (DisplayFilterValidation) -> Void
        ) {
            if let liveSession {
                liveSession.activateDisplayFilter(expression, generation: generation, completion: completion)
            } else {
                offlineDocument?.activateDisplayFilter(expression, generation: generation, completion: completion)
            }
        }

        func evaluateDisplayFilter(
            packetIDs: [PacketSummary.ID],
            generation: UInt64,
            completion: @escaping TCPViewerCompletion<DisplayFilterMatchBatch>
        ) {
            if let liveSession {
                liveSession.evaluateDisplayFilter(packetIDs: packetIDs, generation: generation, completion: completion)
            } else {
                offlineDocument?.evaluateDisplayFilter(packetIDs: packetIDs, generation: generation, completion: completion)
            }
        }

        func followStream(
            containing packetID: PacketSummary.ID,
            streamProtocol: FollowStreamProtocol?,
            limits: FollowStreamLimits,
            progress: FollowStreamProgressHandler?,
            shouldCancel: FollowStreamCancellationCheck?,
            completion: @escaping TCPViewerCompletion<FollowStream>
        ) {
            if let liveSession {
                liveSession.followStream(
                    containing: packetID, streamProtocol: streamProtocol, limits: limits,
                    progress: progress, shouldCancel: shouldCancel, completion: completion
                )
            } else {
                offlineDocument?.followStream(
                    containing: packetID, streamProtocol: streamProtocol, limits: limits,
                    progress: progress, shouldCancel: shouldCancel, completion: completion
                )
            }
        }

        var packetCount: Int { summaries.count }

        var lastPacketID: UInt64 { summaries.last?.id ?? 0 }

        /// Binary search — summaries are append-ordered by ascending id, so
        /// no duplicate id→summary dictionary (memory doubles at 10k pps).
        func summary(for id: UInt64) -> PacketSummary? {
            var low = 0
            var high = summaries.count - 1
            while low <= high {
                let mid = (low + high) / 2
                let candidate = summaries[mid]
                if candidate.id == id { return candidate }
                if candidate.id < id { low = mid + 1 } else { high = mid - 1 }
            }
            return nil
        }

        /// Drop all indexes after a clear/replace so no stale id resurfaces.
        func resetIndexes() {
            filterIDs = []
            filterEvaluatedCount = 0
            filterEvalInFlight = false
            filterEvalPending = false
            combinedKey = nil
            combinedIDs = []
            updateBatches = []
            updateSeq = 0
            evictedUpdateSeq = 0
        }
    }

    // MARK: - State

    private let queue = DispatchQueue(label: "org.omarchy.tcpviewerd.SourceManager")
    let core = NativeTCPViewerCore()
    private(set) var sources: [Source] = []
    /// Fan-out set by SocketServer; called on `queue`.
    var eventSink: ((IPCEventMessage) -> Void)?

    private func emit(_ event: IPCEvent, data: [String: IPCValue]) {
        eventSink?(IPCEventMessage(event: event, data: data))
    }

    private func fail<T>(_ code: String, _ message: String, _ completion: (Result<T, Error>) -> Void) {
        completion(.failure(SourceError(code: code, message: message)))
    }

    // MARK: - Interface / filter validation

    func listInterfaces(completion: @escaping (Result<[CaptureInterfaceSummary], Error>) -> Void) {
        core.listInterfaces { result in
            self.queue.async { completion(result) }
        }
    }

    func validateCaptureFilter(_ expression: String, completion: @escaping (CaptureFilterValidation) -> Void) {
        core.validateCaptureFilter(expression) { validation in
            self.queue.async { completion(validation) }
        }
    }

    // MARK: - Source lifecycle

    /// Starts a live capture. Mirrors upstream "Start begins a new capture
    /// and clears the active packet workspace": any previous live source is
    /// stopped and closed; offline sources are untouched.
    func startCapture(
        interfaceID: String,
        bpf: String?,
        promiscuous: Bool?,
        completion: @escaping (Result<Source, Error>) -> Void
    ) {
        queue.async {
            let trimmedBPF = bpf?.trimmingCharacters(in: .whitespacesAndNewlines)
            let proceed = { (interfaces: [CaptureInterfaceSummary]) in
                self.beginLiveCapture(
                    interfaceID: interfaceID,
                    bpf: (trimmedBPF?.isEmpty ?? true) ? nil : trimmedBPF,
                    promiscuous: promiscuous,
                    interfaces: interfaces,
                    completion: completion
                )
            }
            if let trimmedBPF, !trimmedBPF.isEmpty {
                self.core.validateCaptureFilter(trimmedBPF) { validation in
                    guard validation.disposition == .valid else {
                        self.queue.async {
                            self.fail(
                                IPCError.invalidParams,
                                "invalid BPF filter: \(validation.message ?? "rejected by libpcap")",
                                completion
                            )
                        }
                        return
                    }
                    self.core.listInterfaces { result in
                        self.queue.async {
                            switch result {
                            case .success(let interfaces): proceed(interfaces)
                            case .failure(let error): completion(.failure(error))
                            }
                        }
                    }
                }
            } else {
                self.core.listInterfaces { result in
                    self.queue.async {
                        switch result {
                        case .success(let interfaces): proceed(interfaces)
                        case .failure(let error): completion(.failure(error))
                        }
                    }
                }
            }
        }
    }

    private func beginLiveCapture(
        interfaceID: String,
        bpf: String?,
        promiscuous: Bool?,
        interfaces: [CaptureInterfaceSummary],
        completion: @escaping (Result<Source, Error>) -> Void
    ) {
        // Interface must exist, be up, and be capturable — upstream fails
        // loudly instead of falling back to another device.
        guard let interface = interfaces.first(where: { $0.id == interfaceID }) else {
            return fail(IPCError.notFound, "unknown interface: \(interfaceID)", completion)
        }
        guard interface.availability == .available else {
            return fail(IPCError.captureFailed, "interface \(interfaceID) is \(interface.availability.rawValue)", completion)
        }
        guard interface.capabilities.canCapture else {
            return fail(IPCError.permissionDenied, "interface \(interfaceID) cannot be captured", completion)
        }

        let options = CaptureOptions(
            promiscuousMode: promiscuous ?? (interface.capabilities.supportsPromiscuousMode && !interface.isLoopback),
            snapshotLength: 65_535,
            kernelBufferSizeBytes: 4 * 1024 * 1024,
            readTimeoutMilliseconds: 250,
            captureFilterExpression: bpf,
            stopCondition: .manual,
            fileWriting: .disabled
        )

        core.makeLiveCaptureSession(interfaceID: interfaceID, options: options) { result in
            self.queue.async {
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let session):
                    let previous = self.sources.filter { $0.kind == .live }
                    let source = Source(
                        id: UUID().uuidString.lowercased(),
                        kind: .live,
                        liveSession: session,
                        interfaceID: interfaceID,
                        phase: LiveCaptureSessionPhase.ready.rawValue
                    )
                    self.attach(source: source)
                    self.sources.append(source)

                    // Stop and close previous live sources (one active capture).
                    for old in previous {
                        self.stopAndRemove(source: old, emitChange: false)
                    }

                    session.start { startResult in
                        self.queue.async {
                            switch startResult {
                            case .success:
                                self.emit(.sourcesChanged, data: ["source_id": .string(source.id), "action": .string("opened")])
                                completion(.success(source))
                            case .failure(let error):
                                self.sources.removeAll { $0.id == source.id }
                                completion(.failure(error))
                            }
                        }
                    }
                }
            }
        }
    }

    /// Opens an import file as a new offline source (upstream file.import).
    func importFile(path: String, completion: @escaping (Result<Source, Error>) -> Void) {
        queue.async {
            let resolved: String
            do {
                resolved = try SourceSecurity.validatedImportPath(path)
            } catch let error as SourceError {
                return completion(.failure(error))
            } catch {
                return completion(.failure(error))
            }

            let url = URL(fileURLWithPath: resolved)
            self.core.openOfflineCaptureDocument(at: url) { result in
                self.queue.async {
                    switch result {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let document):
                        let source = Source(
                            id: UUID().uuidString.lowercased(),
                            kind: .offline,
                            offlineDocument: document,
                            filePath: resolved,
                            phase: OfflineCaptureDocumentPhase.opening.rawValue
                        )
                        source.isOfflineLoading = true
                        self.attach(source: source)
                        self.sources.append(source)
                        self.emit(.sourcesChanged, data: ["source_id": .string(source.id), "action": .string("opened")])

                        document.open { openResult in
                            self.queue.async {
                                source.isOfflineLoading = false
                                switch openResult {
                                case .failure(let error):
                                    // Keep the failed source listed with its phase so the
                                    // client sees why; packets stay empty.
                                    source.phase = OfflineCaptureDocumentPhase.failed.rawValue
                                    source.statusMessage = String(describing: error)
                                    self.emit(.sourcesChanged, data: ["source_id": .string(source.id), "action": .string("failed")])
                                    completion(.failure(error))
                                case .success(let summaries):
                                    // Authoritative full list (matches upstream final
                                    // packetCache.set) — event batches streamed before this.
                                    source.summaries = summaries
                                    source.phase = OfflineCaptureDocumentPhase.loaded.rawValue
                                    source.statusMessage = "Loaded \(summaries.count) packets."
                                    source.resetIndexes()
                                    self.emit(.sourcesChanged, data: ["source_id": .string(source.id), "action": .string("loaded")])
                                    completion(.success(source))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func closeSource(id: String, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            guard let source = self.sources.first(where: { $0.id == id }) else {
                return self.fail(IPCError.notFound, "unknown source: \(id)", completion)
            }
            if source.kind == .live {
                self.stopAndRemove(source: source, emitChange: true, completion: completion)
            } else {
                if source.isOfflineLoading {
                    source.offlineDocument?.cancelLoading(completion: nil)
                }
                self.sources.removeAll { $0.id == id }
                self.emit(.sourcesChanged, data: ["source_id": .string(id), "action": .string("closed")])
                completion(.success(()))
            }
        }
    }

    private func stopAndRemove(
        source: Source,
        emitChange: Bool,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        guard let live = source.liveSession else {
            sources.removeAll { $0.id == source.id }
            if emitChange {
                emit(.sourcesChanged, data: ["source_id": .string(source.id), "action": .string("closed")])
            }
            completion?(.success(()))
            return
        }
        live.stop { _ in
            self.queue.async {
                self.sources.removeAll { $0.id == source.id }
                if emitChange {
                    self.emit(.sourcesChanged, data: ["source_id": .string(source.id), "action": .string("closed")])
                }
                completion?(.success(()))
            }
        }
    }

    func controlCapture(
        id: String?,
        action: String,
        completion: @escaping (Result<Source, Error>) -> Void
    ) {
        queue.async {
            guard let source = self.resolveLiveSource(id: id, completion: completion) else { return }
            guard let live = source.liveSession else {
                return self.fail(IPCError.invalidParams, "source \(source.id) is not a live capture", completion)
            }
            let finish: TCPViewerVoidCompletion = { result in
                self.queue.async {
                    if action == "clear" {
                        source.summaries = []
                        source.resetIndexes()
                        source.health = nil
                    }
                    switch result {
                    case .success: completion(.success(source))
                    case .failure(let error): completion(.failure(error))
                    }
                }
            }
            switch action {
            case "pause": live.pause(completion: finish)
            case "resume": live.resume(completion: finish)
            case "stop": live.stop(completion: finish)
            case "clear": live.clearCapturedPackets(completion: finish)
            default:
                return self.fail(IPCError.invalidParams, "unknown capture action: \(action)", completion)
            }
        }
    }

    func sourcesSnapshot(completion: @escaping ([Source]) -> Void) {
        queue.async { completion(self.sources) }
    }

    /// Newest source wins when the client omits source_id (single-capture UX).
    private func resolveSource<T>(
        id: String?,
        completion: (Result<T, Error>) -> Void
    ) -> Source? {
        if let id {
            guard let source = sources.first(where: { $0.id == id }) else {
                fail(IPCError.notFound, "unknown source: \(id)", completion)
                return nil
            }
            return source
        }
        guard let source = sources.last else {
            fail(IPCError.notFound, "no capture sources open", completion)
            return nil
        }
        return source
    }

    private func resolveLiveSource<T>(
        id: String?,
        completion: (Result<T, Error>) -> Void
    ) -> Source? {
        guard let source = resolveSource(id: id, completion: completion) else { return nil }
        guard source.kind == .live else {
            fail(IPCError.invalidParams, "source \(source.id) is not a live capture", completion)
            return nil
        }
        return source
    }

    // MARK: - Core event wiring (upstream applyPacketIngestEvent semantics)

    /// Wires the source's event stream into `apply`. The handler captures the
    /// source ID, never the Source object — avoids a session↔source retain
    /// cycle, and drops late events from already-closed sources.
    private func attach(source: Source) {
        let sourceID = source.id
        source.eventHandler = { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                break  // surfaced through phase events (failed) — ignore here
            case .success(let event):
                self.queue.async {
                    guard let source = self.sources.first(where: { $0.id == sourceID }) else { return }
                    self.apply(event, on: source)
                }
            }
        }
    }

    private func apply(_ event: PacketIngestEvent, on source: Source) {
        // A closed source may still deliver a late event — drop it.
        guard sources.contains(where: { $0.id == source.id }) else { return }

        switch event {
        case .liveStateChanged(let phase, let message):
            source.phase = phase.rawValue
            source.statusMessage = message
            emit(.captureState, data: statusData(for: source))

        case .documentStateChanged(let phase, let message):
            source.phase = phase.rawValue
            source.statusMessage = message
            if phase == .opening || phase == .reopening {
                source.isOfflineLoading = true
            }
            emit(.captureState, data: statusData(for: source))

        case .packetBatch(let packets, let disposition):
            // Upstream: offline batches only count while the document is
            // streaming open; the completion supplies the final list.
            if source.kind == .offline && !source.isOfflineLoading { return }

            switch disposition {
            case .replace:
                source.summaries = packets
                source.resetIndexes()
            case .append:
                guard !packets.isEmpty else { return }
                source.summaries.append(contentsOf: packets)
                // Append-path rule: only NEW ids join the indexes.
                scheduleTailEvaluation(for: source, newCount: packets.count)
            }

        case .packetSummaryUpdates(let updates):
            applySummaryUpdates(updates, on: source)

        case .loadProgressChanged(let progress):
            source.loadProgress = progress
            emitThrottledState(for: source)

        case .healthChanged(let health):
            source.health = health
            emit(.captureHealth, data: statusData(for: source))

        case .documentMetadataChanged:
            break  // v1 exposes metadata via sources.list path/format only
        }
    }

    private func applySummaryUpdates(_ updates: [PacketSummaryUpdate], on source: Source) {
        for update in updates {
            guard let index = indexOfSummary(id: update.packetID, in: source) else { continue }
            let old = source.summaries[index]
            source.summaries[index] = PacketSummary(
                id: old.id,
                packetNumber: old.packetNumber,
                timestamp: old.timestamp,
                source: old.source,
                interfaceID: old.interfaceID,
                transportHint: old.transportHint,
                protocolSummary: update.protocolSummary ?? old.protocolSummary,
                endpoints: old.endpoints,
                originalLength: old.originalLength,
                capturedLength: old.capturedLength,
                streamID: old.streamID,
                followStreamID: old.followStreamID,
                direction: old.direction,
                tcpFlags: old.tcpFlags,
                tcpPayloadLength: old.tcpPayloadLength,
                infoSummary: update.infoSummary,
                layers: old.layers,
                decodeStatus: old.decodeStatus,
                captureMetadata: old.captureMetadata,
                sniDomainName: old.sniDomainName,
                dnsDomainName: old.dnsDomainName,
                dnsResolutions: old.dnsResolutions,
                client: old.client,
                textStyle: old.textStyle,
                customComment: old.customComment
            )
        }
        guard !updates.isEmpty else { return }

        // Bounded ring: keep at most 2000 batches / 100k ids.
        source.updateSeq += 1
        source.updateBatches.append((seq: source.updateSeq, ids: updates.map(\.packetID)))
        var totalIDs = source.updateBatches.reduce(0) { $0 + $1.ids.count }
        while source.updateBatches.count > 2_000 || totalIDs > 100_000 {
            let evicted = source.updateBatches.removeFirst()
            totalIDs -= evicted.ids.count
            source.evictedUpdateSeq = evicted.seq
        }
    }

    private func indexOfSummary(id: UInt64, in source: Source) -> Int? {
        // Summaries are ascending; reuse binary search by id.
        var low = 0
        var high = source.summaries.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let candidate = source.summaries[mid]
            if candidate.id == id { return mid }
            if candidate.id < id { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }

    private func emitThrottledState(for source: Source, minInterval: TimeInterval = 0.25) {
        let now = Date()
        guard now.timeIntervalSince(source.lastStateEmit) >= minInterval else { return }
        source.lastStateEmit = now
        emit(.captureState, data: statusData(for: source))
    }

    // MARK: - Display-filter index (incremental, generation-guarded)

    /// Ensures `expr` is the source's activated filter and the match index
    /// covers all current packets. "" or nil = unfiltered (index = all ids).
    private func ensureFilterIndex(
        source: Source,
        expr: String?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let normalized = expr?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if normalized.isEmpty {
            // Unfiltered: index = every id (kept current by append path).
            if source.displayFilter != nil {
                source.displayFilter = nil
                source.filterGeneration += 1
                source.filterIDs = source.summaries.map(\.id)
                source.filterEvaluatedCount = source.summaries.count
                source.combinedKey = nil
            } else if source.filterEvaluatedCount != source.summaries.count {
                source.filterIDs = source.summaries.map(\.id)
                source.filterEvaluatedCount = source.summaries.count
            }
            return completion(.success(()))
        }

        if source.displayFilter == normalized {
            if source.filterEvaluatedCount >= source.summaries.count {
                return completion(.success(()))
            }
            // Caught up later by the tail loop; waiters register pending.
            source.filterEvalPending = true
            runTailEvaluation(for: source)
            // Completion when caught up: poll via chained check.
            waitForFilterCaughtUp(source: source, completion: completion)
            return
        }

        // New expression → activate (validates) and rebuild.
        source.filterGeneration += 1
        let generation = source.filterGeneration
        source.displayFilter = normalized
        source.filterIDs = []
        source.filterEvaluatedCount = 0
        source.combinedKey = nil

        source.activateDisplayFilter(normalized, generation: generation) { validation in
            self.queue.async {
                guard generation == source.filterGeneration else {
                    return completion(.success(()))  // superseded by a newer filter
                }
                guard validation.status == .valid else {
                    source.displayFilter = nil
                    let detail = validation.diagnostics.map(\.message).joined(separator: "; ")
                    return self.fail(
                        IPCError.invalidParams,
                        "invalid display filter: \(detail.isEmpty ? validation.normalizedExpression : detail)",
                        completion
                    )
                }
                source.filterEvaluatedCount = 0
                source.filterIDs = []
                self.runTailEvaluation(for: source)
                self.waitForFilterCaughtUp(source: source, completion: completion)
            }
        }
    }

    /// Completes when the index covers all summaries (bounded chunked eval).
    private func waitForFilterCaughtUp(source: Source, completion: @escaping (Result<Void, Error>) -> Void) {
        if source.filterEvaluatedCount >= source.summaries.count, !source.filterEvalPending, !source.filterEvalInFlight {
            return completion(.success(()))
        }
        // The tail loop chains waiters after each chunk.
        pendingWaiters[source.id, default: []].append(completion)
        runTailEvaluation(for: source)
    }

    private var pendingWaiters: [String: [(Result<Void, Error>) -> Void]] = [:]

    private func flushWaiters(for source: Source) {
        guard source.filterEvaluatedCount >= source.summaries.count,
            !source.filterEvalPending, !source.filterEvalInFlight
        else { return }
        let waiters = pendingWaiters.removeValue(forKey: source.id) ?? []
        for waiter in waiters {
            waiter(.success(()))
        }
    }

    /// Evaluate only summaries beyond `filterEvaluatedCount` (append rule).
    private func scheduleTailEvaluation(for source: Source, newCount: Int) {
        guard source.displayFilter != nil else {
            // Unfiltered index stays current with plain appends.
            source.filterIDs.append(contentsOf: source.summaries.suffix(newCount).map(\.id))
            source.filterEvaluatedCount = source.summaries.count
            source.combinedKey = nil  // combined rebuilt lazily from new ids
            return
        }
        guard newCount > 0 else { return }
        source.filterEvalPending = true
        runTailEvaluation(for: source)
    }

    private func runTailEvaluation(for source: Source) {
        guard source.displayFilter != nil, !source.filterEvalInFlight else { return }
        guard source.filterEvaluatedCount < source.summaries.count else {
            source.filterEvalPending = false
            flushWaiters(for: source)
            return
        }

        // Bounded chunk (5000 ids) keeps a single Wireshark evaluation short.
        let start = source.filterEvaluatedCount
        let end = min(start + 5_000, source.summaries.count)
        let chunkIDs = Array(source.summaries[start..<end].map(\.id))
        let generation = source.filterGeneration
        source.filterEvalInFlight = true

        source.evaluateDisplayFilter(packetIDs: chunkIDs, generation: generation) { result in
            self.queue.async {
                source.filterEvalInFlight = false
                guard generation == source.filterGeneration else { return }  // stale
                switch result {
                case .success(let batch):
                    source.filterIDs.append(contentsOf: batch.matchingPacketIDs)
                    source.filterEvaluatedCount = end
                    if source.filterEvaluatedCount >= source.summaries.count {
                        source.filterEvalPending = false
                    }
                    source.combinedKey = nil  // display set changed → rebuild combined
                    if source.filterEvalPending || source.filterEvaluatedCount < source.summaries.count {
                        self.runTailEvaluation(for: source)
                    } else {
                        self.flushWaiters(for: source)
                    }
                case .failure(let error):
                    source.filterEvalPending = false
                    let waiters = self.pendingWaiters.removeValue(forKey: source.id) ?? []
                    for waiter in waiters {
                        waiter(.failure(error))
                    }
                }
            }
        }
    }

    // MARK: - Packet query

    struct PacketQueryResult {
        let sourceID: String
        let packets: [PacketSummary]
        let totalCount: Int
        let nextOffset: Int
        let complete: Bool
        let appliedFilter: String?
        let appliedQuick: [String]?
        let updateSeq: UInt64
        let updates: [(seq: UInt64, ids: [UInt64])]
        let updatesOverflow: Bool
    }

    func queryPackets(
        sourceID: String?,
        sinceID: UInt64?,
        offset: Int,
        limit: Int,
        filter: String?,
        quickFilters: [String]?,
        updatesSince: UInt64?,
        completion: @escaping (Result<PacketQueryResult, Error>) -> Void
    ) {
        queue.async {
            guard let source = self.resolveSource(id: sourceID, completion: completion) else { return }

            // filter param present → activate it for this source ("" clears);
            // absent → keep the source's current filter (documented rule).
            let effectiveFilter = filter.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                ?? source.displayFilter

            self.ensureFilterIndex(source: source, expr: effectiveFilter) { result in
                // ensureFilterIndex already runs on `queue`.
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success:
                    let queryOutcome = self.buildPage(
                        source: source,
                        sinceID: sinceID,
                        offset: max(0, offset),
                        limit: min(max(1, limit), 5_000),
                        quick: quickFilters ?? [],
                        updatesSince: updatesSince
                    )
                    completion(.success(queryOutcome))
                }
            }
        }
    }

    private func buildPage(
        source: Source,
        sinceID: UInt64?,
        offset: Int,
        limit: Int,
        quick: [String],
        updatesSince: UInt64?
    ) -> PacketQueryResult {
        let quickKey = quick.sorted().joined(separator: ",")
        let wantQuick = !quick.isEmpty && quickKey != "all"

        // Slice pipeline: display-filtered pool → since → quick → page.
        let basePool: [PacketSummary]
        if source.displayFilter == nil {
            basePool = source.summaries
        } else {
            basePool = source.filterIDs.compactMap { source.summary(for: $0) }
        }
        let complete = source.displayFilter == nil
            || (source.filterEvaluatedCount >= source.summaries.count)

        var pool = basePool
        if let sinceID {
            pool = pool.filter { $0.id > sinceID }
        }
        if wantQuick {
            pool = pool.filter { Self.quickMatches($0, quick: quick) }
        }

        let total = pool.count
        let page = offset < pool.count ? Array(pool[offset..<min(offset + limit, total)]) : []

        var updateSlice: [(seq: UInt64, ids: [UInt64])] = []
        var overflow = false
        if let updatesSince {
            if updatesSince < source.evictedUpdateSeq {
                overflow = true
            } else {
                updateSlice = source.updateBatches.filter { $0.seq > updatesSince }
            }
        }

        return PacketQueryResult(
            sourceID: source.id,
            packets: page,
            totalCount: total,
            nextOffset: offset + page.count,
            complete: complete,
            appliedFilter: source.displayFilter,
            appliedQuick: wantQuick ? quick : [],
            updateSeq: source.updateSeq,
            updates: updateSlice,
            updatesOverflow: overflow
        )
    }

    /// Local quick-filter predicates (upstream quick-filter IDs). Kept out of
    /// Wireshark so a chip click never costs a display-filter recompile.
    static func quickMatches(_ summary: PacketSummary, quick: [String]) -> Bool {
        // OR semantics across chips (upstream: empty = show all).
        for chip in quick {
            switch chip {
            case "tcp":
                if summary.transportHint == .tcp { return true }
            case "udp":
                if summary.transportHint == .udp { return true }
            case "dns":
                if summary.transportHint == .dns
                    || (summary.protocolSummary?.contains("DNS") ?? false) { return true }
            case "http":
                if summary.transportHint == .http1
                    || (summary.protocolSummary?.contains("HTTP") ?? false) { return true }
            case "tls":
                if summary.transportHint == .tls
                    || (summary.protocolSummary?.contains("TLS") ?? false) { return true }
            case "websocket":
                if summary.transportHint == .websocket
                    || (summary.protocolSummary?.contains("WebSocket") ?? false) { return true }
            case "clientHello":
                if summary.infoSummary.localizedCaseInsensitiveContains("client hello") { return true }
            case "serverHello":
                if summary.infoSummary.localizedCaseInsensitiveContains("server hello") { return true }
            case "errors":
                if summary.decodeStatus.kind == .malformed
                    || summary.infoSummary.localizedCaseInsensitiveContains("malformed") { return true }
            case "all":
                return true
            default:
                break  // unknown chip: ignore (forward-compatible)
            }
        }
        return false
    }

    // MARK: - Packet operations

    func inspectPacket(
        sourceID: String?,
        packetID: UInt64,
        maxDepth: Int,
        maxNodes: Int,
        completion: @escaping (Result<(inspection: PacketInspection, sourceID: String), Error>) -> Void
    ) {
        queue.async {
            // Explicit source, else auto-locate the packet's owner (CLI UX).
            let resolvedID = sourceID ?? self.findSource(ofPacket: packetID)
            guard let source = self.resolveSource(id: resolvedID, completion: completion) else { return }
            guard source.summary(for: packetID) != nil else {
                return self.fail(IPCError.notFound, "packet \(packetID) not found in source \(source.id)", completion)
            }
            source.inspectPacket(id: packetID) { result in
                self.queue.async {
                    switch result {
                    case .success(let inspection):
                        completion(.success((inspection, source.id)))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    private func findSource(ofPacket id: UInt64) -> String? {
        for source in sources.reversed() where source.summary(for: id) != nil {
            return source.id
        }
        return nil
    }

    func clearPackets(sourceID: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        controlCapture(id: sourceID, action: "clear") { _ in
            completion(.success(()))
        }
    }

    func followStream(
        sourceID: String?,
        packetID: UInt64,
        direction: String?,
        completion: @escaping (Result<(stream: FollowStream, sourceID: String, followID: FollowStreamID?), Error>) -> Void
    ) {
        queue.async {
            let resolvedID = self.findSource(ofPacket: packetID) ?? sourceID
            guard let source = self.resolveSource(id: resolvedID, completion: completion) else { return }
            guard source.summary(for: packetID) != nil else {
                return self.fail(IPCError.notFound, "packet \(packetID) not found in source \(source.id)", completion)
            }

            var included: FollowStreamDirection?
            switch direction {
            case nil, "", "both": included = nil
            case "client-to-server", "clientToServer": included = .clientToServer
            case "server-to-client", "serverToClient": included = .serverToClient
            default:
                return self.fail(IPCError.invalidParams, "unknown direction: \(direction ?? "")", completion)
            }

            // Upstream CLI.md bounds: 250k candidates, 4 MiB output, 10k records.
            let limits = FollowStreamLimits(
                maximumCandidatePacketCount: 250_000,
                maximumPayloadBytes: 4 * 1_024 * 1_024,
                maximumRecordCount: 10_000,
                includedDirection: included
            )

            source.followStream(
                containing: packetID,
                streamProtocol: nil,
                limits: limits,
                progress: nil,
                shouldCancel: nil
            ) { result in
                self.queue.async {
                    switch result {
                    case .success(let stream):
                        let followID = source.summary(for: packetID)?.followStreamID
                        completion(.success((stream, source.id, followID)))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    func streamPackets(
        sourceID: String?,
        streamKey: String,
        offset: Int,
        limit: Int,
        completion: @escaping (Result<(packets: [PacketSummary], total: Int, nextOffset: Int, sourceID: String), Error>) -> Void
    ) {
        queue.async {
            guard let source = self.resolveSource(id: sourceID, completion: completion) else { return }
            // streamKey: "tcp:12" / "udp:3" (protocol + Wireshark stream number).
            let parts = streamKey.lowercased().split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let number = UInt32(parts[1]),
                let protocolHint = FollowStreamProtocol(rawValue: String(parts[0])) else {
                return self.fail(IPCError.invalidParams, "stream id must look like 'tcp:12' or 'udp:3'", completion)
            }
            let matching = source.summaries.filter {
                $0.followStreamID?.streamProtocol == protocolHint
                    && $0.followStreamID?.streamID == number
            }
            let bounded = min(max(1, limit), 5_000)
            let start = min(max(0, offset), matching.count)
            let page = Array(matching[start..<min(start + bounded, matching.count)])
            completion(.success((page, matching.count, start + page.count, source.id)))
        }
    }

    // MARK: - Export / session save (path security in SourceSecurity)

    func exportPackets(
        sourceID: String?,
        path: String,
        format: String,
        all: Bool,
        packetIDs: [UInt64]?,
        overwrite: Bool,
        completion: @escaping (Result<[String: IPCValue], Error>) -> Void
    ) {
        queue.async {
            guard let source = self.resolveSource(id: sourceID, completion: completion) else { return }

            let destination: String
            do {
                destination = try SourceSecurity.validatedExportPath(path, overwrite: overwrite)
            } catch let error as SourceError {
                return completion(.failure(error))
            } catch {
                return completion(.failure(error))
            }

            let exportFormat = CaptureFileFormat(exportRawValue: format)
            let ids: [PacketSummary.ID]
            if all {
                ids = source.summaries.map(\.id)
            } else if let packetIDs, !packetIDs.isEmpty {
                guard packetIDs.count <= 5_000 else {
                    return self.fail(IPCError.invalidParams, "selector exceeds 5000 packet ids (use --all)", completion)
                }
                ids = packetIDs
            } else {
                return self.fail(IPCError.invalidParams, "selector required: --all or packet ids", completion)
            }
            guard !ids.isEmpty else {
                return self.fail(IPCError.invalidParams, "no packets to export", completion)
            }

            let url = URL(fileURLWithPath: destination)
            source.exportPackets(
                withIDs: ids,
                to: url,
                format: exportFormat,
                progress: nil,
                shouldCancel: nil
            ) { result in
                self.queue.async {
                    switch result {
                    case .success:
                        completion(.success([
                            "path": .string(destination),
                            "format": .string(exportFormat.rawValue),
                            "packet_count": .int(ids.count),
                            "bytes": .int((try? FileManager.default.attributesOfItem(atPath: destination)[.size] as? Int) ?? 0),
                        ]))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    func exportSession(
        sourceID: String?,
        path: String,
        overwrite: Bool,
        completion: @escaping (Result<[String: IPCValue], Error>) -> Void
    ) {
        queue.async {
            guard let source = self.resolveSource(id: sourceID, completion: completion) else { return }

            let destination: String
            do {
                destination = try SourceSecurity.validatedExportPath(path, overwrite: overwrite)
            } catch let error as SourceError {
                return completion(.failure(error))
            } catch {
                return completion(.failure(error))
            }

            let url = URL(fileURLWithPath: destination)
            let finish: TCPViewerVoidCompletion = { result in
                self.queue.async {
                    switch result {
                    case .success:
                        completion(.success([
                            "path": .string(destination),
                            "format": .string(CaptureFileFormat.pcapng.rawValue),
                            "packet_count": .int(source.summaries.count),
                            "bytes": .int((try? FileManager.default.attributesOfItem(atPath: destination)[.size] as? Int) ?? 0),
                        ]))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            }

            // Offline: native document save (writes the loaded capture back).
            if let document = source.offlineDocument {
                document.save(to: url, format: .pcapng, completion: finish)
                return
            }
            // Live: full-capture pcapng export (documented v1 divergence —
            // upstream's .tcpviewsession store format is macOS-app state).
            source.exportPackets(
                withIDs: source.summaries.map(\.id),
                to: url,
                format: .pcapng,
                progress: nil,
                shouldCancel: nil,
                completion: finish
            )
        }
    }

    // MARK: - Status snapshots

    func statusData(for source: Source) -> [String: IPCValue] {
        var data: [String: IPCValue] = [
            "source_id": .string(source.id),
            "kind": .string(source.kind.rawValue),
            "phase": .string(source.phase),
            "created_at": .string(ISO8601DateFormatter().string(from: source.createdAt)),
            "packet_count": .int(source.summaries.count),
            "last_packet_id": .string(String(source.lastPacketID)),
        ]
        if let interfaceID = source.interfaceID {
            data["interface"] = .string(interfaceID)
        }
        if let filePath = source.filePath {
            data["path"] = .string(filePath)
        }
        if let statusMessage = source.statusMessage {
            data["status_message"] = .string(statusMessage)
        }
        if let filter = source.displayFilter {
            data["display_filter"] = .string(filter)
        }
        if let loadProgress = source.loadProgress {
            data["load_progress"] = .object([
                "phase": .string(loadProgress.phase.rawValue),
                "loaded_packet_count": .int(loadProgress.loadedPacketCount),
                "processed_bytes": loadProgress.processedBytes.map { .int(Int($0)) } ?? .null,
                "total_bytes": loadProgress.totalBytes.map { .int(Int($0)) } ?? .null,
                "is_partial_result": .bool(loadProgress.isPartialResult),
                "message": .string(loadProgress.message),
            ])
        }
        if let health = source.health {
            data["health"] = .object(Self.healthData(health))
        }
        return data
    }

    static func healthData(_ health: CaptureHealthSnapshot) -> [String: IPCValue] {
        [
            "packets_received": .string(String(health.packetsReceived)),
            "packets_dropped": .string(String(health.packetsDropped)),
            "packets_dropped_by_interface": .string(String(health.packetsDroppedByInterface)),
            "packets_observed": .string(String(health.packetsObserved)),
            "status_message": .string(health.statusMessage ?? ""),
        ]
    }

    /// capture.status with a fresh healthSnapshot pulled from the session.
    func captureStatus(
        sourceID: String?,
        completion: @escaping (Result<[String: IPCValue], Error>) -> Void
    ) {
        queue.async {
            guard let source = self.resolveSource(id: sourceID, completion: completion) else { return }
            guard let live = source.liveSession else {
                // Offline sources answer with document status only.
                return completion(.success(self.statusData(for: source)))
            }
            live.healthSnapshot { health in
                self.queue.async {
                    source.health = health
                    completion(.success(self.statusData(for: source)))
                }
            }
        }
    }
}
