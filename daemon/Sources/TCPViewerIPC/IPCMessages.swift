//
//  IPCMessages.swift
//  Omarchy TCPViewer
//
//  schema_version 1 request/response/event envelopes over a Unix domain
//  socket, one JSON object per line (UTF-8, newline-delimited).
//  The success/failure envelopes are byte-compatible with the upstream
//  CLI.md JSON contract; request envelope matches upstream's
//  TCPViewerCLIRequest (ISO 8601 timestamps per schema rules).
//

import Foundation

public enum IPCError {
    // Stable wire error codes (lowercase snake_case, like upstream).
    public static let invalidRequest = "invalid_request"
    public static let unsupportedSchema = "unsupported_schema"
    public static let unknownCommand = "unknown_command"
    public static let unsupportedCommand = "unsupported_command"
    public static let invalidParams = "invalid_params"
    public static let notFound = "not_found"
    public static let captureFailed = "capture_failed"
    public static let permissionDenied = "permission_denied"
    public static let busy = "busy"
    public static let ioError = "io_error"
    public static let timeout = "timeout"
    public static let appCommandFailed = "app_command_failed"
    public static let operationCancelled = "operation_cancelled"
}

public enum IPCLimits {
    // Inbound lines are attacker-relevant: bound them hard. Responses are
    // built from bounded batches (CLI.md: 5000-row pages, 4 MiB follows).
    public static let maxRequestBytes = 1_048_576        // 1 MiB
    public static let maxResponseBytes = 16_777_216      // 16 MiB
    public static let maxRequestIDLength = 64
    public static let requestIDAllowedCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
}

public struct IPCRequest: Codable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let requestID: String
    public let command: IPCCommand
    public let params: [String: IPCValue]
    public let createdAt: Date?
    public let expiresAt: Date?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case command
        case params
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }

    public init(
        requestID: String = UUID().uuidString.lowercased(),
        command: IPCCommand,
        params: [String: IPCValue] = [:],
        createdAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.requestID = requestID
        self.command = command
        self.params = params
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    public func value(_ key: String) -> IPCValue? { params[key] }
    public func string(_ key: String) -> String? { params[key]?.stringValue }
    public func int(_ key: String) -> Int? { params[key]?.intValue }
    public func bool(_ key: String) -> Bool? { params[key]?.boolValue }
    public func array(_ key: String) -> [IPCValue]? { params[key]?.arrayValue }

    /// Present and not JSON null — distinguishes `"color": null` (clear) from
    /// an absent key (leave alone). Runs entirely client-side here.
    public func hasValue(_ key: String) -> Bool {
        guard let value = params[key] else { return false }
        if case .null = value { return false }
        return true
    }

    /// Security: request IDs are echoed back and logged — validate shape.
    public static func isValidRequestID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= IPCLimits.maxRequestIDLength else { return false }
        return id.unicodeScalars.allSatisfy { IPCLimits.requestIDAllowedCharacters.contains($0) }
    }
}

public struct IPCErrorPayload: Codable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct IPCResponse: Codable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let requestID: String
    public let ok: Bool
    public let command: String
    public let data: [String: IPCValue]?
    public let error: IPCErrorPayload?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case ok
        case command
        case data
        case error
    }

    public static func success(requestID: String, command: String, data: [String: IPCValue]) -> IPCResponse {
        IPCResponse(
            schemaVersion: schemaVersion,
            requestID: requestID,
            ok: true,
            command: command,
            data: data,
            error: nil
        )
    }

    public static func failure(
        requestID: String,
        command: String,
        code: String,
        message: String,
        data: [String: IPCValue]? = nil
    ) -> IPCResponse {
        IPCResponse(
            schemaVersion: schemaVersion,
            requestID: requestID,
            ok: false,
            command: command,
            data: data,
            error: IPCErrorPayload(code: code, message: message)
        )
    }
}

/// Server-initiated notification. Not a response: has `event`, no `ok`.
public struct IPCEventMessage: Codable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let event: String
    public let data: [String: IPCValue]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case event
        case data
    }

    public init(event: IPCEvent, data: [String: IPCValue]) {
        self.schemaVersion = Self.schemaVersion
        self.event = event.rawValue
        self.data = data
    }
}
