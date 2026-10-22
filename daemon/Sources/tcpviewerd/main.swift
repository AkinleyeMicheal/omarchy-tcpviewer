//
//  main.swift
//  tcpviewerd
//
//  Omarchy TCPViewer daemon: owns capture sources and serves the
//  schema_version 1 JSON protocol on a per-user Unix socket
//  ($XDG_RUNTIME_DIR/omarchy-tcpviewer/tcpviewerd.sock, dir 0700/socket
//  0600, same-UID peers only). Runs in the foreground under systemd.
//
//  Exit codes: 0 clean, 2 usage, 3 runtime failure.
//

import Foundation
import TCPViewerIPC
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

func usage() -> Never {
    let text = """
    usage: tcpviewerd [--socket PATH] [--version] [--help]

      --socket PATH   listen on PATH instead of
                      $XDG_RUNTIME_DIR/omarchy-tcpviewer/tcpviewerd.sock
      --version       print version and exit
    """
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(2)
}

// MARK: - Arguments

var socketPathOverride: String?
var iterator = Array(CommandLine.arguments.dropFirst())
while let argument = iterator.first {
    iterator.removeFirst()
    switch argument {
    case "--help", "-h":
        usage()
    case "--version":
        print("tcpviewerd \(SourceManager.daemonVersion)")
        exit(0)
    case "--socket":
        guard let path = iterator.first else {
            FileHandle.standardError.write(Data("--socket needs a path\n".utf8))
            exit(2)
        }
        iterator.removeFirst()
        socketPathOverride = path
    default:
        FileHandle.standardError.write(Data("unknown argument: \(argument)\n".utf8))
        usage()
    }
}

let socketPath: String
if let override = socketPathOverride {
    socketPath = override
} else {
    guard let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] else {
        FileHandle.standardError.write(Data("XDG_RUNTIME_DIR is not set; not an Omarchy user session?\n".utf8))
        exit(3)
    }
    socketPath = "\(runtime)/omarchy-tcpviewer/tcpviewerd.sock"
}

// MARK: - Boot

let manager = SourceManager()
let router = CommandRouter(manager: manager, socketPath: socketPath)
let server = SocketServer(path: socketPath, router: router, manager: manager)

do {
    try server.start()
} catch {
    FileHandle.standardError.write(Data("tcpviewerd: \(error)\n".utf8))
    exit(3)
}

print("tcpviewerd \(SourceManager.daemonVersion) listening on \(socketPath)")
fflush(stdout)

// MARK: - Signals

// SIGPIPE must never kill the daemon: a vanished client is just an EPIPE
// write. Handlers only raise a flag; teardown runs on the normal run loop so
// Wireshark sessions can be released before exit.
signal(SIGPIPE, SIG_IGN)

nonisolated(unsafe) var shutdownRequested: sig_atomic_t = 0
signal(SIGINT, { _ in shutdownRequested = 1 })
signal(SIGTERM, { _ in shutdownRequested = 1 })

// Foreground run loop (systemd-friendly); poll the flag cheaply.
while shutdownRequested == 0 {
    usleep(250_000)
}

server.stop()
manager.shutdown()
print("tcpviewerd stopped")
fflush(stdout)
exit(0)
