import QtQuick
import QtQuick.Controls
import Omarchy.TCPViewer

// Spike #2 variant B (chosen): Qt Quick Controls TableView with cell delegates.
// Same data stream and column layout as the rejected ListView variant; see
// app/design/spike-2.md for measurements. This is the base of the production
// packet table.
Item {
    id: root

    required property PacketListModel model
    property bool follow: true

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
        default: return ""
        }
    }

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
            required property int row
            required property int column
            required property var model

            implicitHeight: Theme.packetRowHeight
            color: row % 2 === 1 ? Theme.rowAlternate : "transparent"

            Text {
                anchors.fill: parent
                anchors.leftMargin: 5
                anchors.rightMargin: 4
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                text: root.readRole(model, root.columns[column].role)
                color: Theme.isSecondary(root.columns[column].role) ? Theme.secondaryLabel : Theme.label
                font.family: Theme.monoFont
                font.pixelSize: Theme.packetFontSize
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
