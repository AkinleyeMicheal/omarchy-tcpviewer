pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// TCPViewer quick access panel. The shell injects `shell` and `manifest`
// into this root item and drives open()/close() on summon/hide. The window
// keeps itself stateless besides volatile probe results and never writes to
// user configuration.
//
// Keyboard contract: opening hands focus to the first action row; Up/Down (or
// Tab/BackTab) cycle with wraparound, Enter/Space activate, Esc closes. Every
// action reachable with the mouse is reachable with the keyboard alone.
Item {
    id: root

    property bool opened: false
    property var shell: null
    property var manifest: null

    readonly property string pluginId: "fonsgaudii.tcpviewer"
    readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/" + pluginId

    property bool probed: false
    property bool daemonRunning: false
    property bool binariesReady: false
    property bool captureActive: false
    property bool building: false

    onBinariesReadyChanged: {
        if (root.binariesReady)
            root.building = false
    }

    readonly property string statusLabel: !root.probed
        ? "Checking capture engine…"
        : root.daemonRunning
          ? (root.captureActive ? "Live capture active"
                                : root.binariesReady ? "Idle — not capturing"
                                : "Daemon running (viewer app not built in this clone)")
          : (root.binariesReady ? "Idle — not capturing"
                                : "Not built yet — build inside the plugin clone")

    readonly property string versionLabel: root.manifest && root.manifest.version
        ? "v" + String(root.manifest.version) : ""

    function open(payloadJson) {
        root.opened = true
        root.refresh()
    }

    function close() {
        root.opened = false
    }

    function toggle() {
        if (root.opened)
            root.close()
        else
            root.open("")
    }

    function refresh() {
        daemonProbe.running = true
        binariesProbe.running = true
        captureProbe.running = true
        soonProbe.restart()
    }

    function refreshSoon() {
        soonProbe.restart()
    }

    // Hand focus to the first action row once the layer surface is up. The
    // keyboard grant arrives asynchronously after `visible`, so retry once.
    function focusFirstRow() {
        var first = actionRows.itemAt(0)
        if (first)
            first.forceActiveFocus()
        focusRetryTimer.restart()
    }

    onOpenedChanged: {
        if (root.opened) {
            Qt.callLater(root.focusFirstRow)
        }
    }

    Timer {
        id: focusRetryTimer
        interval: 200
        repeat: false
        onTriggered: {
            if (!root.opened)
                return
            var first = actionRows.itemAt(0)
            if (first && !first.activeFocus)
                first.forceActiveFocus()
        }
    }

    // Launch the viewer: builds are expected inside this plugin clone; the
    // run script is fixed-height safe for launchers (no terminal, no eval).
    function launch() {
        Util.execDetached('"' + root.pluginDir + '/scripts/tcpviewer-run.sh"')
        root.refresh()
    }

    function startCapture() {
        Util.execDetached('"' + root.pluginDir + '/scripts/quick-capture.sh" start')
        root.refreshSoon()
    }

    function stopCapture() {
        Util.execDetached('"' + root.pluginDir + '/scripts/quick-capture.sh" stop')
        root.refreshSoon()
    }

    function buildNow() {
        root.building = true
        Util.execDetached('"' + root.pluginDir + '/scripts/build.sh"')
    }

    function openProjectPage() {
        Util.execDetached("xdg-open https://github.com/AkinleyeMicheal/omarchy-tcpviewer")
    }

    // ---- probes ----

    // pgrep exits 0 when a tcpviewerd process exists under this user.
    Process {
        id: daemonProbe
        command: ["pgrep", "-x", "tcpviewerd"]
        onExited: function(exitCode) {
            root.daemonRunning = exitCode === 0
            root.probed = true
        }
    }

    Process {
        id: binariesProbe
        command: ["bash", "-lc", "test -x '" + root.pluginDir + "/app/build/omarchy-tcpviewer' && test -x '" + root.pluginDir + "/daemon/.build/debug/tcpviewerd' && echo ready || echo missing"]
        stdout: StdioCollector {
            id: binariesOutput
        }
        onExited: function(exitCode) {
            root.binariesReady = binariesOutput.text.trim() === "ready"
        }
    }

    // `capture status` exits 0 only when a source is open (live capture or a
    // loaded capture file). Anything else (idle daemon, offline, missing CLI)
    // reads as not capturing.
    Process {
        id: captureProbe
        command: ["bash", "-lc", "test -x '" + root.pluginDir + "/daemon/.build/debug/tcpviewer-cli' && '" + root.pluginDir + "/daemon/.build/debug/tcpviewer-cli' capture status >/dev/null 2>&1"]
        onExited: function(exitCode) {
            root.captureActive = exitCode === 0
        }
    }

    Timer {
        id: refreshTimer
        interval: 3000
        repeat: true
        running: root.opened
        onTriggered: {
            daemonProbe.running = true
            binariesProbe.running = true
            captureProbe.running = true
        }
    }

    Timer {
        id: soonProbe
        interval: 2500
        repeat: false
        onTriggered: {
            daemonProbe.running = true
            binariesProbe.running = true
            captureProbe.running = true
        }
    }

    PanelWindow {
        id: window

        visible: root.opened
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        screen: Quickshell.screens && Quickshell.screens.length > 0 ? Quickshell.screens[0] : null

        WlrLayershell.namespace: "omarchy-menu"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.opened
            ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        // Outside click dismisses (mirror of the omarchy menu surface).
        MouseArea {
            anchors.fill: parent
            enabled: root.opened
            onClicked: root.close()
        }

        Shortcut {
            sequence: "Esc"
            enabled: root.opened
            onActivated: root.close()
        }

        Rectangle {
            id: card
            anchors.centerIn: parent
            width: 480
            height: contentColumn.implicitHeight + 28
            radius: 12
            color: Color.menu.background
            border.color: Util.alpha(Color.menu.border, 0.5)
            border.width: 1

            MouseArea {
                anchors.fill: parent
            }

            Column {
                id: contentColumn
                anchors.margins: 16
                anchors.fill: parent
                spacing: 12

                function moveFocus(from, delta) {
                    var count = actionRows.count
                    if (count === 0)
                        return
                    for (var step = 0; step < count; step++) {
                        var next = (((from + delta) % count) + count) % count
                        var row = actionRows.itemAt(next)
                        if (row) {
                            row.forceActiveFocus()
                            return
                        }
                    }
                }

                // Header
                Item {
                    width: parent.width
                    height: 30

                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 10

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "⇄"
                            font.family: Style.font.family
                            font.pixelSize: 16
                            color: Color.accent
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Omarchy TCPViewer"
                            font.family: Style.font.family
                            font.pixelSize: 13
                            font.weight: Font.DemiBold
                            color: Color.menu.text
                        }
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.right: parent.right
                        text: root.versionLabel
                        font.family: Style.font.family
                        font.pixelSize: 10
                        color: Color.muted
                    }
                }

                // Status
                Rectangle {
                    width: parent.width
                    height: statusRow.implicitHeight + 20
                    radius: 8
                    color: Util.alpha(Color.menu.text, 0.06)

                    Row {
                        id: statusRow
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        spacing: 10

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 8
                            height: 8
                            radius: 4
                            color: root.captureActive
                                ? Color.accent
                                : Util.alpha(Color.foreground, 0.35)
                            border.color: root.captureActive
                                ? "transparent"
                                : (root.daemonRunning ? Color.accent : "transparent")
                            border.width: 2
                        }

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 3

                            Text {
                                text: root.statusLabel
                                font.family: Style.font.family
                                font.pixelSize: 11
                                color: Color.menu.text
                            }

                            Text {
                                text: "Repo: " + root.pluginDir
                                font.family: Style.font.family
                                font.pixelSize: 9
                                color: Color.muted
                            }
                        }
                    }
                }

                // Actions. The Build row appears only while the clone has no
                // binaries, keeping the list short once everything is ready.
                Repeater {
                    id: actionRows

                    model: {
                        var rows = [
                            { label: "Launch TCPViewer", hint: "daemon + viewer app", glyph: "▶", action: function() { root.launch() } }
                        ]
                        if (!root.binariesReady)
                            rows.push({ label: "Build engine & viewer", hint: root.building ? "running in background…" : "first build takes minutes", glyph: "⚒", action: function() { root.buildNow() } })
                        rows.push({ label: "Start live capture", hint: root.captureActive ? "already capturing" : "default interface", glyph: "●", action: function() { root.startCapture() } })
                        rows.push({ label: "Stop capture", hint: "keeps the daemon running", glyph: "■", action: function() { root.stopCapture() } })
                        rows.push({ label: "Open project page", hint: "github.com/AkinleyeMicheal", glyph: "↗", action: function() { root.openProjectPage() } })
                        return rows
                    }

                    delegate: Rectangle {
                        id: actionRow

                        required property var modelData
                        required property int index

                        width: parent ? parent.width : 0
                        height: 36
                        radius: 8
                        color: actionRow.activeFocus || actionMouse.containsMouse
                            ? Color.menu.selectedBackground
                            : "transparent"
                        border.color: actionRow.activeFocus ? Color.accent : "transparent"
                        border.width: 1

                        function activate() {
                            actionRow.modelData.action()
                        }

                        Keys.onReturnPressed: function(event) { root.close(); actionRow.activate() }
                        Keys.onEnterPressed: function(event) { root.close(); actionRow.activate() }
                        Keys.onSpacePressed: function(event) { root.close(); actionRow.activate() }
                        Keys.onUpPressed: function(event) { contentColumn.moveFocus(actionRow.index, -1) }
                        Keys.onDownPressed: function(event) { contentColumn.moveFocus(actionRow.index, 1) }
                        Keys.onTabPressed: function(event) { contentColumn.moveFocus(actionRow.index, 1) }
                        Keys.onBacktabPressed: function(event) { contentColumn.moveFocus(actionRow.index, -1) }

                        Row {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: 12
                            spacing: 10

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: actionRow.modelData.glyph
                                font.family: Style.font.family
                                font.pixelSize: 11
                                color: Color.accent
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: actionRow.modelData.label
                                font.family: Style.font.family
                                font.pixelSize: 11
                                color: Color.menu.text
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: actionRow.modelData.hint
                                font.family: Style.font.family
                                font.pixelSize: 9
                                color: Color.muted
                            }
                        }

                        MouseArea {
                            id: actionMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { root.close(); actionRow.activate() }
                        }
                    }
                }

                // Keyboard legend
                Text {
                    text: "↑↓/Tab select · Enter activate · Esc close"
                    font.family: Style.font.family
                    font.pixelSize: 9
                    color: Color.muted
                }

                Text {
                    text: "GPL-2.0-or-later · " + root.pluginId + " · Esc or click outside to close"
                    font.family: Style.font.family
                    font.pixelSize: 9
                    color: Color.muted
                }
            }
        }
    }
}
