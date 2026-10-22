import QtQuick
import QtQuick.Controls
import Omarchy.TCPViewer

// Spike #2 variant A (rejected): ListView with a composite row delegate.
// Retained because the benchmark harness measures both table implementations;
// the production table is PacketTableView.qml (see app/design/spike-2.md).
//
// Upstream-faithful packet table body: fixed-height rows, alternating
// backgrounds, monospaced cells, and centered protocol pills
// (PacketTableCells.swift / PacketTablePresentation.swift).
Item {
    id: root

    required property PacketListModel model
    property bool follow: true
    property int selectedIndex: -1
    signal rowClicked(int index)

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

    // Header -----------------------------------------------------------------
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

    // Rows -------------------------------------------------------------------
    ListView {
        id: list
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        reuseItems: true
        cacheBuffer: 480
        boundsBehavior: Flickable.StopAtBounds
        model: root.model

        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        delegate: Item {
            id: row

            required property int index
            required property int number
            required property string time
            required property string source
            required property string sourcePort
            required property string destination
            required property string destinationPort
            required property string protocol
            required property string client
            required property string domain
            required property string streamId
            required property int length
            required property string summary
            required property int severity

            width: ListView.view.width
            height: Theme.packetRowHeight

            function textFor(role) {
                switch (role) {
                case "number": return String(number)
                case "time": return time
                case "source": return source
                case "sourcePort": return sourcePort
                case "destination": return destination
                case "destinationPort": return destinationPort
                case "protocol": return protocol
                case "client": return client
                case "domain": return domain
                case "streamId": return streamId
                case "length": return String(length)
                case "summary": return summary
                default: return ""
                }
            }

            Rectangle {
                anchors.fill: parent
                color: index === root.selectedIndex
                       ? Qt.rgba(Theme.selection.r, Theme.selection.g, Theme.selection.b, 0.18)
                       : (index % 2 === 1 ? Theme.rowAlternate : "transparent")
            }

            MouseArea {
                anchors.fill: parent
                onClicked: root.rowClicked(row.index)
            }

            Repeater {
                model: root.columns

                delegate: Item {
                    id: cell

                    required property int index
                    required property var modelData

                    x: root.offsets[index]
                    width: root.cellWidth(index)
                    height: row.height

                    readonly property bool isProtocol: modelData.role === "protocol"
                    readonly property bool isSummary: modelData.role === "summary"
                    readonly property string text: row.textFor(modelData.role)

                    // Protocol pill (PacketProtocolCell.drawInterior)
                    Rectangle {
                        visible: cell.isProtocol
                        anchors.centerIn: parent
                        width: Math.min(Math.max(pillText.implicitWidth + 16, 42), cell.width - 12)
                        height: Math.min(cell.height - 4, Math.max(18, pillText.implicitHeight + 6))
                        radius: height / 2
                        color: Theme.protocolFill(row.protocol)
                    }

                    Text {
                        id: pillText
                        visible: cell.isProtocol
                        anchors.centerIn: parent
                        text: cell.text
                        color: Theme.protocolTint(row.protocol)
                        font.family: Theme.monoFont
                        font.pixelSize: Theme.packetFontSize
                        font.weight: Font.DemiBold
                    }

                    Text {
                        visible: !cell.isProtocol
                        anchors.fill: parent
                        anchors.leftMargin: 5
                        anchors.rightMargin: 4
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                        text: cell.text
                        color: cell.isSummary && row.severity !== 0
                               ? Theme.systemOrange
                               : (Theme.isSecondary(cell.modelData.role) ? Theme.secondaryLabel : Theme.label)
                        font.family: Theme.monoFont
                        font.pixelSize: Theme.packetFontSize
                    }
                }
            }
        }

        Connections {
            target: root.model
            function onRowsInserted() {
                if (root.follow)
                    Qt.callLater(list.positionViewAtEnd)
            }
        }
    }
}
