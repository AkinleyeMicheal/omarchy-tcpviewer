//
//  IPCCommand.swift
//  Omarchy TCPViewer
//
//  schema_version 1 command names. Dotted names match upstream
//  TCPViewerCLIShared/TCPViewerCLIModels.swift where a command exists there,
//  so automation written against upstream translates directly.
//
//  Documented divergences from upstream CLI.md (see docs/ipc.md):
//  - `license.*` omitted: the port is fully open, no license gating.
//  - `workspace.*`, `tabs.*`, `pane.*`, `split.*`, `diff.*`, `packets.reveal`
//    omitted: these model GUI window state; tabs/splits/diff live entirely
//    in the Qt Quick client, the daemon holds only capture sources.
//  - `settings.*` omitted for v1: client-side settings are stored in the
//    GUI's XDG config; no daemon-wide settings exist yet.
//  - `source.close` is new: closing a source is the daemon-side equivalent
//    of upstream's tabs.close for import tabs.
//

import Foundation

public enum IPCCommand: String, Codable, CaseIterable {
    case appStatus = "app.status"
    case interfacesList = "interfaces.list"

    case captureStatus = "capture.status"
    case captureStart = "capture.start"
    case capturePause = "capture.pause"
    case captureResume = "capture.resume"
    case captureStop = "capture.stop"

    case sourcesList = "sources.list"
    case sourceClose = "source.close"

    case packetsList = "packets.list"
    case packetsSummary = "packets.summary"
    case packetsDetails = "packets.details"
    case packetsBytes = "packets.bytes"
    case packetsClear = "packets.clear"

    case streamPackets = "stream.packets"
    case streamFollow = "stream.follow"

    case fileImport = "file.import"
    case fileExport = "file.export"
    case fileExportSession = "file.export_session"
}

/// Async server→client notifications, multiplexed on the same socket as
/// responses. A line is a response iff it carries `ok`; an event iff it
/// carries `event`.
public enum IPCEvent: String, Codable, CaseIterable {
    /// Capture lifecycle/health changed. data: status snapshot.
    case captureState = "capture.state"
    /// Batch of new packet summaries. data: source_id, packets[], dropped.
    case capturePackets = "capture.packets"
    /// Capture health (drop count, store size). data: status snapshot.
    case captureHealth = "capture.health"
}
