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
    required property PacketColumnLayout columnLayout
    required property PacketCustomColumns customColumns
    property bool follow: true
    property int selectedIndex: -1

    signal rowClicked(int index)
    signal rowActivated(int index)
    signal rowContextClicked(int index, real globalX, real globalY, string columnID)

    readonly property var columns: columnLayout.columns
    readonly property int customRevision: customColumns.revision

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

    // Header drag-reorder state (dropIndicator + headers read these).
    property string dragColumnID: ""
    property real dragOffsetX: 0
    property real dropX: 0
    property int dropSlot: -1
    readonly property bool dragActive: dragColumnID !== ""

    function beginColumnDrag(columnID) {
        dragColumnID = columnID
        dropSlot = -1
        dropX = 0
    }

    function updateColumnDrag(draggedIndex, grabX, mouseLocalX) {
        dragOffsetX = mouseLocalX - grabX
        // Pointer position in content space, then a boundary slot among the
        // other movable columns by their midpoints (insert-before rule).
        const pointerContentX = offsets[draggedIndex] + mouseLocalX
        var others = []
        for (var i = 0; i < columns.length; ++i) {
            if (i === draggedIndex || columns[i].id === "comment")
                continue
            others.push(i)
        }
        var slot = others.length
        for (var j = 0; j < others.length; ++j) {
            var midpoint = offsets[others[j]] + cellWidth(others[j]) / 2
            if (pointerContentX < midpoint) {
                slot = j
                break
            }
        }
        dropSlot = slot
        dropX = slot < others.length
            ? offsets[others[slot]]
            : (offsets[others[others.length - 1]] + cellWidth(others[others.length - 1]))
    }

    function finishColumnDrag() {
        if (dragColumnID !== "" && dropSlot >= 0) {
            // moveColumn persists and emits columnsChanged; the offsets and
            // header repeater rebuild from the new order.
            columnLayout.moveColumn(dragColumnID, dropSlot)
        }
        dragColumnID = ""
        dragOffsetX = 0
        dropSlot = -1
        dropX = 0
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
        case "deltaTime": return item.deltaTime
        case "streamDeltaTime": return item.streamDeltaTime
        case "clientPid": return item.clientPid > 0 ? String(item.clientPid) : ""
        case "bundleIdentifier": return item.bundleIdentifier
        case "comment": return item.comment
        case "tags": return item.tags
        default: return ""
        }
    }

    Component.onCompleted: root.model.setColumnCount(root.columns.length)
    onColumnsChanged: {
        root.model.setColumnCount(root.columns.length)
        table.forceLayout()
    }

    Rectangle {
        id: header
        anchors.top: parent.top
        width: parent.width
        height: 24
        color: Theme.headerBackground
        clip: true

        // Drop indicator for a header drag (upstream NSTableView column
        // dragging): a 2 px insertion line at the candidate boundary.
        Rectangle {
            id: dropIndicator
            visible: root.dragActive
            height: parent.height - 6
            anchors.verticalCenter: parent.verticalCenter
            width: 2
            radius: 1
            color: Theme.accent
            x: root.dropX - table.contentX
        }

        // Header context menu (upstream PacketTableColumnVisibilityMenuController).
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.RightButton
            onClicked: (mouse) => {
                columnMenu.x = Math.min(mouse.x, Math.max(0, root.width - columnMenu.width))
                columnMenu.y = header.height
                columnMenu.open()
            }
        }

        Repeater {
            model: root.columns
            delegate: Item {
                id: headerCell

                required property int index
                required property var modelData
                // Track the body's horizontal scroll: when the TableView pans
                // left/right, headers must slide with their columns or the
                // field above a cell stops naming it.
                x: root.offsets[index] - table.contentX
                width: root.cellWidth(index)
                height: header.height

                // While this column is dragged, the pointer offsets it and
                // the drop line shows the candidate boundary.
                readonly property bool dragging: root.dragColumnID === modelData.id
                readonly property real dragOffset: dragging ? root.dragOffsetX : 0

                Text {
                    anchors.fill: parent
                    anchors.leftMargin: 5 + headerCell.dragOffset
                    anchors.rightMargin: 4
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    text: modelData.title
                    textFormat: Text.PlainText
                    color: headerCell.dragging ? Theme.accent : Theme.secondaryLabel
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSmall
                    font.weight: Font.DemiBold
                    opacity: headerCell.dragging ? 0.85 : 1
                }

                Rectangle {
                    anchors.right: parent.right
                    width: 1
                    height: parent.height - 8
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.separator
                }

                // Drag the header to reorder (upstream native column drag);
                // drag the divider to resize; the layout persists both. The
                // trailing Comment column is not movable.
                MouseArea {
                    id: headerDrag
                    anchors.fill: parent
                    cursorShape: Qt.DragMoveCursor
                    acceptedButtons: Qt.LeftButton
                    enabled: headerCell.modelData.id !== "comment"

                    property real grabX: 0

                    onPressed: (mouse) => {
                        grabX = mouse.x
                        root.beginColumnDrag(headerCell.modelData.id)
                    }
                    onPositionChanged: (mouse) => {
                        if (pressed && root.dragColumnID === headerCell.modelData.id)
                            root.updateColumnDrag(headerCell.index, grabX, mouse.x)
                    }
                    onReleased: root.finishColumnDrag()
                    onCanceled: root.finishColumnDrag()
                }

                // Drag the divider to resize; the layout persists the width.
                MouseArea {
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: 5
                    cursorShape: Qt.SplitHCursor
                    acceptedButtons: Qt.LeftButton
                    enabled: !headerCell.dragging
                    z: 2
                    property real startWidth: 0

                    onPressed: startWidth = modelData.width
                    onReleased: (mouse) => {
                        root.columnLayout.setColumnWidth(
                            modelData.id,
                            Math.max(modelData.minimumWidth, startWidth + mouse.x))
                    }
                    onDoubleClicked: root.columnLayout.resetColumnWidth(modelData.id)
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

    Menu {
        id: columnMenu
        width: 240

        Repeater {
            model: root.columnLayout.menuEntries
            delegate: MenuItem {
                required property var modelData
                text: modelData.title
                checkable: true
                checked: modelData.visible
                enabled: modelData.enabled
                onTriggered: root.columnLayout.toggleColumn(modelData.id)
            }
        }

        MenuSeparator {}

        MenuItem {
            text: qsTr("Reset All Columns")
            onTriggered: root.columnLayout.resetColumns()
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
        ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }

        delegate: Rectangle {
            id: cell

            required property int row
            required property int column
            required property var model

            readonly property var columnData: root.columns[column]
            readonly property bool isCustom: columnData && columnData.custom === true
            readonly property bool isProtocol: !isCustom && columnData.role === "protocol"
            readonly property string cellText: {
                if (isCustom) {
                    // Reading the revision keeps reused delegates bound to
                    // lazily resolved detail-field values.
                    root.customRevision
                    return root.customColumns.value(columnData.id, model.packetId)
                }
                return root.readRole(model, columnData.role)
            }
            readonly property bool isSecondary: !isCustom && Theme.isSecondary(columnData.role)
            readonly property bool isSummary: !isCustom && columnData.role === "summary"
            readonly property bool rowSelected: row === root.selectedIndex
            // Upstream PacketHighlightPalette: a highlighted row fills the
            // whole row (selected rows keep the selection paint over it).
            readonly property string rowHighlight: String(model.highlightColor || "")
            readonly property bool rowStrikethrough: model.strikethrough === true

            implicitHeight: Theme.packetRowHeight
            color: rowSelected
                ? Qt.rgba(Theme.selection.r, Theme.selection.g, Theme.selection.b, 0.18)
                : (rowHighlight !== ""
                    ? Theme.highlightRowColor(rowHighlight)
                    : (row % 2 === 1 ? Theme.rowAlternate : "transparent"))

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
                font.strikeout: cell.rowStrikethrough
            }

            MouseArea {
                anchors.fill: parent
                // Right-click raises the downstream context menu (Follow Stream, …).
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onPressed: (mouse) => {
                    if (mouse.button === Qt.RightButton) {
                        root.selectedIndex = cell.row
                        mouse.accepted = true
                        root.rowContextClicked(cell.row, mouse.globalX, mouse.globalY,
                            cell.columnData ? cell.columnData.id : "")
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
