pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// TCPViewer bar leaf: a recognizable network glyph whose color carries the
// capture-engine state (accent when tcpviewerd answers, muted otherwise).
// Click opens the quick access panel. The shell injects `bar`, `moduleName`
// and `settings` into this root (Plugin registry contract); BarIconButton
// handles slot sizing, optical glyph bounds and tooltips like first-party
// widgets. U+F0318 is nf-md-lan_connect from JetBrainsMono Nerd Font.
BarIconButton {
    id: root

    property string moduleName: "fonsgaudii.tcpviewer"
    property var settings: ({})

    // True when a tcpviewerd under this user session is running.
    property bool daemonRunning: false

    text: "\uDB80\uDF18"
    foreground: root.daemonRunning ? Color.accent : Color.muted
    tooltipText: root.daemonRunning
        ? "TCPViewer — capture engine running. Click for quick access."
        : "TCPViewer — capture engine stopped. Click for quick access."
    onPressed: function(buttonCode) {
        if (buttonCode === Qt.LeftButton)
            root.togglePanel()
    }

    function togglePanel() {
        // Public shell IPC: omarchy-shell shell toggle <pluginId>.
        if (root.bar && typeof root.bar.run === "function")
            root.bar.run("omarchy-shell -q shell toggle " + root.moduleName)
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
