//
//  IPCCommand.swift
//  Omarchy TCPViewer
//
//  schema_version 1 command names. Dotted names match upstream
//  TCPViewerCLIShared/TCPViewerCLIModels.swift where a command exists there,
//  so automation written against upstream translates directly.
//
//  Documented divergences from upstream CLI.md (see docs/security-checklist.md
//  and the plugin README for the ported command surface):
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
    // New in the port: GUI Overview page aggregates over the summary buffer.
    case captureOverview = "capture.overview"

    case sourcesList = "sources.list"
    case sourceClose = "source.close"

    case packetsList = "packets.list"
    case packetsSummary = "packets.summary"
    case packetsDetails = "packets.details"
    case packetsBytes = "packets.bytes"
    case packetsClear = "packets.clear"

    /// New in our schema: packet text-style mutations (highlight color,
    /// strikethrough). Upstream applies these in-process from the GUI; the
    /// port's daemon owns the packet buffers, so the client needs commands.
    /// `op`: set_highlight (with `color`: name) | toggle_strikethrough | reset.
    case packetsSetStyle = "packets.set_style"

    /// New in our schema: set or replace the TCP Viewer comment on the
    /// indexed packets. `comment` is sanitized like upstream (CR/CRLF → LF,
    /// trimmed, first 1000 chars); an empty sanitized comment is a silent
    /// no-op — upstream v1 offers no comment removal.
    case packetsSetComment = "packets.set_comment"

    case streamPackets = "stream.packets"
    case streamFollow = "stream.follow"

    case fileImport = "file.import"
    case fileExport = "file.export"
    case fileExportSession = "file.export_session"

    /// Session-document workspace state for a loaded source (pins for now).
    /// New in our schema: upstream keeps document state in-process.
    case fileSessionState = "file.session_state"

    /// Abort an in-flight `file.import` chain (cancel current file and stop
    /// loading the remaining ones). New in our schema.
    case importCancel = "import.cancel"

    /// Opt this connection into async events (params: enabled bool, default
    /// true). New in our schema: upstream's file transport had no push.
    case eventsSubscribe = "events.subscribe"
}

/// Async server→client notifications, multiplexed on the same socket as
/// responses. A line is a response iff it carries `ok`; an event iff it
/// carries `event`. Only connections that sent `events.subscribe` receive
/// them. New packet rows are NOT pushed — clients pull with
/// `packets.list --since-id` (bounded, backpressure-friendly per the
/// upstream AGENTS.md design rules).
public enum IPCEvent: String, Codable, CaseIterable {
    /// Capture lifecycle/health changed. data: status snapshot.
    case captureState = "capture.state"
    /// Capture health (drop counts, store size). data: status snapshot.
    case captureHealth = "capture.health"
    /// A source was opened or closed (e.g. by another client).
    case sourcesChanged = "sources.changed"
}
