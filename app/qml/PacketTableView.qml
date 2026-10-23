import QtQuick
import QtQuick.Controls
import Omarchy.TCPViewer

// Production packet table (Spike #2 decision): Qt Quick Controls TableView with
// per-cell delegates, virtualized and reused. Reproduces the upstream row
// metrics, alternating backgrounds, secondary text colors, and protocol pills
// (PacketTablePresentation.swift / PacketTableCells.swift).
Item {
    id: root

    required property PacketListModel model
    property bool follow: true
    property int selectedIndex: -1

    signal rowClicked(int index)
    signal rowActivated(int index)
    signal rowContextClicked(int index, real globalX, real globalY)

    readonly property var columns: {
        var result = []
        for (var i = 0; i < Theme.columns.length; ++i) {
            if (Theme.columns[i].visible)
                result.push(Theme.columns[i])
        }
        return result
    }

    readonly property var offsets: {
        var result = []
        var x = 0
        for (var i = 0; i < columns.length; ++i) {
            result.push(x)
            x += columns[i].width
        }
        return result
    }

    function cellWidth(index) {
        var column = columns[index]
        if (index === columns.length - 1)
            return Math.max(column.width, width - offsets[index])
        return column.width
    }

    function readRole(item, role) {
        switch (role) {
        case "number": return String(item.number)
        case "packetId": return item.packetId
        case "time": return item.time
        case "source": return item.source
        case "sourcePort": return item.sourcePort
        case "destination": return item.destination
        case "destinationPort": return item.destinationPort
        case "protocol": return item.protocol
        case "client": return item.client
        case "domain": return item.domain
        case "streamId": return item.streamId
        case "length": return String(item.length)
        case "summary": return item.summary
        case "tcpFlags": return item.tcpFlags
        case "direction": return item.direction
        case "interface": return item.interface
        case "decodeStatus": return item.decodeStatus
        case "sourceKind": return item.sourceKind
        case "tcpPayloadLength": return String(item.tcpPayloadLength)
        default: return ""
        }
    }

    Component.onCompleted: root.model.setColumnCount(root.columns.length)
    onColumnsChanged: root.model.setColumnCount(root.columns.length)

    Rectangle {
        id: header
        anchors.top: parent.top
        width: parent.width
        height: 24
        color: Theme.headerBackground

        Repeater {
            model: root.columns
            delegate: Item {
                required property int index
                required property var modelData
                x: root.offsets[index]
                width: root.cellWidth(index)
                height: header.height

                Text {
                    anchors.fill: parent
                    anchors.leftMargin: 5
                    anchors.rightMargin: 4
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    text: modelData.title
                    color: Theme.secondaryLabel
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSmall
                    font.weight: Font.DemiBold
                }

                Rectangle {
                    anchors.right: parent.right
                    width: 1
                    height: parent.height - 8
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.separator
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

    TableView {
        id: table
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        reuseItems: true
        model: root.model
        columnWidthProvider: function(column) { return root.cellWidth(column) }
        rowHeightProvider: function(row) { return Theme.packetRowHeight }

        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        delegate: Rectangle {
            id: cell

            required property int row
            required property int column
            required property var model

            readonly property var columnData: root.columns[column]
            readonly property bool isProtocol: columnData.role === "protocol"
            readonly property string cellText: root.readRole(model, columnData.role)
            readonly property bool isSecondary: Theme.isSecondary(columnData.role)
            readonly property bool isSummary: columnData.role === "summary"

            implicitHeight: Theme.packetRowHeight
            color: row === root.selectedIndex
                ? Qt.rgba(Theme.selection.r, Theme.selection.g, Theme.selection.b, 0.18)
                : (row % 2 === 1 ? Theme.rowAlternate : "transparent")

            Rectangle {
                visible: cell.isProtocol
                anchors.centerIn: parent
                width: Math.min(Math.max(pillLabel.implicitWidth + 16, 42), cell.width - 12)
                height: Math.min(cell.height - 4, Math.max(18, pillLabel.implicitHeight + 6))
                radius: height / 2
                color: Theme.protocolFill(model.protocol)

                Text {
                    id: pillLabel
                    anchors.centerIn: parent
                    text: cell.cellText
                    textFormat: Text.PlainText
                    color: Theme.protocolTint(model.protocol)
                    font.family: Theme.monoFont
                    font.pixelSize: Theme.packetFontSize
                    font.weight: Font.DemiBold
                }
            }

            Text {
                visible: !cell.isProtocol
                anchors.fill: parent
                anchors.leftMargin: 5
                anchors.rightMargin: 4
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                text: cell.cellText
                textFormat: Text.PlainText
                color: cell.isSummary && model.severity !== 0
                    ? Theme.systemOrange
                    : (cell.isSecondary ? Theme.secondaryLabel : Theme.label)
                font.family: Theme.monoFont
                font.pixelSize: Theme.packetFontSize
            }

            MouseArea {
                anchors.fill: parent
                // Right-click raises the downstream context menu (Follow Stream, …).
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onPressed: (mouse) => {
                    if (mouse.button === Qt.RightButton) {
                        root.selectedIndex = cell.row
                        mouse.accepted = true
                        root.rowContextClicked(cell.row, mouse.globalX, mouse.globalY)
                    }
                }
                onClicked: (mouse) => {
                    if (mouse.button === Qt.LeftButton) {
                        root.selectedIndex = cell.row
                        root.rowClicked(cell.row)
                    }
                }
                onDoubleClicked: root.rowActivated(cell.row)
            }
        }

        Connections {
            target: root.model
            function onRowsInserted() {
                if (root.follow)
                    Qt.callLater(function() {
                        table.contentY = Math.max(0, table.contentHeight - table.height)
                    })
            }
        }
    }
}
