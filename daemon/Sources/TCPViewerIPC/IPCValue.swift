//
//  IPCValue.swift
//  Omarchy TCPViewer
//
//  JSON value type for the schema_version 1 wire format.
//  Ported verbatim from upstream TCPViewerCLIShared/TCPViewerCLIModels.swift
//  (TCP Viewer, Proxyman LLC, GPL-2.0-or-later) — see ../NOTICE.
//

import Foundation

public enum IPCValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([IPCValue])
    case object([String: IPCValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([IPCValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: IPCValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported IPC JSON value."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .double(let value) where value.isFinite && value.rounded() == value:
            return Int(exactly: value)
        default:
            return nil
        }
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [IPCValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var objectValue: [String: IPCValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}

extension IPCValue {
    // Keep filter input lexical because the app applies numeric conversion only for numeric operators.
    public static func lexicalFilterValue(_ value: String) -> IPCValue {
        .string(value)
    }
}
