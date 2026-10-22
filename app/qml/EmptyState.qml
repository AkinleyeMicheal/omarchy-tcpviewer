import QtQuick
import QtQuick.Controls
import Omarchy.TCPViewer

// Upstream empty-state layout (AppKitUIUtilities placeholder): large glyph,
// 19 px semibold title, 13 px secondary message, action row.
Item {
    id: root

    property string glyph: "◎"
    property string title: "No Capture Open"
    property string message: "Start a live capture or open a capture file to inspect traffic."
    property bool showStartAction: true
    property bool showOpenAction: true

    signal startCaptureRequested
    signal openFileRequested

    Column {
        anchors.centerIn: parent
        width: Math.min(parent.width - 80, 460)
        spacing: 10

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.glyph
            font.family: Theme.uiFont
            font.pixelSize: 42
            color: Theme.secondaryLabel
            opacity: 0.55
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: root.title
            font.family: Theme.uiFont
            font.pixelSize: Theme.uiTitle
            font.weight: Font.DemiBold
            color: Theme.label
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(parent.width, 420)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: root.message
            font.family: Theme.uiFont
            font.pixelSize: Theme.uiSize
            color: Theme.secondaryLabel
            lineHeight: 1.25
        }

        Item {
            width: 1
            height: 6
        }

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 8

            Rectangle {
                visible: root.showStartAction
                width: startLabel.implicitWidth + 28
                height: 28
                radius: 6
                color: startMouse.containsMouse ? Qt.lighter(Theme.accent, 1.1) : Theme.accent

                Text {
                    id: startLabel
                    anchors.centerIn: parent
                    text: "Start Capture"
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSize
                    font.weight: Font.DemiBold
                    color: "white"
                }

                MouseArea {
                    id: startMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: root.startCaptureRequested()
                }
            }

            Rectangle {
                visible: root.showOpenAction
                width: openLabel.implicitWidth + 28
                height: 28
                radius: 6
                color: openMouse.containsMouse
                    ? Qt.rgba(Theme.label.r, Theme.label.g, Theme.label.b, 0.06)
                    : "transparent"
                border.width: 1
                border.color: Theme.separator

                Text {
                    id: openLabel
                    anchors.centerIn: parent
                    text: "Open Capture…"
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSize
                    color: Theme.label
                }

                MouseArea {
                    id: openMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: root.openFileRequested()
                }
            }
        }
    }
}
