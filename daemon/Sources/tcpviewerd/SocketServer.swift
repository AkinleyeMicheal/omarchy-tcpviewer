//
//  SocketServer.swift
//  tcpviewerd
//
//  Per-user Unix-socket JSON server (schema_version 1).
//  Security model: directory 0700 + socket 0600 under $XDG_RUNTIME_DIR,
//  SO_PEERCRED same-UID enforcement on accept, 1 MiB inbound line cap,
//  per-connection serial read/write queues with bounded fan-out events.
//

import Foundation
import TCPViewerIPC
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// C `struct ucred { pid_t; uid_t; gid_t }` — Swift Glibc doesn't import the
/// glibc-only type, so mirror its layout (three 4-byte fields, align 4 =
/// 12 bytes, identical to the kernel's SO_PEERCRED payload).
private struct LinuxPeerCredentials {
    var pid: Int32 = 0
    var uid: UInt32 = 0
    var gid: UInt32 = 0
}

final class SocketServer: @unchecked Sendable {
    enum ServerError: Error, CustomStringConvertible {
        case mkdirFailed(String)
        case socketFailed(String)
        case bindFailed(String)
        case listenFailed(String)
        case notSafeToUnlink(String)
        case unsafeDirectory(String)

        var description: String {
            switch self {
            case .mkdirFailed(let path): return "cannot create \(path): \(String(cString: strerror(errno)))"
            case .socketFailed(let detail): return "socket(): \(detail)"
            case .bindFailed(let path): return "bind(\(path)): \(String(cString: strerror(errno)))"
            case .listenFailed(let detail): return "listen(): \(detail)"
            case .notSafeToUnlink(let path): return "refusing to replace non-socket at \(path)"
            case .unsafeDirectory(let path): return "socket directory is not owned by this user: \(path)"
            }
        }
    }

    private let path: String
    private let router: CommandRouter
    private let manager: SourceManager

    private let registryQueue = DispatchQueue(label: "org.omarchy.tcpviewerd.registry")
    private var connections: [ObjectIdentifier: Connection] = [:]
    private let acceptQueue = DispatchQueue(label: "org.omarchy.tcpviewerd.accept", qos: .userInitiated)
    private var listenFD: Int32 = -1
    private var running = false

    init(path: String, router: CommandRouter, manager: SourceManager) {
        self.path = path
        self.router = router
        self.manager = manager
    }

    // MARK: - Lifecycle

    func start() throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if mkdir(directory, 0o700) != 0, errno != EEXIST {
            throw ServerError.mkdirFailed(directory)
        }
        // Tighten even when the dir already existed (XDG_RUNTIME_DIR is 0700,
        // but this dir may have been created by an older/looser build).
        // Refuse to bind into a directory owned by another user: in a shared
        // parent that user could replace our socket and impersonate the daemon.
        var directoryStat = stat()
        guard stat(directory, &directoryStat) == 0, directoryStat.st_uid == geteuid() else {
            throw ServerError.unsafeDirectory(directory)
        }
        chmod(directory, 0o700)

        var fileStat = stat()
        if lstat(path, &fileStat) == 0 {
            // Only ever replace a socket we own in our private dir; a regular
            // file or foreign symlink at this path means something is wrong.
            guard (fileStat.st_mode & S_IFMT) == S_IFSOCK else {
                throw ServerError.notSafeToUnlink(path)
            }
            unlink(path)
        }

        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { throw ServerError.socketFailed(String(cString: strerror(errno))) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw ServerError.bindFailed("path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = byte
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw ServerError.bindFailed(path)
        }
        // 0600 on the socket itself (dir is 0700; belt and suspenders).
        chmod(path, 0o600)

        guard listen(fd, 16) == 0 else {
            close(fd)
            unlink(path)
            throw ServerError.listenFailed(String(cString: strerror(errno)))
        }

        listenFD = fd
        running = true
        manager.eventSink = { [weak self] message in
            self?.broadcast(message)
        }
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        running = false
        if listenFD >= 0 {
            // Unblocks the pending accept().
            shutdown(listenFD, Int32(SHUT_RDWR))
            close(listenFD)
            listenFD = -1
        }
        let current = registryQueue.sync { Array(connections.values) }
        for connection in current {
            connection.close()
        }
        unlink(path)
    }

    // MARK: - Accept

    private func acceptLoop() {
        while running {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return  // listener closed or fatal
            }

            // Same-UID only: reject foreign processes before any read.
            var credentials = LinuxPeerCredentials()
            var length = socklen_t(MemoryLayout<LinuxPeerCredentials>.size)
            let gotCredentials = getsockopt(client, SOL_SOCKET, SO_PEERCRED, &credentials, &length) == 0
            guard gotCredentials, credentials.uid == geteuid() else {
                close(client)
                continue
            }

            let connection = Connection(fd: client, server: self)
            registryQueue.sync {
                connections[ObjectIdentifier(connection)] = connection
            }
            connection.start()
        }
    }

    fileprivate func remove(_ connection: Connection) {
        registryQueue.sync {
            connections.removeValue(forKey: ObjectIdentifier(connection))
        }
    }

    fileprivate func setSubscribed(_ connection: Connection, _ subscribed: Bool) {
        registryQueue.sync {
            connection.isSubscribed = subscribed
        }
    }

    // MARK: - Event fan-out

    private func broadcast(_ message: IPCEventMessage) {
        let targets = registryQueue.sync {
            connections.values.filter(\.isSubscribed)
        }
        for target in targets {
            target.send(message)  // hops onto the target's write queue
        }
    }

    // MARK: - One client connection

    final class Connection {
        fileprivate var isSubscribed = false  // guarded by server.registryQueue
        private let fd: Int32
        private unowned let server: SocketServer
        private let readQueue = DispatchQueue(label: "org.omarchy.tcpviewerd.conn.read")
        private let writeQueue = DispatchQueue(label: "org.omarchy.tcpviewerd.conn.write")
        private let closeLock = NSLock()
        private var isClosed = false

        fileprivate init(fd: Int32, server: SocketServer) {
            self.fd = fd
            self.server = server
        }

        func start() {
            readQueue.async { [weak self] in
                self?.readLoop()
            }
        }

        /// Idempotent close; safe from both read and write paths.
        func close() {
            closeLock.lock()
            defer { closeLock.unlock() }
            guard !isClosed else { return }
            isClosed = true
            Darwin_close(fd)
            server.remove(self)
        }

        // MARK: Read

        private func readLoop() {
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 16_384)

            while true {
                // Drain complete lines first so a partial line never hides
                // behind more reads.
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    handle(line: line)
                }
                if buffer.count > IPCLimits.maxRequestBytes {
                    respond(failure: IPCFramingError.lineTooLarge(buffer.count), to: nil, command: "")
                    close()
                    return
                }

                let count = read(fd, &chunk, chunk.count)
                if count == 0 {
                    close()  // orderly EOF
                    return
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    close()
                    return
                }
                buffer.append(contentsOf: chunk[0..<count])
            }
        }

        private func handle(line: Data) {
            guard !line.isEmpty else { return }

            let request: IPCRequest
            do {
                request = try IPCCodec.decodeRequest(line: line)
            } catch let error as IPCFramingError {
                // Unparseable input: answer with the wire error, id "".
                respond(failure: error, to: "", command: "")
                return
            } catch {
                respond(failure: IPCFramingError.malformed("decode failed"), to: "", command: "")
                return
            }

            guard !IPCCodec.isExpired(request) else {
                respond(
                    failure: IPCFramingError(code: IPCError.timeout, message: "request expired before processing"),
                    to: request.requestID,
                    command: request.command.rawValue
                )
                return
            }

            server.router.handle(request: request, setSubscription: { [weak self] enabled in
                guard let self else { return }
                self.server.setSubscribed(self, enabled)
            }) { [weak self] response in
                self?.send(response)
            }
        }

        // MARK: Write

        fileprivate func send<T: Encodable>(_ message: T) {
            guard let line = try? IPCCodec.encodeLine(message, limit: IPCLimits.maxResponseBytes) else {
                return  // encoding failure: drop (never kill capture over one line)
            }
            writeQueue.async { [weak self] in
                guard let self else { return }
                if !self.writeAll(line) {
                    self.close()
                }
            }
        }

        private func writeAll(_ data: Data) -> Bool {
            var offset = 0
            return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
                guard let base = raw.baseAddress else { return false }
                while offset < raw.count {
                    let written = write(fd, base.advanced(by: offset), raw.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else {
                        return false
                    }
                }
                return true
            }
        }

        // MARK: Failure responses

        private func respond(failure: IPCFramingError, to requestID: String?, command: String) {
            let response = IPCResponse.failure(
                requestID: requestID ?? "",
                command: command,
                code: failure.code,
                message: failure.message
            )
            send(response)
        }
    }
}

/// `close(2)` collides with `Connection.close()` under Swift's method
/// lookup — route the syscall through a free function.
private func Darwin_close(_ fd: Int32) {
    close(fd)
}
