//
//  ZIPArchive.swift
//  TCPViewerSession
//
//  Minimal ZIP reader/writer over the system zlib, standing in for upstream's
//  ZIPFoundation dependency. The reader accepts stored (0) and deflate (8)
//  entries and requires the central directory to carry the real sizes; the
//  writer deflates file payloads and emits directory entries. Deliberately
//  narrow: no ZIP64, no encryption, no data descriptors, no streaming.
//

import Foundation
import CZlib
import PcapPlusPlusCore

// MARK: - Types

enum ZIPSignatures {
    static let localHeader: UInt32 = 0x04034b50
    static let centralHeader: UInt32 = 0x02014b50
    static let endOfCentralDirectory: UInt32 = 0x06054b50
}

struct ZIPEntry {
    let path: String
    let method: UInt16
    let crc: UInt32
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
    let isDirectory: Bool
    let isSymlink: Bool
}

enum ZIPError: Error, CustomStringConvertible {
    case notAnArchive
    case corrupted(String)
    case unsafePath(String)

    var description: String {
        switch self {
        case .notAnArchive: "The TCPViewer session file is not a readable ZIP archive."
        case .corrupted(let detail): "The TCPViewer session archive is corrupt: \(detail)"
        case .unsafePath(let path): "The TCPViewer session package contains an unsafe path: \(path)"
        }
    }
}

// MARK: - Reader

enum ZIPArchiveReader {
    static func readDirectory(_ data: Data) throws -> [ZIPEntry] {
        let eocd = try locateEOCD(in: data)
        guard let entryCount = readU16(data, eocd + 10),
              let centralSize = readU32(data, eocd + 12),
              let centralOffset = readU32(data, eocd + 16) else {
            throw ZIPError.corrupted("end-of-central-directory record")
        }

        var entries: [ZIPEntry] = []
        var cursor = Int(centralOffset)
        let end = cursor + Int(centralSize)
        for _ in 0..<Int(entryCount) {
            guard cursor + 46 <= min(end, data.count),
                  readU32(data, cursor) == ZIPSignatures.centralHeader else {
                throw ZIPError.corrupted("central directory entry")
            }

            let method = readU16(data, cursor + 10) ?? 0
            let crc = readU32(data, cursor + 16) ?? 0
            let compressedSize = Int(readU32(data, cursor + 20) ?? 0)
            let uncompressedSize = Int(readU32(data, cursor + 24) ?? 0)
            let nameLength = Int(readU16(data, cursor + 28) ?? 0)
            let extraLength = Int(readU16(data, cursor + 30) ?? 0)
            let commentLength = Int(readU16(data, cursor + 32) ?? 0)
            let externalAttrs = readU32(data, cursor + 38) ?? 0
            let localOffset = Int(readU32(data, cursor + 42) ?? 0)

            guard let name = readString(data, cursor + 46, nameLength) else {
                throw ZIPError.corrupted("central directory entry name")
            }

            // Unix mode is stored in the high 16 bits of the external attrs.
            let mode = (externalAttrs >> 16) & 0xFFFF
            entries.append(ZIPEntry(
                path: name,
                method: method,
                crc: crc,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localOffset,
                isDirectory: name.hasSuffix("/"),
                isSymlink: mode == 0o120777 || (mode & 0o170000) == 0o120000
            ))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Extracts one entry's payload (stored or raw-deflate).
    static func readFile(_ entry: ZIPEntry, from data: Data) throws -> Data {
        let base = entry.localHeaderOffset
        guard readU32(data, base) == ZIPSignatures.localHeader else {
            throw ZIPError.corrupted("local file header for \(entry.path)")
        }
        let nameLength = Int(readU16(data, base + 26) ?? 0)
        let extraLength = Int(readU16(data, base + 28) ?? 0)
        let start = base + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard start >= 0, end <= data.count else {
            throw ZIPError.corrupted("payload bounds for \(entry.path)")
        }

        let payload = data.subdata(in: start..<end)
        let output: Data
        switch entry.method {
        case 0:
            output = payload
        case ZIPArchiveWriter.deflateMethod:
            output = try inflateRaw(payload, outputSize: entry.uncompressedSize, path: entry.path)
        default:
            throw ZIPError.corrupted("unsupported compression method \(entry.method) for \(entry.path)")
        }

        guard output.count == entry.uncompressedSize,
              crc32Of(output) == entry.crc else {
            throw ZIPError.corrupted("checksum mismatch for \(entry.path)")
        }
        return output
    }

    /// Raw-deflate inflate with a known output size (single pass).
    private static func inflateRaw(_ input: Data, outputSize: Int, path: String) throws -> Data {
        guard outputSize >= 0, outputSize <= maxPackageFileSize else {
            throw ZIPError.corrupted("uncompressed size for \(path)")
        }

        var stream = z_stream()
        let initResult = inflateInit2_(&stream, -CInt(MAX_WBITS), ZLIB_VERSION, CInt(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else {
            throw ZIPError.corrupted("zlib init failure (\(initResult))")
        }
        defer { inflateEnd(&stream) }

        var output = Data(count: outputSize)
        var status: Int32 = Z_BUF_ERROR
        var produced = 0
        input.withUnsafeBytes { inputRaw in
            output.withUnsafeMutableBytes { outputRaw in
                let inputBase = inputRaw.bindMemory(to: Bytef.self).baseAddress
                let outputBase = outputRaw.bindMemory(to: Bytef.self).baseAddress
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBase)
                stream.avail_in = uInt(input.count)
                stream.next_out = outputBase
                stream.avail_out = uInt(outputSize)
                status = inflate(&stream, Z_FINISH)
                produced = outputSize - Int(stream.avail_out)
            }
        }

        guard status == Z_STREAM_END else {
            throw ZIPError.corrupted("inflate for \(path) (status \(status), produced \(produced))")
        }
        return output
    }

    private static func locateEOCD(in data: Data) throws -> Int {
        let minimumSize = 22
        guard data.count >= minimumSize else { throw ZIPError.notAnArchive }
        let scanFloor = max(0, data.count - minimumSize - 65_536)
        var index = data.count - minimumSize
        while index >= scanFloor {
            if readU32(data, index) == ZIPSignatures.endOfCentralDirectory {
                return index
            }
            index -= 1
        }
        throw ZIPError.notAnArchive
    }

    private static let maxPackageFileSize = 4 * 1024 * 1024 * 1024 - 1

    // Little-endian reads (byte-wise: no alignment requirement on the map).
    private static func readU32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        var value: UInt32 = 0
        for step in 0..<4 {
            value |= UInt32(data[data.startIndex + offset + step]) << (8 * step)
        }
        return value
    }

    private static func readU16(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[data.startIndex + offset])
            | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private static func readString(_ data: Data, _ offset: Int, _ length: Int) -> String? {
        guard length >= 0, offset + length <= data.count else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(length)
        for step in 0..<length {
            bytes.append(data[data.startIndex + offset + step])
        }
        return String(data: Data(bytes), encoding: .utf8)
    }
}

// MARK: - Writer

enum ZIPArchiveWriter {
    static let deflateMethod: UInt16 = 0x0008
    private static let storedMethod: UInt16 = 0

    struct Entry {
        let path: String
        let payload: Data

        init(path: String, payload: Data = Data()) {
            self.path = path
            self.payload = payload
        }

        var isDirectory: Bool { path.hasSuffix("/") }
    }

    /// Writes a classic (non-ZIP64) archive; file payloads are deflated.
    static func write(_ entries: [Entry], to url: URL) throws {
        var body = Data()
        var central = Data()

        for entry in entries {
            let name = Data(entry.path.utf8)
            let method = entry.isDirectory ? storedMethod : deflateMethod
            let crc: UInt32
            let uncompressedSize: Int
            let compressed: Data
            if entry.isDirectory {
                crc = 0
                uncompressedSize = 0
                compressed = Data()
            } else {
                crc = crc32Of(entry.payload)
                uncompressedSize = entry.payload.count
                compressed = try deflatePacket(entry.payload)
            }

            let localOffset = body.count
            body.append(localHeader(method: method, crc: crc, compressedSize: compressed.count,
                                    uncompressedSize: uncompressedSize, name: name))
            body.append(name)
            body.append(compressed)

            central.append(centralHeader(method: method, crc: crc, compressedSize: compressed.count,
                                         uncompressedSize: uncompressedSize, name: name,
                                         isDirectory: entry.isDirectory, localOffset: localOffset))
            central.append(name)
        }

        var out = Data()
        out.reserveCapacity(body.count + central.count + 22)
        out.append(body)
        out.append(central)
        out.append(endOfCentralDirectory(entries: entries.count, centralSize: central.count,
                                         centralOffset: body.count))

        try overwrite(url, with: out)
    }

    /// Deflates one payload as a raw deflate stream (no zlib header).
    private static func deflatePacket(_ payload: Data) throws -> Data {
        var stream = z_stream()
        let initResult = deflateInit2_(&stream, 6, Z_DEFLATED, -CInt(MAX_WBITS), 8, Z_DEFAULT_STRATEGY,
                                       ZLIB_VERSION, CInt(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else {
            throw ZIPError.corrupted("zlib deflate init (\(initResult))")
        }
        defer { deflateEnd(&stream) }

        var output = Data(count: upperBoundDeflated(payload.count))
        let outputCapacity = output.count
        var produced = 0
        var status: Int32 = Z_BUF_ERROR
        payload.withUnsafeBytes { inputRaw in
            output.withUnsafeMutableBytes { outputRaw in
                let inputBase = inputRaw.bindMemory(to: Bytef.self).baseAddress
                let outputBase = outputRaw.bindMemory(to: Bytef.self).baseAddress
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBase)
                stream.avail_in = uInt(payload.count)
                stream.next_out = outputBase
                stream.avail_out = uInt(outputCapacity)
                status = deflate(&stream, Z_FINISH)
                produced = outputCapacity - Int(stream.avail_out)
            }
        }
        guard status == Z_STREAM_END else {
            throw ZIPError.corrupted("deflate (status \(status))")
        }
        return output.prefix(produced)
    }

    /// zlib's deflate bound for one Z_FINISH call on a pre-sized buffer.
    private static func upperBoundDeflated(_ size: Int) -> Int {
        // deflateBound() ~ size + size/1000 + 12 + 5*2; pad generously.
        size + size / 100 + 64
    }

    private static func overwrite(_ url: URL, with data: Data) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).zip-tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    private static func localHeader(method: UInt16, crc: UInt32, compressedSize: Int,
                                    uncompressedSize: Int, name: Data) -> Data {
        var d = Data()
        d.appendLE32(0x04034b50)
        d.appendLE16(UInt16(20))         // version needed
        d.appendLE16(UInt16(0))          // flags
        d.appendLE16(method)
        d.appendLE16(UInt16(0))          // mod time
        d.appendLE16(UInt16((2026 - 1980) << 9 | (1 << 5) | 1)) // mod date
        d.appendLE32(crc)
        d.appendLE32(UInt32(compressedSize))
        d.appendLE32(UInt32(uncompressedSize))
        d.appendLE16(UInt16(name.count))
        d.appendLE16(UInt16(0))          // extra length
        return d
    }

    private static func centralHeader(method: UInt16, crc: UInt32, compressedSize: Int,
                                      uncompressedSize: Int, name: Data, isDirectory: Bool,
                                      localOffset: Int) -> Data {
        var d = Data()
        d.appendLE32(0x02014b50)
        d.appendLE16(UInt16(0x031E))     // made by: Unix, spec 3.0
        d.appendLE16(UInt16(20))         // version needed
        d.appendLE16(UInt16(0))          // flags
        d.appendLE16(method)
        d.appendLE16(UInt16(0))          // mod time
        d.appendLE16(UInt16((2026 - 1980) << 9 | (1 << 5) | 1)) // mod date
        d.appendLE32(crc)
        d.appendLE32(UInt32(compressedSize))
        d.appendLE32(UInt32(uncompressedSize))
        d.appendLE16(UInt16(name.count))
        d.appendLE16(UInt16(0))          // extra length
        d.appendLE16(UInt16(0))          // comment length
        d.appendLE16(UInt16(0))          // disk number start
        d.appendLE16(UInt16(0))          // internal attrs
        // External attrs: posix mode in the high 16 bits (dir 0755 / file 0644).
        let posixMode: UInt32 = (isDirectory ? 0o040755 : 0o100644) << 16
        d.appendLE32(posixMode | (isDirectory ? 0x10 : 0))
        d.appendLE32(UInt32(localOffset))
        return d
    }

    private static func endOfCentralDirectory(entries: Int, centralSize: Int, centralOffset: Int) -> Data {
        var d = Data()
        d.appendLE32(0x06054b50)
        d.appendLE16(UInt16(0))          // this disk
        d.appendLE16(UInt16(0))          // central dir disk
        d.appendLE16(UInt16(truncatingIfNeeded: entries))
        d.appendLE16(UInt16(truncatingIfNeeded: entries))
        d.appendLE32(UInt32(centralSize))
        d.appendLE32(UInt32(centralOffset))
        d.appendLE16(UInt16(0))          // comment length
        return d
    }
}

// MARK: - Shared zlib helpers

func crc32Of(_ data: Data) -> UInt32 {
    let count = data.count
    return data.withUnsafeBytes { raw -> UInt32 in
        guard let base = raw.bindMemory(to: Bytef.self).baseAddress else {
            return 0
        }
        return UInt32(crc32(crc32(0, nil, 0), base, uInt(count)))
    }
}

// MARK: - little-endian appends

private extension Data {
    mutating func appendLE32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    mutating func appendLE16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }
}

