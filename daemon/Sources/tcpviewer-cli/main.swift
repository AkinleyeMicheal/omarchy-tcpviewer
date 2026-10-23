//
//  main.swift
//  tcpviewer-cli
//
//  Thin CLI for Omarchy TCPViewer over the schema_version 1 Unix-socket
//  JSON protocol. Links NO Wireshark/capture libraries. Command syntax and
//  exit codes mirror upstream CLI.md: <group> <verb> [--key value ...],
//  exit 0 = success, 2 = usage/validation, 3 = transport, 4 = daemon error.
//

import Foundation
import TCPViewerIPC
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Argument parsing

struct CLIArguments {
    var commandPath: [String] = []
    var flags: [String: String] = [:]
    var positionals: [String] = []
    var outputPretty = false
    var outputText = false
    var timeoutSeconds: Double = 30
    var socketPath: String? = nil
    var printEvents = false
}

// Commands whose group verb form uses two words; everything else one word.
let twoWordCommands: Set<String> = [
    "capture.start", "capture.pause", "capture.resume", "capture.stop", "capture.status",
    "interfaces.list", "sources.list", "source.close",
    "packets.list", "packets.summary", "packets.details", "packets.bytes", "packets.clear",
    "stream.packets", "stream.follow",
    "file.import", "file.export", "file.export_session",
    "app.status",
]

// Positional argument mapping for upstream's "COMMAND ID" forms.
let positionalKeys: [String: [String]] = [
    "packets.details": ["packet_id"],
    "packets.bytes": ["packet_id"],
    "stream.packets": ["stream_id"],
    "stream.follow": ["packet_id"],
    "file.export": ["path"],
    "file.export_session": ["path"],
    "source.close": ["source_id"],
]

// Long operations inherit upstream's 300 s timeout (import/export/follow).
let longRunningCommands: Set<String> = ["file.import", "file.export", "file.export_session", "stream.follow"]

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func usage() -> Never {
    let text = """
    usage: tcpviewer-cli <command> [--key value ...] [options]

    commands (group verb or dotted):
      app status | interfaces list
      capture status | capture start --interface IFACE [--bpf EXPR]
      capture pause | capture resume | capture stop [--source-id ID]
      sources list | source close SOURCE_ID
      packets list [QUERY OPTIONS] | packets summary [QUERY OPTIONS]
      packets details PACKET_ID [--max-depth N] [--max-nodes N]
      packets bytes PACKET_ID [--offset N] [--length N] [--encoding hex|base64]
      packets clear --yes
      stream packets STREAM_ID [QUERY OPTIONS]
      stream follow PACKET_ID [--direction both|client-to-server|server-to-client]
                             [--encoding text|hex|base64]
      file import PATH... | file export PATH --format pcap|pcapng SELECTOR [--overwrite]
      file export_session PATH [--overwrite]

    options:
      --output json|text   default json (schema_version 1)
      --pretty             pretty-print JSON
      --timeout SECONDS    default 30 (300 for import/export/follow)
      --socket PATH        override daemon socket (default $XDG_RUNTIME_DIR)
      --events             print capture events while waiting for the reply

    exit codes: 0 success, 2 usage/validation, 3 transport, 4 daemon error
    """
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(2)
}

func parseArguments() -> CLIArguments {
    var args = CLIArguments()
    var iterator = Array(CommandLine.arguments.dropFirst())
    if iterator.first == "--help" || iterator.first == "-h" { usage() }

    // First segment: the command. Accept both "capture start" and "capture.start".
    guard let first = iterator.first, !first.hasPrefix("--") else {
        FileHandle.standardError.write(Data("missing command (try --help)\n".utf8))
        exit(2)
    }
    iterator.removeFirst()
    var commandPath = [first]

    // Two-word form: second token is a bare verb, not a flag/value.
    if let second = iterator.first, !second.hasPrefix("--"),
        twoWordCommands.contains((commandPath + [second]).joined(separator: ".")) {
        commandPath.append(second)
        iterator.removeFirst()
    }
    args.commandPath = commandPath

    var i = 0
    while i < iterator.count {
        let token = iterator[i]
        defer { i += 1 }
        if token == "--pretty" {
            args.outputPretty = true
        } else if token == "--events" {
            args.printEvents = true
        } else if token.hasPrefix("--") {
            let key = String(token.dropFirst(2))
            // Boolean shorthand: --flag (no value) or --flag value
            guard i + 1 < iterator.count else {
                args.flags[key] = "true"
                continue
            }
            let next = iterator[i + 1]
            if next.hasPrefix("--") {
                args.flags[key] = "true"
            } else {
                args.flags[key] = next
                i += 1
            }
        } else {
            args.positionals.append(token)
        }
    }

    if let output = args.flags["output"] {
        guard output == "json" || output == "text" else {
            fail("--output must be json or text", code: 2)
        }
        args.outputText = output == "text"
        args.flags.removeValue(forKey: "output")
    }
    if let timeout = args.flags["timeout"], let seconds = Double(timeout), seconds > 0 {
        args.timeoutSeconds = seconds
        args.flags.removeValue(forKey: "timeout")
    }
    if let socket = args.flags["socket"] {
        args.socketPath = socket
        args.flags.removeValue(forKey: "socket")
    }
    return args
}

// MARK: - Wire value typing

/// Infer JSON types from CLI text the way a thin client should: integers as
/// ints, true/false as bools, everything else strings (daemon coerces per
/// command, matching upstream's lexical filter rule).
func wireValue(_ text: String) -> IPCValue {
    if text == "true" { return .bool(true) }
    if text == "false" { return .bool(false) }
    if text == "null" { return .null }
    if let int = Int(text) { return .int(int) }
    if let double = Double(text), double.isFinite, !text.contains("e") { return .double(double) }
    // Comma-separated list helper: --quick-filters tcp,dns
    if text.contains(",") && !text.contains(" ") {
        let parts = text.split(separator: ",").map(String.init)
        if parts.allSatisfy({ Int($0) != nil || $0 == "true" || $0 == "false" || !$0.isEmpty }) {
            return .array(parts.map { wireValue($0) })
        }
    }
    return .string(text)
}

func buildRequest(args: CLIArguments) -> IPCRequest {
    guard let command = IPCCommand(rawValue: args.commandPath.joined(separator: ".")) else {
        fail("unknown command: \(args.commandPath.joined(separator: " ")) (try --help)", code: 2)
    }

    var params: [String: IPCValue] = [:]

    // Positionals in declared order (upstream "COMMAND ID" forms).
    if let keys = positionalKeys[command.rawValue] {
        guard args.positionals.count >= keys.count else {
            fail("missing argument: \(keys.last!.replacingOccurrences(of: "_", with: " "))", code: 2)
        }
        for (index, key) in keys.enumerated() {
            params[key] = .string(args.positionals[index])
        }
        if args.positionals.count > keys.count {
            fail("too many arguments for \(command.rawValue)", code: 2)
        }
    } else if !args.positionals.isEmpty {
        if command == .fileImport {
            params["paths"] = .array(args.positionals.map { .string($0) })
        } else {
            fail("unexpected argument: \(args.positionals[0])", code: 2)
        }
    }

    for (key, raw) in args.flags {
        params[key.replacingOccurrences(of: "-", with: "_")] = wireValue(raw)
    }

    let timeout = longRunningCommands.contains(command.rawValue) ? max(args.timeoutSeconds, 300) : args.timeoutSeconds
    return IPCRequest(command: command, params: params, expiresAt: Date(timeIntervalSinceNow: timeout))
}

// MARK: - Socket transport

func defaultSocketPath() -> String {
    // Per-user runtime dir only — never a world-writable fallback like /tmp.
    guard let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] else {
        fail("XDG_RUNTIME_DIR is not set; is this an Omarchy user session?", code: 3)
    }
    return "\(runtime)/omarchy-tcpviewer/tcpviewerd.sock"
}

func connectSocket(path: String) -> Int32 {
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    guard fd >= 0 else { fail("socket(): \(String(cString: strerror(errno)))", code: 3) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        fail("socket path too long: \(path)", code: 3)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        for (index, byte) in bytes.enumerated() {
            buffer[index] = byte
        }
    }

    let connectResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else {
        fail("cannot connect to \(path): \(String(cString: strerror(errno))) (is tcpviewerd running?)", code: 3)
    }
    return fd
}

/// Blocking line reader over the socket; returns nil on EOF.
func readLine(fd: Int32, buffer: inout Data) -> Data? {
    var line = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        if let newlineIndex = buffer.firstIndex(of: 0x0A) {
            line.append(buffer[buffer.startIndex..<newlineIndex])
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            return line
        }
        line.append(buffer)
        buffer.removeAll(keepingCapacity: true)
        let count = read(fd, &chunk, chunk.count)
        if count <= 0 { return nil }
        buffer.append(contentsOf: chunk[0..<count])
    }
}

// MARK: - Output

/// Fixed-width text rendering for the query-friendly commands. Returns ""
/// when no renderer exists — caller falls back to JSON (script-safe).
func renderText(command: String, data: [String: IPCValue]) -> String {
    switch command {
    case "interfaces.list":
        guard let rows = data["interfaces"]?.arrayValue else { return "" }
        var out = pad("ID", 14) + pad("ROLE", 12) + pad("STATE", 11) + "ADDRESSES"
        for row in rows {
            guard let obj = row.objectValue else { continue }
            let id = displaySafe(obj["id"]?.stringValue ?? "")
            let role = displaySafe(obj["display_name"]?.stringValue ?? "")
            let state = displaySafe(obj["availability"]?.stringValue ?? "")
            let addresses = (obj["addresses"]?.arrayValue ?? [])
                .compactMap { $0.objectValue?["value"]?.stringValue ?? $0.stringValue }
                .map(displaySafe)
                .joined(separator: ", ")
            out += "\n" + pad(id, 14) + pad(role, 12) + pad(state, 11) + addresses
        }
        return out
    case "packets.list", "packets.summary":
        guard let rows = (data["packets"] ?? data["summaries"])?.arrayValue else { return "" }
        var out = pad("NO", 8) + pad("TIME", 14) + pad("SOURCE", 24) + pad("DESTINATION", 24)
            + pad("PROTO", 8) + pad("LEN", 6) + "INFO"
        for row in rows {
            guard let obj = row.objectValue else { continue }
            out += "\n"
                + pad(obj["packet_id"]?.stringValue ?? "", 8)
                + pad(formatTimestamp(obj["timestamp"]?.stringValue), 14)
                + pad(displaySafe(formatEndpoint(obj["source"])), 24)
                + pad(displaySafe(formatEndpoint(obj["destination"])), 24)
                + pad(displaySafe(obj["protocol"]?.stringValue ?? ""), 8)
                + pad(scalarText(obj["length"]), 6)
                + displaySafe(obj["info"]?.stringValue ?? "")
        }
        return out
    default:
        return ""
    }
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
}

/// Int-or-string column value (daemon sends numbers as .int, not .string).
func scalarText(_ value: IPCValue?) -> String {
    switch value {
    case .string(let text): return text
    case .int(let number): return String(number)
    case .double(let number): return String(number)
    default: return ""
    }
}

/// ISO 8601 → local HH:MM:SS.mmm for compact rows.
func formatTimestamp(_ iso: String?) -> String {
    guard let iso else { return "" }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else {
        return String(iso.suffix(12))
    }
    let display = DateFormatter()
    display.dateFormat = "HH:mm:ss.SSS"
    return display.string(from: date)
}

/// Render daemon/capture strings safely for a terminal: strip control and
/// bidirectional formatting scalars so malicious packet data cannot emit
/// terminal escape sequences or spoof the layout.
func displaySafe(_ value: String) -> String {
    var out = String()
    out.reserveCapacity(value.count)
    for scalar in value.unicodeScalars {
        if scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format {
            out.append("\u{00B7}")
        } else {
            out.unicodeScalars.append(scalar)
        }
    }
    return out
}

func formatEndpoint(_ value: IPCValue?) -> String {
    guard let obj = value?.objectValue else { return value?.stringValue ?? "" }
    let address = obj["address"]?.stringValue ?? ""
    guard let port = obj["port"]?.intValue else { return address }
    return "[\(address)]:\(port)"
}

// MARK: - Main

func run() -> Never {
    let args = parseArguments()
    let request = buildRequest(args: args)
    let socketPath = args.socketPath ?? defaultSocketPath()

    guard let line = try? IPCCodec.encodeLine(request, limit: IPCLimits.maxRequestBytes) else {
        fail("failed to encode request", code: 2)
    }

    let fd = connectSocket(path: socketPath)
    defer { close(fd) }

    // Bound the whole exchange by the request's own timeout.
    var timeout = timeval(
        tv_sec: Int(args.timeoutSeconds),
        tv_usec: 0
    )
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    line.withUnsafeBytes { raw in
        _ = write(fd, raw.baseAddress!, raw.count)
    }

    var readBuffer = Data()
    while let responseLine = readLine(fd: fd, buffer: &readBuffer) {
        guard !responseLine.isEmpty else { continue }
        switch (try? IPCCodec.decodeServerLine(line: responseLine)) {
        case .response(let response):
            guard response.requestID == request.requestID else { continue }  // stale line
            emit(response: response, args: args)
        case .event(let name, let data):
            if args.printEvents {
                let message = IPCEventMessage(event: IPCEvent(rawValue: name) ?? .captureHealth, data: data)
                if let bytes = try? IPCCodec.encodeLine(message, limit: IPCLimits.maxResponseBytes) {
                    FileHandle.standardOutput.write(bytes)
                }
            }
        case nil:
            fail("daemon sent a malformed line", code: 3)
        }
    }
    // EOF without a matching response = transport failure (3), covering
    // SO_RCVTIMEO timeouts (read returned 0/-1).
    fail("no response from daemon (transport closed or timed out)", code: 3)
}

func emit(response: IPCResponse, args: CLIArguments) -> Never {
    if response.ok {
        let data = response.data ?? [:]
        if args.outputText {
            let text = renderText(command: response.command, data: data)
            if !text.isEmpty {
                FileHandle.standardOutput.write(Data((text + "\n").utf8))
                exit(0)
            }
            // Fall through to JSON when no text renderer exists (honest: the
            // data is what matters for scripting).
        }
        if let bytes = try? IPCCodec.encodeLine(response, limit: IPCLimits.maxResponseBytes) {
            FileHandle.standardOutput.write(args.outputPretty ? prettyLine(bytes) : bytes)
            exit(0)
        }
        fail("failed to encode response", code: 4)
    } else {
        let envelope: [String: IPCValue] = [
            "schema_version": .int(response.schemaVersion),
            "request_id": .string(response.requestID),
            "ok": .bool(false),
            "command": .string(response.command),
            "error": .object([
                "code": .string(response.error?.code ?? "unknown"),
                "message": .string(response.error?.message ?? "unknown error"),
            ]),
        ]
        var bytes = (try? IPCCodec.encodeLine(envelope, limit: IPCLimits.maxResponseBytes)) ?? Data()
        FileHandle.standardError.write(args.outputPretty ? prettyLine(bytes) : bytes)
        exit(4)
    }
}

/// Re-pretty a single-line JSON object.
func prettyLine(_ line: Data) -> Data {
    var trimmed = line
    if trimmed.last == 0x0A { trimmed.removeLast() }
    guard let object = try? JSONSerialization.jsonObject(with: trimmed),
        let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    else {
        return line
    }
    return pretty + Data("\n".utf8)
}

run()
