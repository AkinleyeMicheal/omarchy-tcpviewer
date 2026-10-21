//
//  SourceSecurity.swift
//  tcpviewerd
//
//  Path validation for file.import / file.export / file.export_session.
//  Export mirrors upstream CLI.md: never replaces an existing file without
//  --overwrite, and refuses symbolic-link destinations (same-UID transport,
//  so this is overwrite-hygiene rather than a privilege boundary).
//

import Foundation
import TCPViewerIPC

enum SourceSecurity {
    private static let maxPathLength = 4_096

    /// Import: absolute, exists, regular file, readable, supported format.
    static func validatedImportPath(_ raw: String) throws -> String {
        let path = try commonChecks(raw)

        guard path.hasSuffix(".pcap") || path.hasSuffix(".pcapng") || path.hasSuffix(".cap") else {
            throw SourceError(
                code: IPCError.invalidParams,
                message: "unsupported capture format (want .pcap or .pcapng)"
            )
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw SourceError(code: IPCError.notFound, message: "file not found: \(path)")
        }
        guard !isDirectory.boolValue else {
            throw SourceError(code: IPCError.invalidParams, message: "not a file: \(path)")
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw SourceError(code: IPCError.permissionDenied, message: "file not readable: \(path)")
        }
        return path
    }

    /// Export destination: absolute, parent exists, no symlink at the final
    /// component, existing regular files only with overwrite.
    static func validatedExportPath(_ raw: String, overwrite: Bool) throws -> String {
        let path = try commonChecks(raw)

        // Refuse BEFORE existence checks: a symlink destination is always
        // rejected, overwrite or not (upstream rule).
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil {
            throw SourceError(code: IPCError.invalidParams, message: "refusing symbolic-link destination: \(path)")
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else {
                throw SourceError(code: IPCError.invalidParams, message: "destination is a directory: \(path)")
            }
            guard overwrite else {
                throw SourceError(
                    code: IPCError.invalidParams,
                    message: "file exists (pass --overwrite to replace): \(path)"
                )
            }
        }

        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var parentIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent, isDirectory: &parentIsDirectory),
            parentIsDirectory.boolValue else {
            throw SourceError(code: IPCError.notFound, message: "parent directory not found: \(parent)")
        }
        return path
    }

    private static func commonChecks(_ raw: String) throws -> String {
        guard !raw.isEmpty, raw.count <= maxPathLength else {
            throw SourceError(code: IPCError.invalidParams, message: "path empty or too long")
        }
        guard !raw.unicodeScalars.contains("\0") else {
            throw SourceError(code: IPCError.invalidParams, message: "path contains NUL")
        }
        guard raw.hasPrefix("/") else {
            throw SourceError(code: IPCError.invalidParams, message: "path must be absolute: \(raw)")
        }
        // stdize removes "." / ".." components lexically before use.
        return URL(fileURLWithPath: raw).standardized.path
    }
}
