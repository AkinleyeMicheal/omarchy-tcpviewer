import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Omarchy.TCPViewer

// Endpoint statistics window (upstream EndpointStatisticsWindowController):
// one pane per endpoint group, search field, sortable table with per-group
// column layouts, row context actions, and a footer totals strip.
Window {
    id: window

    // Raised after Show Related Packets applies a scope; the main window
    // comes forward on the packets view (upstream activateForNavigation).
    signal relatedRequested()

    required property EndpointStatisticsModel stats
    required property SessionController session

    width: 1240
    height: 700
    minimumWidth: 960
    minimumHeight: 480
    color: Theme.windowBackground
    title: "Endpoint Statistics"

    // Upstream refreshes while capture stays live; 2 s bounds the cost.
    Timer {
        interval: 2000
        running: window.visible
        repeat: true
        onTriggered: window.stats.rebuild(window.session.packets)
    }

    // Twelve wire-order columns; visibility and widths are per group
    // (upstream keeps one column store per endpoint group).
    readonly property int columnTotal: 12
    property var columnState: []
    // Multi-selection tracked by row key so it survives the live rebuilds
    // (upstream keys selections by EndpointStatisticsRow.ID).
    property var selectedKeys: []
    property int selectionAnchor: -1

    function defaultState() {
        const state = []
        for (let group = 0; group < 6; ++group) {
            const visible = []
            const widths = []
            for (let column = 0; column < columnTotal; ++column) {
                visible.push(stats.columnDefaultVisible(column, group))
                widths.push(stats.columnDefaultWidth(column))
            }
            state.push({visible: visible, widths: widths})
        }
        return state
    }

    // Merge the persisted layout over the defaults; malformed entries fall
    // back per column (the C++ side already bounds every stored value).
    function loadLayout() {
        const saved = session.endpointColumnLayout()
        const merged = defaultState()
        for (let group = 0; group < 6; ++group) {
            const entry = saved[String(group)]
            if (!entry || !entry.visible || !entry.widths)
                continue
            for (let column = 0; column < columnTotal; ++column) {
                if (typeof entry.visible[column] === "boolean")
                    merged[group].visible[column] = entry.visible[column]
                if (typeof entry.widths[column] === "number")
                    merged[group].widths[column] = entry.widths[column]
            }
        }
        columnState = merged
    }

    function persistLayout() {
        const out = {}
        for (let group = 0; group < 6; ++group)
            out[String(group)] = columnState[group]
        session.setEndpointColumnLayout(out)
    }

    function resetColumns() {
        const state = columnState.slice()
        state[stats.group] = (() => {
            const visible = []
            const widths = []
            for (let column = 0; column < columnTotal; ++column) {
                visible.push(stats.columnDefaultVisible(column, stats.group))
                widths.push(stats.columnDefaultWidth(column))
            }
            return {visible: visible, widths: widths}
        })()
        columnState = state
        persistLayout()
    }

    // Visible column ids for the active group, then prefix sums of widths so
    // headers and cells track the body's horizontal scroll (packet-table
    // offsets pattern).
    readonly property var visibleColumns: {
        const state = columnState[stats.group]
        const columns = []
        for (let i = 0; i < columnTotal; ++i)
            if (!state || state.visible[i])
                columns.push(i)
        return columns
    }
    readonly property var offsets: {
        const state = columnState[stats.group]
        const result = []
        let x = 0
        for (let i = 0; i < visibleColumns.length; ++i) {
            result.push(x)
            const column = visibleColumns[i]
            x += state ? state.widths[column] : stats.columnDefaultWidth(column)
        }
        result.push(x)
        return result
    }
    readonly property real tableWidth: offsets.length > 0
        ? offsets[offsets.length - 1] : 0
    readonly property var groupTitles: [
        "Apps", "Domains", "IPv4", "IPv6", "TCP", "UDP"
    ]

    // Visible column id at a viewport x, or -1 outside any column.
    function columnAt(viewportX) {
        const x = viewportX + table.contentX
        for (let i = 0; i < visibleColumns.length; ++i) {
            if (x >= offsets[i] && x < offsets[i + 1])
                return visibleColumns[i]
        }
        return -1
    }

    function openAndRaise() {
        stats.rebuild(session.packets)
        show()
        requestActivate()
    }

    // Selection: plain click selects one row, Ctrl+click toggles,
    // Shift+click extends from the anchor (packet-table selection model).
    function clickRow(index, key, modifiers) {
        if (modifiers & Qt.ShiftModifier) {
            const from = selectionAnchor >= 0 ? Math.min(selectionAnchor, index) : index
            const to = selectionAnchor >= 0 ? Math.max(selectionAnchor, index) : index
            const keys = []
            for (let i = from; i <= to; ++i) {
                const k = stats.keyAt(i)
                if (k !== "" && keys.indexOf(k) < 0)
                    keys.push(k)
            }
            selectedKeys = keys
        } else if (modifiers & Qt.ControlModifier) {
            const next = selectedKeys.slice()
            const at = next.indexOf(key)
            if (at >= 0)
                next.splice(at, 1)
            else
                next.push(key)
            selectedKeys = next
            selectionAnchor = index
        } else {
            selectedKeys = [key]
            selectionAnchor = index
        }
    }

    // Menu targets: the whole selection when the clicked row is in it,
    // otherwise the clicked row alone (upstream targetSelection).
    function targetKeys(clickedKey) {
        return selectedKeys.indexOf(clickedKey) >= 0 ? selectedKeys : [clickedKey]
    }

    function allKeys() {
        const keys = []
        for (let i = 0; i < stats.count; ++i)
            keys.push(stats.keyAt(i))
        return keys
    }

    function copyRowsCsv(keys) {
        const value = stats.rowsAsCsv(keys, visibleColumns)
        if (value !== "")
            session.copyPlainText(value)
    }

    function copyRowsJson(keys) {
        const value = stats.rowsAsJson(keys, visibleColumns)
        if (value !== "")
            session.copyPlainText(value)
    }

    function copyCell(key, columnId) {
        const row = stats.rawRow(key)
        if (!row.valid || row.multiple[columnId])
            return
        const value = String(row[stats.columnJsonKey(columnId)])
        if (value !== "")
            session.copyPlainText(value)
    }

    // Semantic field copies (0 address, 1 domain, 2 client): joined unique
    // copyable values across the target rows.
    function copySemantic(field, keys) {
        const value = stats.joinedValues(keys, field)
        if (value !== "")
            session.copyPlainText(value)
    }

    // Show Related Packets: the closest sidebar scope with the exact match
    // kept in the packet view (transport rows scope All Packets plus a
    // display filter).
    function showRelatedPackets(key) {
        const scope = stats.relatedScope(key)
        if (!scope)
            return
        if (scope.nodeId && scope.nodeId !== "")
            session.selectTreeFilter(scope.nodeId)
        if (scope.filter && scope.filter !== "")
            session.applyFilter(scope.filter)
        relatedRequested()
    }

    // Upstream ⌘C on the table copies the selected rows as CSV; text fields
    // keep their own copy shortcut when they hold focus.
    Shortcut {
        sequence: "Ctrl+C"
        enabled: window.visible
            && window.selectedKeys.length > 0
            && !(window.activeFocusItem instanceof TextInput)
            && !(window.activeFocusItem instanceof TextArea)
        onActivated: window.copyRowsCsv(window.selectedKeys)
    }

    Shortcut {
        sequence: "Ctrl+F"
        enabled: window.visible
        onActivated: searchField.forceActiveFocus()
    }

    // Column visibility menu (upstream column store menu): one checkable
    // entry per column plus a reset back to the group defaults.
    Menu {
        id: columnMenu

        function toggleColumn(columnId, checked) {
            const state = window.columnState.slice()
            const group = state[window.stats.group]
            const visible = group.visible.slice()
            visible[columnId] = checked
            state[window.stats.group] = Object.assign({}, group, {visible: visible})
            window.columnState = state
            window.persistLayout()
        }

        Repeater {
            model: window.columnTotal

            delegate: MenuItem {
                required property int modelData
                text: window.stats.columnTitle(modelData)
                checkable: true
                checked: window.columnState[window.stats.group]
                    ? window.columnState[window.stats.group].visible[modelData] : true
                onToggled: columnMenu.toggleColumn(modelData, checked)
            }
        }

        MenuSeparator {}

        MenuItem {
            text: qsTr("Reset Columns")
            onTriggered: window.resetColumns()
        }
    }

    // Row actions (upstream updateContextMenu).
    Menu {
        id: rowMenu
        property string pendingKey: ""
        property int pendingColumn: -1
        readonly property var targets: window.selectedKeys.indexOf(pendingKey) >= 0
            ? window.selectedKeys : (pendingKey !== "" ? [pendingKey] : [])
        readonly property var pendingRow: pendingKey !== "" ? window.stats.rawRow(pendingKey) : ({})

        function openFor(key, columnId) {
            pendingKey = key
            pendingColumn = columnId
            popup()
        }

        MenuItem {
            text: qsTr("Show Related Packets")
            enabled: rowMenu.pendingKey !== ""
            onTriggered: window.showRelatedPackets(rowMenu.pendingKey)
        }

        MenuSeparator {}

        MenuItem {
            text: qsTr("Copy Cell")
            enabled: rowMenu.pendingRow.valid
                && rowMenu.pendingColumn >= 0
                && !rowMenu.pendingRow.multiple[rowMenu.pendingColumn]
                && String(rowMenu.pendingRow[window.stats.columnJsonKey(rowMenu.pendingColumn)] ?? "") !== ""
            onTriggered: window.copyCell(rowMenu.pendingKey, rowMenu.pendingColumn)
        }

        MenuItem {
            text: qsTr("Copy Address")
            enabled: rowMenu.targets.length > 0
                && window.stats.joinedValues(rowMenu.targets, 0) !== ""
            onTriggered: window.copySemantic(0, rowMenu.targets)
        }

        MenuItem {
            text: qsTr("Copy Domain")
            enabled: rowMenu.targets.length > 0
                && window.stats.joinedValues(rowMenu.targets, 1) !== ""
            onTriggered: window.copySemantic(1, rowMenu.targets)
        }

        MenuItem {
            text: qsTr("Copy App")
            enabled: rowMenu.targets.length > 0
                && window.stats.joinedValues(rowMenu.targets, 2) !== ""
            onTriggered: window.copySemantic(2, rowMenu.targets)
        }

        MenuSeparator {}

        MenuItem {
            text: qsTr("Copy Selected Rows as CSV")
            enabled: rowMenu.targets.length > 0
            onTriggered: window.copyRowsCsv(rowMenu.targets)
        }

        MenuItem {
            text: qsTr("Copy Selected Rows as JSON")
            enabled: rowMenu.targets.length > 0
            onTriggered: window.copyRowsJson(rowMenu.targets)
        }

        MenuItem {
            text: qsTr("Copy All Rows as CSV")
            enabled: window.stats.count > 0
            onTriggered: window.copyRowsCsv(window.allKeys())
        }

        MenuItem {
            text: qsTr("Copy All Rows as JSON")
            enabled: window.stats.count > 0
            onTriggered: window.copyRowsJson(window.allKeys())
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Group tabs with live counts, search field on the right -----------
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 40
            color: Theme.headerBackground

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 6

                Repeater {
                    model: window.groupTitles

                    delegate: Rectangle {
                        id: groupTab
                        required property string modelData
                        required property int index
                        readonly property bool selected: stats.group === index
                        readonly property int count: stats.groupCounts[index] || 0

                        width: pill.implicitWidth + 24
                        height: 26
                        radius: 6
                        color: selected ? Theme.selection : Theme.contentBackground
                        border.width: selected ? 0 : 1
                        border.color: Theme.separator

                        Text {
                            id: pill
                            anchors.centerIn: parent
                            text: groupTab.modelData + " (" + groupTab.count + ")"
                            font.family: Theme.uiFont
                            font.pixelSize: Theme.uiSmall
                            font.weight: groupTab.selected ? Font.DemiBold : Font.Normal
                            color: groupTab.selected ? Theme.contentBackground : Theme.label
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: stats.group = index
                        }
                    }
                }

                Item { Layout.fillWidth: true }

                TextField {
                    id: searchField
                    placeholderText: qsTr("Search endpoints (Ctrl+F)")
                    text: stats.searchText
                    onTextEdited: stats.searchText = text
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSmall
                    implicitWidth: 220
                    // Clear the field instead of navigating away on Escape.
                    Keys.onEscapePressed: {
                        if (text !== "")
                            clear()
                        else
                            focus = false
                    }
                }
            }
        }

        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.separator }

        // Table ---------------------------------------------------------------
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            // Pinned header row: cells track the body's horizontal scroll.
            Rectangle {
                id: headerRow
                width: parent.width
                height: 24
                color: Theme.headerBackground
                z: 2
                clip: true

                Repeater {
                    model: window.visibleColumns

                    delegate: Item {
                        id: headerCell
                        required property int modelData
                        required property int index
                        x: window.offsets[index] - table.contentX
                        width: window.offsets[index + 1] - window.offsets[index]
                        height: headerRow.height

                        readonly property bool sortedUp: stats.sortColumn === modelData
                            && stats.sortAscending
                        readonly property bool sortedDown: stats.sortColumn === modelData
                            && !stats.sortAscending

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 5
                            anchors.right: sortGlyph.visible ? sortGlyph.left : parent.right
                            anchors.rightMargin: 4
                            anchors.verticalCenter: parent.verticalCenter
                            text: stats.columnTitle(headerCell.modelData)
                            font.family: Theme.uiFont
                            font.pixelSize: Theme.uiSmall
                            font.weight: Font.DemiBold
                            color: Theme.secondaryLabel
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }

                        Text {
                            id: sortGlyph
                            anchors.right: parent.right
                            anchors.rightMargin: 4
                            anchors.verticalCenter: parent.verticalCenter
                            visible: headerCell.sortedUp || headerCell.sortedDown
                            text: headerCell.sortedUp ? "▲" : "▼"
                            font.family: Theme.uiFont
                            font.pixelSize: Theme.uiSmall
                            color: Theme.secondaryLabel
                        }

                        // Header click sorts (same column toggles direction);
                        // the right edge resizes; right-click opens the
                        // column menu.
                        MouseArea {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            anchors.right: resizeHandle.left
                            cursorShape: Qt.PointingHandCursor
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            onClicked: (mouse) => {
                                if (mouse.button === Qt.RightButton) {
                                    columnMenu.popup()
                                    return
                                }
                                window.stats.clickSort(headerCell.modelData)
                            }
                        }

                        MouseArea {
                            id: resizeHandle
                            property int pressX: 0
                            property int pressWidth: 0
                            width: 6
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            cursorShape: Qt.SizeHorCursor
                            onPressed: (mouse) => {
                                pressX = mouse.x
                                pressWidth = window.columnState[window.stats.group].widths[headerCell.modelData]
                            }
                            onPositionChanged: (mouse) => {
                                const state = window.columnState.slice()
                                const group = state[window.stats.group]
                                const widths = group.widths.slice()
                                widths[headerCell.modelData] = Math.max(40,
                                    Math.min(1200, pressWidth + (mouse.x - pressX)))
                                state[window.stats.group] = Object.assign({}, group, {widths: widths})
                                window.columnState = state
                            }
                            onReleased: window.persistLayout()
                        }
                    }
                }
            }

            ListView {
                id: table
                anchors.top: parent.top
                anchors.bottom: footer.top
                anchors.left: parent.left
                anchors.right: parent.right
                topMargin: headerRow.height
                clip: true
                model: window.stats
                contentWidth: window.tableWidth
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.HorizontalAndVerticalFlick
                ScrollBar.vertical: ScrollBar { }
                ScrollBar.horizontal: ScrollBar { }

                delegate: Rectangle {
                    id: rowDelegate
                    required property int index
                    required property string key
                    required property string address
                    required property string port
                    required property string protocol
                    required property string client
                    required property string domain
                    required property string packets
                    required property string bytes
                    required property string txPackets
                    required property string txBytes
                    required property string rxPackets
                    required property string rxBytes
                    required property string summary
                    // Span the full content width so right-edge columns stay
                    // clickable when the table is scrolled horizontally.
                    width: Math.max(table.width, window.tableWidth)
                    height: 22
                    color: window.selectedKeys.indexOf(key) >= 0
                        ? Theme.selection : (index % 2 === 1 ? Theme.rowAlternate : "transparent")

                    Repeater {
                        model: window.visibleColumns

                        delegate: Text {
                            required property int modelData
                            required property int index
                            x: window.offsets[index] - table.contentX
                            width: window.offsets[index + 1] - window.offsets[index]
                            height: 22
                            verticalAlignment: Text.AlignVCenter
                            leftPadding: 5
                            rightPadding: 8
                            textFormat: Text.PlainText
                            text: {
                                switch (modelData) {
                                case 0: return rowDelegate.address
                                case 1: return rowDelegate.port
                                case 2: return rowDelegate.protocol
                                case 3: return rowDelegate.client
                                case 4: return rowDelegate.domain
                                case 5: return rowDelegate.packets
                                case 6: return rowDelegate.bytes
                                case 7: return rowDelegate.txPackets
                                case 8: return rowDelegate.txBytes
                                case 9: return rowDelegate.rxPackets
                                case 10: return rowDelegate.rxBytes
                                default: return rowDelegate.summary
                                }
                            }
                            font.family: modelData < 5 ? Theme.uiFont : Theme.monoFont
                            font.pixelSize: Theme.uiSmall
                            color: window.selectedKeys.indexOf(rowDelegate.key) >= 0
                                ? Theme.contentBackground
                                : (modelData >= 5 ? Theme.secondaryLabel : Theme.label)
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        onClicked: (mouse) => {
                            if (mouse.button === Qt.RightButton) {
                                // Context targets follow upstream: the whole
                                // selection when it contains the clicked row.
                                rowMenu.openFor(rowDelegate.key, window.columnAt(mouse.x))
                                return
                            }
                            window.clickRow(index, rowDelegate.key, mouse.modifiers)
                        }
                        onDoubleClicked: window.showRelatedPackets(rowDelegate.key)
                    }
                }

                // Upstream placeholder when nothing flows yet.
                Column {
                    anchors.centerIn: parent
                    spacing: 8
                    visible: stats.count === 0

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "⇄"
                        font.family: Theme.uiFont
                        font.pixelSize: 30
                        color: Theme.secondaryLabel
                        opacity: 0.5
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: qsTr("No Traffic")
                        font.family: Theme.uiFont
                        font.pixelSize: Theme.uiSize
                        font.weight: Font.DemiBold
                        color: Theme.label
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: qsTr("Endpoints appear here once traffic is captured or a file is opened.")
                        font.family: Theme.uiFont
                        font.pixelSize: Theme.uiSmall
                        color: Theme.secondaryLabel
                    }
                }
            }

            // Column-count fused footer: totals strip under the table.
            Rectangle {
                id: footer
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 24
                color: Theme.headerBackground

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: window.stats.footerText
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSmall
                    color: Theme.secondaryLabel
                    elide: Text.ElideMiddle
                    width: parent.width - 20
                }
            }
        }
    }
}
