//
//  IPCFraming.swift
//  Omarchy TCPViewer
//
//  Line framing + validation for the Unix-socket JSON transport.
//  One JSON object per line. All inbound bytes are untrusted: size caps,
//  bracket-depth pre-scan (before Foundation's decoder can recurse),
//  schema/command/request-id validation happen here.
//

import Foundation

public enum IPCCodec {
    // Deterministic output (sorted keys) keeps tests and log diffs stable.
    // Dates: fractional ISO 8601 (millisecond precision must round-trip for
    // Equatable/staleness checks); decoding accepts fractional AND plain.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            if let date = ISO8601DateFormatter().date(from: text) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid ISO 8601 timestamp"
            )
        }
        return decoder
    }

    // MARK: - Encode

    /// Encodes any message as one newline-terminated line, bounded by `limit`.
    public static func encodeLine<T: Encodable>(_ value: T, limit: Int) throws -> Data {
        var line = try makeEncoder().encode(value)
        guard line.count <= limit else {
            throw IPCFramingError.lineTooLarge(line.count)
        }
        line.append(0x0A)
        return line
    }

    // MARK: - Decode (inbound = untrusted)

    /// Decodes and validates one request line. Throws `IPCFramingError`
    /// with a wire error code; the server maps it to a failure response.
    public static func decodeRequest(line: Data) throws -> IPCRequest {
        let raw = stripNewline(line)
        guard raw.count <= IPCLimits.maxRequestBytes else {
            throw IPCFramingError.lineTooLarge(raw.count)
        }
        guard !raw.isEmpty else {
            throw IPCFramingError.malformed("empty line")
        }
        // Pre-scan bracket depth before any recursive parsing.
        guard let depth = maxBracketDepth(raw), depth <= maxNestingDepth else {
            throw IPCFramingError.tooDeeplyNested
        }

        // Decode with `command` as a plain string so unknown commands can be
        // rejected as unknown_command instead of a generic decode failure.
        struct RawRequest: Decodable {
            let schemaVersion: Int?
            let requestID: String?
            let command: String?
            let params: [String: IPCValue]?
            let createdAt: Date?
            let expiresAt: Date?

            enum CodingKeys: String, CodingKey {
                case schemaVersion = "schema_version"
                case requestID = "request_id"
                case command
                case params
                case createdAt = "created_at"
                case expiresAt = "expires_at"
            }
        }

        let rawRequest: RawRequest
        do {
            rawRequest = try makeDecoder().decode(RawRequest.self, from: raw)
        } catch {
            throw IPCFramingError.malformed(String(describing: error))
        }

        guard rawRequest.schemaVersion == IPCRequest.schemaVersion else {
            throw IPCFramingError.unsupportedSchema(rawRequest.schemaVersion ?? -1)
        }
        guard let requestID = rawRequest.requestID, IPCRequest.isValidRequestID(requestID) else {
            throw IPCFramingError.invalidRequestID
        }
        guard let commandName = rawRequest.command else {
            throw IPCFramingError.malformed("missing command")
        }
        guard let command = IPCCommand(rawValue: commandName) else {
            throw IPCFramingError.unknownCommand(commandName)
        }

        return IPCRequest(
            requestID: requestID,
            command: command,
            params: rawRequest.params ?? [:],
            createdAt: rawRequest.createdAt ?? Date(),
            expiresAt: rawRequest.expiresAt
        )
    }

    /// Decodes a server line (CLI/GUI side). Returns either response or event.
    public static func decodeServerLine(line: Data) throws -> ServerMessage {
        let raw = stripNewline(line)
        guard raw.count <= IPCLimits.maxResponseBytes else {
            throw IPCFramingError.lineTooLarge(raw.count)
        }
        guard let depth = maxBracketDepth(raw), depth <= maxNestingDepth else {
            throw IPCFramingError.tooDeeplyNested
        }

        struct Envelope: Decodable {
            let ok: Bool?
            let event: String?
        }
        guard let envelope = try? makeDecoder().decode(Envelope.self, from: raw) else {
            throw IPCFramingError.malformed("unrecognized server line")
        }
        if envelope.ok != nil {
            return .response(try makeDecoder().decode(IPCResponse.self, from: raw))
        }
        if let event = envelope.event {
            struct DecodedEvent: Decodable {
                let schemaVersion: Int?
                let event: String
                let data: [String: IPCValue]
                enum CodingKeys: String, CodingKey {
                    case schemaVersion = "schema_version"
                    case event
                    case data
                }
            }
            let decoded = try makeDecoder().decode(DecodedEvent.self, from: raw)
            guard decoded.schemaVersion == IPCResponse.schemaVersion else {
                throw IPCFramingError.unsupportedSchema(decoded.schemaVersion ?? -1)
            }
            return .event(name: decoded.event, data: decoded.data)
        }
        throw IPCFramingError.malformed("line is neither response nor event")
    }

    /// Returns true when the request's optional expiry has passed.
    public static func isExpired(_ request: IPCRequest, now: Date = Date()) -> Bool {
        guard let expiresAt = request.expiresAt else { return false }
        return expiresAt < now
    }

    // MARK: - Helpers

    public static let maxNestingDepth = 64

    public enum ServerMessage {
        case response(IPCResponse)
        case event(name: String, data: [String: IPCValue])
    }

    private static func stripNewline(_ data: Data) -> Data {
        var result = data
        if result.last == 0x0A { result.removeLast() }
        if result.last == 0x0D { result.removeLast() }
        return result
    }

    /// Max bracket nesting over the raw bytes (string-aware: brackets inside
    /// quoted strings don't count). Bounds decoder recursion cheaply.
    private static func maxBracketDepth(_ data: Data) -> Int? {
        var depth = 0
        var maxDepth = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {  // backslash
                    escaped = true
                } else if byte == 0x22 {  // closing quote
                    inString = false
                }
                continue
            }
            switch byte {
            case 0x22: inString = true          // opening quote
            case 0x7B, 0x5B: depth += 1         // { [
                maxDepth = max(maxDepth, depth)
                if depth > maxNestingDepth { return maxDepth }
            case 0x7D, 0x5D: depth -= 1         // } ]
                if depth < 0 { return nil }     // malformed; let decoder report
            default: break
            }
        }
        return maxDepth
    }
}

/// Framing/validation failure carrying a wire error code + message.
public struct IPCFramingError: Error {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public static func lineTooLarge(_ size: Int) -> IPCFramingError {
        IPCFramingError(code: IPCError.invalidRequest, message: "line exceeds \(size) bytes")
    }

    public static let tooDeeplyNested = IPCFramingError(
        code: IPCError.invalidRequest,
        message: "JSON nesting exceeds \(IPCCodec.maxNestingDepth) levels"
    )

    public static let invalidRequestID = IPCFramingError(
        code: IPCError.invalidRequest,
        message: "request_id missing, too long, or contains invalid characters"
    )

    public static func unsupportedSchema(_ version: Int) -> IPCFramingError {
        IPCFramingError(
            code: IPCError.unsupportedSchema,
            message: "schema_version \(version) not supported (want 1)"
        )
    }

    public static func unknownCommand(_ name: String) -> IPCFramingError {
        // Bound the echoed name — it comes from untrusted input.
        let bounded = String(name.prefix(IPCLimits.maxRequestIDLength))
        return IPCFramingError(code: IPCError.unknownCommand, message: "unknown command: \(bounded)")
    }

    public static func malformed(_ detail: String) -> IPCFramingError {
        IPCFramingError(code: IPCError.invalidRequest, message: "malformed request: \(String(detail.prefix(200)))")
    }
}
