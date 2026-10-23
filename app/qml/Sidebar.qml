import QtQuick
import QtQuick.Controls
import Omarchy.TCPViewer

// Upstream sidebar shell (SidebarViewController). The full packet-source tree
// (Capture/Files/All → Apps/Domains) is being rebuilt incrementally; this
// milestone lists live and offline sources with the upstream group styling.
Rectangle {
    id: root

    required property SessionController session

    color: Theme.dark ? "#232323" : "#f6f6f6"

    function basename(path) {
        var value = String(path || "")
        var slash = value.lastIndexOf("/")
        return slash >= 0 ? value.substring(slash + 1) : value
    }

    function sourceKind(source) {
        return String(source.kind || "")
    }

    readonly property var liveSources: {
        var result = []
        for (var i = 0; i < session.sources.length; ++i) {
            if (sourceKind(session.sources[i]) === "live")
                result.push(session.sources[i])
        }
        return result
    }

    readonly property var fileSources: {
        var result = []
        for (var i = 0; i < session.sources.length; ++i) {
            var kind = sourceKind(session.sources[i])
            if (kind !== "live")
                result.push(session.sources[i])
        }
        return result
    }

    Flickable {
        anchors.fill: parent
        contentHeight: tree.height + 12
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: tree
            width: parent.width
            y: 8

            GroupHeader { text: "Capture" }

            Repeater {
                model: root.liveSources
                delegate: SourceRow {
                    required property var modelData
                    width: tree.width
                    source: modelData
                }
            }

            SidebarPlaceholder {
                visible: root.liveSources.length === 0
                width: tree.width
                text: "No live capture"
            }

            GroupHeader { text: "Files" }

            Repeater {
                model: root.fileSources
                delegate: SourceRow {
                    required property var modelData
                    width: tree.width
                    source: modelData
                }
            }

            SidebarPlaceholder {
                visible: root.fileSources.length === 0
                width: tree.width
                text: "No open files"
            }

            GroupHeader { text: "All" }

            SidebarPlaceholder {
                width: tree.width
                text: "Apps"
                iconText: "▤"
                disabledRow: true
            }
            SidebarPlaceholder {
                width: tree.width
                text: "Domains"
                iconText: "◍"
                disabledRow: true
            }
        }
    }

    component GroupHeader: Item {
        id: header

        property string text

        width: parent ? parent.width : 0
        height: 26

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            text: header.text
            font.family: Theme.uiFont
            font.pixelSize: Theme.uiSmall
            font.weight: Font.DemiBold
            color: Theme.secondaryLabel
        }
    }

    component SidebarPlaceholder: Item {
        id: placeholder

        property string text
        property string iconText: ""
        property bool disabledRow: false

        width: parent ? parent.width : 0
        height: 28

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            text: placeholder.iconText
            visible: placeholder.iconText !== ""
            font.family: Theme.uiFont
            font.pixelSize: Theme.uiSmall
            color: Theme.secondaryLabel
            opacity: 0.7
        }

        Text {
            anchors.left: parent.left
            anchors.leftMargin: placeholder.iconText !== "" ? 38 : 20
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: placeholder.text
            elide: Text.ElideRight
            font.family: Theme.uiFont
            font.pixelSize: Theme.uiSize
            color: Theme.secondaryLabel
            opacity: 0.75
        }
    }

    component SourceRow: Item {
        id: row

        required property var source

        height: Theme.sidebarRowHeight

        readonly property bool selected: root.session.currentSourceID === String(source.source_id)
        readonly property bool isLive: String(source.kind) === "live"
        readonly property string title: isLive
            ? "Live: " + String(source.interface || "Capture")
            : root.basename(source.path)
        readonly property bool hovered: mouse.containsMouse

        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            radius: 6
            color: row.selected
                ? Theme.selection
                : (row.hovered ? Qt.rgba(Theme.label.r, Theme.label.g, Theme.label.b, 0.06)
                               : "transparent")
        }

        Text {
            id: glyph
            anchors.left: parent.left
            anchors.leftMargin: 18
            anchors.verticalCenter: parent.verticalCenter
            text: row.isLive ? "●" : "▤"
            font.family: Theme.uiFont
            font.pixelSize: row.isLive ? 9 : 12
            color: row.selected ? "white" : (row.isLive ? Theme.systemGreen : Theme.secondaryLabel)
        }

        Text {
            anchors.left: glyph.right
            anchors.leftMargin: 8
            anchors.right: countLabel.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: row.title
            textFormat: Text.PlainText
            elide: Text.ElideMiddle
            font.family: Theme.uiFont
            font.pixelSize: Theme.uiSize
            color: row.selected ? "white" : Theme.label
        }

        Text {
            id: countLabel
            anchors.right: parent.right
            anchors.rightMargin: 22
            anchors.verticalCenter: parent.verticalCenter
            text: Number(source.packet_count || 0).toLocaleString(Qt.locale(), "f", 0)
            font.family: Theme.monoFont
            font.pixelSize: Theme.uiSmall
            color: row.selected ? Qt.rgba(1, 1, 1, 0.8) : Theme.secondaryLabel
        }

        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton
            onClicked: root.session.selectSource(String(row.source.source_id))
        }

        Rectangle {
            id: closeButton
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            width: 16
            height: 16
            radius: 8
            visible: row.hovered && !row.isLive
            color: closeMouse.containsMouse ? Qt.rgba(0, 0, 0, 0.12) : "transparent"

            Text {
                anchors.centerIn: parent
                text: "×"
                font.family: Theme.uiFont
                font.pixelSize: 12
                color: row.selected ? "white" : Theme.secondaryLabel
            }

            MouseArea {
                id: closeMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: root.session.closeSource(String(row.source.source_id))
            }
        }
    }
}
