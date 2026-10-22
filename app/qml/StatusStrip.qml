import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Omarchy.TCPViewer

// Bottom status strip (StatusStripViewController): Clear/Filter controls on
// the left, centered packet count, capture metrics on the right.
Rectangle {
    id: root

    required property SessionController session

    implicitHeight: Theme.statusStripHeight
    color: Theme.windowBackground

    function formattedCount(count) {
        return Number(count).toLocaleString(Qt.locale(), "f", 0)
    }

    readonly property string totalText: session.packets.count === 1
        ? "1 packet"
        : formattedCount(session.packets.count) + " packets"

    readonly property string metricsText: {
        var status = session.status
        var health = status.health || {}
        var dropped = Number(health.packets_dropped || 0)
        var parts = []
        if (session.capturePhase.length > 0)
            parts.push(session.capturePhase)
        if (dropped > 0)
            parts.push(formattedCount(dropped) + " dropped")
        return parts.join(" · ")
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 14
        anchors.rightMargin: 14
        spacing: 8

        StripButton {
            text: "Clear"
            enabled: session.packets.count > 0 && !session.loading
            onClicked: session.clearPackets()
        }

        Item { Layout.fillWidth: true }

        Text {
            Layout.alignment: Qt.AlignHCenter
            text: root.totalText
            font.family: Theme.monoFont
            font.pixelSize: Theme.uiSmall
            color: Theme.secondaryLabel
        }

        Item { Layout.fillWidth: true }

        Text {
            text: root.metricsText
            font.family: Theme.monoFont
            font.pixelSize: Theme.uiSmall
            color: Theme.secondaryLabel
        }
    }

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 1
        color: Theme.separator
    }

    component StripButton: Rectangle {
        id: button

        property string text
        signal clicked

        implicitWidth: label.implicitWidth + 20
        implicitHeight: 22
        radius: 5
        color: !button.enabled
            ? "transparent"
            : (buttonMouse.containsMouse
                ? Qt.rgba(Theme.label.r, Theme.label.g, Theme.label.b, 0.08)
                : "transparent")
        border.width: button.enabled ? 1 : 0
        border.color: Theme.separator
        opacity: button.enabled ? 1.0 : 0.45

        Text {
            id: label
            anchors.centerIn: parent
            text: button.text
            font.family: Theme.uiFont
            font.pixelSize: Theme.uiSmall
            color: Theme.label
        }

        MouseArea {
            id: buttonMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: button.enabled
            onClicked: button.clicked()
        }
    }
}
