pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// TCPViewer bar leaf: glyph with capture-daemon status dot; click opens the
// quick access panel. The shell injects `bar`, `moduleName` and `settings`
// into this root item (Plugin registry contract).
Item {
    id: root

    property var bar: null
    property string moduleName: "fonsgaudii.tcpviewer"
    property var settings: ({})

    // True when a tcpviewerd under this user session is running.
    property bool daemonRunning: false

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    function togglePanel() {
        // Public shell IPC: omarchy-shell shell toggle <pluginId>.
        if (root.bar && typeof root.bar.run === "function")
            root.bar.run("omarchy-shell -q shell toggle " + root.moduleName)
    }

    WidgetButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: "⇄"
        labelVisible: false
        fontSize: Style.bar.iconFont
        tooltipText: "TCPViewer — status & quick access"
        onPressed: function(buttonCode) {
            if (buttonCode === Qt.LeftButton)
                root.togglePanel()
        }
    }

    // Capture daemon indicator pinned to the glyph corner.
    Rectangle {
        width: 7
        height: 7
        radius: 3.5
        anchors.bottom: button.bottom
        anchors.bottomMargin: 4
        anchors.right: button.right
        anchors.rightMargin: 5
        color: root.daemonRunning
            ? Color.accent
            : Util.alpha(Color.foreground, 0.3)
        border.color: Color.background
        border.width: 1
    }

    Timer {
        id: pollTimer
        interval: 4000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: daemonProbe.running = true
    }

    // pgrep exits 0 when a tcpviewerd process exists under this user.
    Process {
        id: daemonProbe
        command: ["pgrep", "-x", "tcpviewerd"]
        onExited: function(exitCode) {
            root.daemonRunning = exitCode === 0
        }
    }
}
