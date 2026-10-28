//
//  TCPViewSessionFormat.swift
//  TCPViewerSession
//
//  Ported from upstream TCPViewer/Features/NetworkInspector/Services/
//  TCPViewSessionFormat.swift (ZIP sidecar record types). The Codable shapes
//  stay byte-compatible with the macOS app so session files round-trip
//  between the port and upstream.
//

import Foundation
import PcapPlusPlusCore

public enum TCPViewSessionFormat {
    public static let fileExtension = "tcpviewsession"
    public static let packageDirectoryName = "TCPViewerSession"
    public static let magic = "TCPViewerSession"
    public static let schemaVersion = 1
    public static let minimumCompatibleSchemaVersion = 1

    public static let manifestPath = "manifest.json"
    public static let capturePath = "capture.pcapng"
    public static let packetsPath = "packets.jsonl"
    public static let clientsPath = "clients.json"
    public static let annotationsPath = "annotations.json"
    public static let statePath = "state.json"
    public static let iconsDirectoryPath = "icons"

    /// Files every readable session must contain (upstream requiredFiles).
    public static var requiredFiles: [String] {
        [
            manifestPath,
            capturePath,
            packetsPath,
            clientsPath,
            annotationsPath,
            statePath,
        ]
    }
}

public struct TCPViewSessionManifest: Codable, Equatable {
    public var magic: String
    public var schemaVersion: Int
    public var minimumCompatibleSchemaVersion: Int
    public var createdAt: Date
    public var applicationName: String
    public var applicationVersion: String
    public var applicationBuild: String
    public var packetCount: Int
    public var files: [String]
    public var captureFile: String
    public var packetsFile: String
    public var clientsFile: String
    public var annotationsFile: String
    public var stateFile: String
    public var iconsDirectory: String

    public init(
        createdAt: Date,
        applicationName: String,
        applicationVersion: String,
        applicationBuild: String,
        packetCount: Int
    ) {
        self.magic = TCPViewSessionFormat.magic
        self.schemaVersion = TCPViewSessionFormat.schemaVersion
        self.minimumCompatibleSchemaVersion = TCPViewSessionFormat.minimumCompatibleSchemaVersion
        self.createdAt = createdAt
        self.applicationName = applicationName
        self.applicationVersion = applicationVersion
        self.applicationBuild = applicationBuild
        self.packetCount = packetCount
        self.files = [
            TCPViewSessionFormat.manifestPath,
            TCPViewSessionFormat.capturePath,
            TCPViewSessionFormat.packetsPath,
            TCPViewSessionFormat.clientsPath,
            TCPViewSessionFormat.annotationsPath,
            TCPViewSessionFormat.statePath,
            TCPViewSessionFormat.iconsDirectoryPath,
        ]
        self.captureFile = TCPViewSessionFormat.capturePath
        self.packetsFile = TCPViewSessionFormat.packetsPath
        self.clientsFile = TCPViewSessionFormat.clientsPath
        self.annotationsFile = TCPViewSessionFormat.annotationsPath
        self.stateFile = TCPViewSessionFormat.statePath
        self.iconsDirectory = TCPViewSessionFormat.iconsDirectoryPath
    }
}

public struct TCPViewSessionPacketRecord: Codable, Equatable {
    public let packetID: PacketSummary.ID
    public let captureOrdinal: Int
    public let clientID: String?
    public let packet: PacketSummary
}

public struct TCPViewSessionClientRecord: Codable, Equatable {
    public let id: String
    public let client: PacketClient
    public let iconID: String?
}

public struct TCPViewSessionClientStore: Codable, Equatable {
    public let clients: [TCPViewSessionClientRecord]

    public init(clients: [TCPViewSessionClientRecord]) {
        self.clients = clients
    }
}

public struct TCPViewSessionPacketAnnotation: Codable, Equatable {
    public let packetID: PacketSummary.ID
    public let packetComment: String?
    public let customComment: String?
    public let colorHex: String?
    public let textStyle: PacketTextStyle?

    public init(
        packetID: PacketSummary.ID,
        packetComment: String?,
        customComment: String?,
        colorHex: String?,
        textStyle: PacketTextStyle? = nil
    ) {
        self.packetID = packetID
        self.packetComment = packetComment
        self.customComment = customComment
        self.colorHex = colorHex
        self.textStyle = textStyle
    }
}

public struct TCPViewSessionAnnotations: Codable, Equatable {
    public let annotations: [TCPViewSessionPacketAnnotation]

    public init(annotations: [TCPViewSessionPacketAnnotation]) {
        self.annotations = annotations
    }
}

public struct TCPViewSessionSourceMetadata: Codable, Equatable {
    public let fileName: String?
    public let filePath: String?
    public let format: String?
    public let packetCount: Int

    public init(fileName: String?, filePath: String?, format: String?, packetCount: Int) {
        self.fileName = fileName
        self.filePath = filePath
        self.format = format
        self.packetCount = packetCount
    }
}

/// Workspace state restored by upstream's session import (the daemon only
/// authors it — the app state round-trip is a later phase). Fields mirror
/// upstream TCPViewSessionState so the macOS app can read our files.
public struct TCPViewSessionState: Codable, Equatable {
    public let source: String?
    public let backingIdentity: String?
    public let importedFiles: [SessionImportedFileRecord]
    public let importedPacketReferences: [SessionImportedPacketReferenceRecord]
    public let pins: [SessionPinRecord]
    public let savedPackets: [SessionSavedPacketRecord]
    public let customFilters: [SessionCustomFilterRecord]
    public let quickFilterSelection: SessionQuickFilterSelection
    public let structuredFilterGroup: SessionStructuredFilterGroup
    public let displayFilterText: String
    public let sourceListFilterText: String
    public let selectedPacketID: PacketSummary.ID?
    public let selectedSourceListSelection: SessionSourceListSelectionRecord?
    public let workspaceMode: String
    public let inspectorTab: String
    public let inspectorPlacement: String
    public let isInspectorVisible: Bool
    public let isStructuredFilterVisible: Bool
    public var filterMode: String? = nil
    public var wiresharkExpression: String? = nil
    public let tableColumnLayout: SessionTableColumnLayout?
    public let importedFileProvenance: String?
    public let sourceMetadata: TCPViewSessionSourceMetadata?

    public init(sourceMetadata: TCPViewSessionSourceMetadata?) {
        self.source = "offline"
        self.backingIdentity = nil
        self.importedFiles = []
        self.importedPacketReferences = []
        self.pins = []
        self.savedPackets = []
        self.customFilters = []
        self.quickFilterSelection = SessionQuickFilterSelection()
        self.structuredFilterGroup = SessionStructuredFilterGroup()
        self.displayFilterText = ""
        self.sourceListFilterText = ""
        self.selectedPacketID = nil
        self.selectedSourceListSelection = nil
        self.workspaceMode = "packets"
        self.inspectorTab = "summary"
        self.inspectorPlacement = "trailing"
        self.isInspectorVisible = true
        self.isStructuredFilterVisible = false
        self.tableColumnLayout = nil
        self.importedFileProvenance = nil
        self.sourceMetadata = sourceMetadata
    }
}

/// `{selectedIDs: [...]}` (upstream PacketQuickFilterSelection; Set encodes
/// as an array).
public struct SessionQuickFilterSelection: Codable, Equatable {
    public let selectedIDs: [String]

    public init(selectedIDs: [String] = ["all"]) {
        self.selectedIDs = selectedIDs
    }
}

/// Upstream PacketStructuredFilterGroup with its default single empty row.
public struct SessionStructuredFilterGroup: Codable, Equatable {
    public struct Row: Codable, Equatable {
        public let id: String
        public var query: String
        public var condition: String
        public var text: String
        public var isEnabled: Bool

        public init() {
            self.id = UUID().uuidString
            self.query = "anyText"
            self.condition = "contains"
            self.text = ""
            self.isEnabled = true
        }
    }

    public var filters: [Row]
    public var `operator`: String

    public init(filters: [Row]? = nil, `operator`: String = "and") {
        self.filters = filters ?? [Row()]
        self.operator = `operator`
    }
}

public struct SessionSourceListSelectionRecord: Codable, Equatable {
    public let kind: String
    public let values: [String]

    public init(kind: String, values: [String]) {
        self.kind = kind
        self.values = values
    }
}

/// Empty sidecar records: the daemon authors empty arrays until the state
/// round-trip phase lands; empty arrays decode identically upstream.
public struct SessionImportedFileRecord: Codable, Equatable {
    public init() {}
}

public struct SessionImportedPacketReferenceRecord: Codable, Equatable {
    public init() {}
}

public struct SessionPinRecord: Codable, Equatable {
    public init() {}
}

public struct SessionSavedPacketRecord: Codable, Equatable {
    public init() {}
}

public struct SessionCustomFilterRecord: Codable, Equatable {
    public init() {}
}

/// Placeholder so optional column-layout sidecars stay parseable; the daemon
/// never authors one (null).
public struct SessionTableColumnLayout: Codable, Equatable {
    public init() {}
}

// MARK: - Codec

public enum TCPViewSessionCodec {
    public static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    public static func decodePacketRecords(from data: Data) throws -> (records: [TCPViewSessionPacketRecord], failedLineCount: Int) {
        guard let payload = String(data: data, encoding: .utf8) else {
            throw SessionPackageError("The packet sidecar is not valid UTF-8.")
        }

        var records: [TCPViewSessionPacketRecord] = []
        var failedLineCount = 0
        for line in payload.split(separator: "\n", omittingEmptySubsequences: true) {
            do {
                records.append(try decodeJSON(TCPViewSessionPacketRecord.self, from: Data(line.utf8)))
            } catch {
                failedLineCount += 1
            }
        }
        return (records, failedLineCount)
    }
}

public struct SessionPackageError: Error, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

// MARK: - Client store builder (upstream parity; the daemon has no clients)

public enum TCPViewSessionClientStoreBuilder {
    public static func buildClientStore(
        packets: [PacketSummary]
    ) -> (records: [TCPViewSessionPacketRecord], clients: TCPViewSessionClientStore) {
        var packetRecords: [TCPViewSessionPacketRecord] = []
        packetRecords.reserveCapacity(packets.count)

        for (ordinal, packet) in packets.enumerated() {
            packetRecords.append(TCPViewSessionPacketRecord(
                packetID: packet.id,
                captureOrdinal: ordinal,
                clientID: nil,
                packet: packet.tcpviewSessionPacketWithoutClient()
            ))
        }

        return (packetRecords, TCPViewSessionClientStore(clients: []))
    }

    public static func rehydratePackets(
        records: [TCPViewSessionPacketRecord],
        clients: TCPViewSessionClientStore
    ) -> [PacketSummary] {
        let clientByID = Dictionary(
            clients.clients.map { ($0.id, $0.client) },
            uniquingKeysWith: { existing, _ in existing }
        )
        return records
            .sorted { $0.captureOrdinal < $1.captureOrdinal }
            .map { record in
                let client = record.clientID.flatMap { clientByID[$0] }
                return record.packet.tcpviewSessionPacketWithClient(client)
            }
    }
}

extension PacketSummary {
    /// The sidecar record stores the summary without client assignment.
    public func tcpviewSessionPacketWithoutClient() -> PacketSummary {
        tcpviewSessionPacketWithClient(nil)
    }

    public func tcpviewSessionPacketWithClient(_ client: PacketClient?) -> PacketSummary {
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
