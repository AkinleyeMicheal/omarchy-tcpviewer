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

    readonly property string statusLabel: !root.probed
        ? "Checking capture engine…"
        : root.daemonRunning
          ? (root.binariesReady ? "Capture engine running — viewer ready"
                                : "Capture engine running (viewer app not built in this clone)")
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
        soonProbe.restart()
    }

    function refreshSoon() {
        soonProbe.restart()
    }

    // Launch the viewer: builds are expected inside this plugin clone; the
    // run script is fixed-height safe for launchers (no terminal, no eval).
    function launch() {
        Util.execDetached('"' + root.pluginDir + '/scripts/tcpviewer-run.sh"')
        root.refresh()
    }

    function stopDaemon() {
        Util.execDetached("pkill -x tcpviewerd")
        root.refreshSoon()
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

    Timer {
        id: refreshTimer
        interval: 3000
        repeat: true
        running: root.opened
        onTriggered: {
            daemonProbe.running = true
            binariesProbe.running = true
        }
    }

    Timer {
        id: soonProbe
        interval: 2500
        repeat: false
        onTriggered: {
            daemonProbe.running = true
            binariesProbe.running = true
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
                            color: root.daemonRunning
                                ? Color.accent
                                : Util.alpha(Color.foreground, 0.35)
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

                // Actions
                Repeater {
                    model: [
                        { label: "Launch TCPViewer", hint: "daemon + viewer app", glyph: "▶", action: function() { root.launch() } },
                        { label: "Stop capture daemon", hint: "tcpviewerd", glyph: "■", action: function() { root.stopDaemon() } },
                        { label: "Open project page", hint: "github.com/AkinleyeMicheal", glyph: "↗", action: function() { root.openProjectPage() } }
                    ]

                    delegate: Rectangle {
                        required property var modelData
                        width: parent ? parent.width : 0
                        height: 36
                        radius: 8
                        color: actionMouse.containsMouse
                            ? Color.menu.selectedBackground
                            : "transparent"

                        Row {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: 12
                            spacing: 10

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.glyph
                                font.family: Style.font.family
                                font.pixelSize: 11
                                color: Color.accent
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.label
                                font.family: Style.font.family
                                font.pixelSize: 11
                                color: Color.menu.text
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.hint
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
                            onClicked: { root.close(); modelData.action() }
                        }
                    }
                }

                // Footer
                Item {
                    width: parent.width
                    height: 12
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
