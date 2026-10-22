import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Omarchy.TCPViewer

ApplicationWindow {
    id: window
    width: 1440
    height: 900
    visible: true
    title: qsTr("Omarchy TCPViewer")
    color: Theme.windowBackground

    property bool capturing: false

    PacketListModel { id: packets }
    Benchmark { id: bench }

    // Toolbar ----------------------------------------------------------------
    Rectangle {
        id: toolbar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 48
        color: Theme.contentBackground

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            spacing: 10

            // Interface popup (visual stand-in until the daemon is wired in).
            Rectangle {
                Layout.preferredWidth: 220
                Layout.preferredHeight: 28
                radius: 6
                color: Theme.windowBackground

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 8
                    spacing: 6

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Ethernet (enp0s25)"
                        font.family: Theme.uiFont
                        font.pixelSize: Theme.uiSize
                        color: Theme.label
                    }
                }
            }

            // Capture toggle
            Rectangle {
                Layout.preferredWidth: 74
                Layout.preferredHeight: 28
                radius: 6
                color: window.capturing ? Theme.systemRed : Theme.accent

                Text {
                    anchors.centerIn: parent
                    text: window.capturing ? "Stop" : "Start"
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSize
                    font.weight: Font.DemiBold
                    color: "white"
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: window.capturing = !window.capturing
                }
            }

            Item { Layout.fillWidth: true }

            Text {
                text: packets.count === 1 ? "1 packet" : packets.count + " packets"
                font.family: Theme.uiFont
                font.pixelSize: Theme.uiSmall
                color: Theme.secondaryLabel
            }

            Item { Layout.fillWidth: true }

            Text {
                text: "Share"
                font.family: Theme.uiFont
                font.pixelSize: Theme.uiSize
                color: Theme.label
            }
        }

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1
            color: Theme.separator
        }
    }

    // Quick filters ----------------------------------------------------------
    Rectangle {
        id: quickFilter
        anchors.top: toolbar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: Theme.quickFilterHeight
        color: Theme.contentBackground

        Row {
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            Repeater {
                model: ["All", "TCP", "UDP", "TLS", "DNS", "HTTP"]

                delegate: Rectangle {
                    required property int index
                    required property string modelData

                    width: pill.implicitWidth + 32
                    height: Theme.quickFilterButtonHeight
                    radius: 6
                    color: index === 0 ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                                       : "transparent"

                    Text {
                        id: pill
                        anchors.centerIn: parent
                        text: modelData
                        font.family: Theme.uiFont
                        font.pixelSize: Theme.uiSmall
                        font.weight: Font.Medium
                        color: index === 0 ? Theme.accent : Theme.label
                    }
                }
            }
        }

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1
            color: Theme.separator
        }
    }

    // Packet table -----------------------------------------------------------
    Loader {
        id: tableLoader
        anchors.top: quickFilter.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: statusStrip.top
        sourceComponent: bench.enabled && bench.view === "table" ? qmlTableView : qmlListView
    }

    Component {
        id: qmlListView
        PacketTableListView {
            model: packets
            follow: bench.follow
        }
    }

    Component {
        id: qmlTableView
        PacketTableView {
            model: packets
            follow: bench.follow
        }
    }

    // Status strip -----------------------------------------------------------
    Rectangle {
        id: statusStrip
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Theme.statusStripHeight
        color: Theme.windowBackground

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 1
            color: Theme.separator
        }

        Text {
            anchors.centerIn: parent
            text: packets.count === 1 ? "1 packet" : packets.count + " packets"
            font.family: Theme.monoFont
            font.pixelSize: Theme.uiSmall
            color: Theme.secondaryLabel
        }

        Text {
            anchors.right: parent.right
            anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            text: bench.enabled ? "spike: " + bench.view : ""
            font.family: Theme.monoFont
            font.pixelSize: Theme.uiSmall
            color: Theme.secondaryLabel
        }
    }

    Component.onCompleted: {
        if (bench.enabled)
            bench.start(packets, window)
    }
}
