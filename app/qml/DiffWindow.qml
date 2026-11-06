import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Omarchy.TCPViewer

// Diff window (upstream DiffWindowController): packet pool on the left,
// details text diff or byte hex diff on the right. Native Qt rendering per
// ADR-3 (Monaco/WebEngine deliberately deferred).
Window {
    id: window

    required property DiffController diff

    width: 1180
    height: 760
    minimumWidth: 820
    minimumHeight: 480
    color: Theme.windowBackground
    title: "Diff"
    visible: false

    property int changeCursor: -1
    // Byte-change navigation cursor (upstream currentChange, wrap-around).
    property int byteCursor: -1
    // Hex search bar state (upstream DiffBinaryViewController search bar).
    property bool searchActive: false
    property string searchSide: "left"
    property string searchStatus: ""

    readonly property color addTint: Qt.rgba(Theme.systemGreen.r, Theme.systemGreen.g,
                                             Theme.systemGreen.b, 0.16)
    readonly property color removeTint: Qt.rgba(Theme.systemRed.r, Theme.systemRed.g,
                                                Theme.systemRed.b, 0.16)
    readonly property color changeTint: Qt.rgba(Theme.systemOrange.r, Theme.systemOrange.g,
                                                Theme.systemOrange.b, 0.14)

    function openAndRaise() {
        show()
        raise()
        requestActivate()
        // CI/screenshot hook: step to the first change / open the hex search
        // once both sides' bytes have arrived.
        if (window.diff.startupStep || window.diff.startupSearch !== "")
            hookTimer.start()
    }

    Timer {
        id: hookTimer
        interval: 500
        onTriggered: {
            if (window.diff.startupSearch !== "") {
                window.openSearch()
                searchField.text = window.diff.startupSearch
                window.findNext()
            } else {
                window.navigate(false)
            }
        }
    }

    // Change count of the active comparison kind (drives Prev/Next).
    function navigateCount() {
        return window.diff.contentKind === "bytes"
            ? window.diff.byteChanges.length : window.diff.differenceCount
    }

    // Per-pane tint ranges of the byte edits.
    function byteHighlights(side) {
        const list = []
        const changes = window.diff.byteChanges
        for (let i = 0; i < changes.length; ++i) {
            const change = changes[i]
            const offset = side === "left" ? change.leftOffset : change.rightOffset
            const length = side === "left" ? change.leftLength : change.rightLength
            if (length > 0)
                list.push({offset: offset, length: length})
        }
        return list
    }

    function navigate(backwards) {
        if (!window.diff.ready)
            return
        if (window.diff.contentKind === "bytes") {
            if (window.diff.byteChanges.length === 0)
                return
            window.byteCursor = window.diff.nextByteChange(window.byteCursor, backwards)
            const change = window.diff.byteChanges[window.byteCursor]
            // Upstream revealCurrentChange selects and centers both panes.
            leftHexView.select(change.leftOffset, change.leftLength)
            rightHexView.select(change.rightOffset, change.rightLength)
            return
        }
        if (window.diff.differenceCount === 0)
            return
        window.changeCursor = window.diff.nextChangeRow(window.changeCursor, backwards)
        if (window.diff.displayMode === "unified")
            unifiedView.positionViewAtIndex(window.changeCursor, ListView.Center)
        else
            sideView.positionViewAtIndex(window.changeCursor, ListView.Center)
    }

    // Upstream showSearchBar/findNext/closeSearch (hex byte sequence search).
    function openSearch() {
        if (window.diff.contentKind !== "bytes" || !window.diff.ready)
            return
        window.searchActive = true
        searchField.forceActiveFocus()
        searchField.selectAll()
    }

    function closeSearch() {
        window.searchActive = false
        window.searchStatus = ""
    }

    function findNext() {
        if (!window.diff.ready)
            return
        const side = window.searchSide === "left" ? 0 : 1
        const view = side === 0 ? leftHexView : rightHexView
        const bytes = side === 0 ? window.diff.leftBytes : window.diff.rightBytes
        // Find Next continues after the current selection, wrapping around.
        const start = view.selectionOffset >= 0
            ? view.selectionOffset + view.selectionLength : 0
        const result = window.diff.findBytes(side, searchField.text,
                                             Math.min(start, bytes.length))
        if (result.error !== undefined) {
            window.searchStatus = result.error
            return
        }
        view.select(result.offset, result.length)
        window.searchStatus = "0x" + result.offset.toString(16).toUpperCase()
    }

    Shortcut {
        sequences: ["Escape"]
        onActivated: window.searchActive ? window.closeSearch() : window.close()
    }

    Shortcut {
        sequences: ["F7"]
        onActivated: window.navigate(false)
    }

    Shortcut {
        sequences: ["Shift+F7"]
        onActivated: window.navigate(true)
    }

    // Upstream ⌘F opens the binary view's hex search bar.
    Shortcut {
        sequences: ["Ctrl+F"]
        enabled: window.diff.contentKind === "bytes"
        onActivated: window.openSearch()
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Toolbar ---------------------------------------------------------------
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 44
            color: Theme.headerBackground

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 10

                Text {
                    text: "Diff"
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSize
                    font.weight: Font.DemiBold
                    color: Theme.label
                }

                SegmentPill {
                    labels: ["Packet Details", "Packet Bytes"]
                    value: window.diff.contentKind === "bytes" ? 1 : 0
                    onPicked: (index) => {
                        window.diff.contentKind = index === 0 ? "details" : "bytes"
                    }
                }

                SegmentPill {
                    labels: ["Side By Side", "Unified"]
                    value: window.diff.displayMode === "unified" ? 1 : 0
                    enabled: window.diff.contentKind === "details"
                    onPicked: (index) => {
                        window.diff.displayMode = index === 0 ? "sideBySide" : "unified"
                    }
                }

                Item { Layout.fillWidth: true }

                FlatButton {
                    text: "Prev"
                    enabled: window.navigateCount() > 0
                    onClicked: window.navigate(true)
                }
                FlatButton {
                    text: "Next"
                    enabled: window.navigateCount() > 0
                    onClicked: window.navigate(false)
                }
                FlatButton {
                    text: "Clear"
                    enabled: window.diff.pool.count > 0
                    onClicked: window.diff.clear()
                }
            }
        }

        // Body ------------------------------------------------------------------
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // Diff pool
            Rectangle {
                Layout.preferredWidth: 300
                Layout.fillHeight: true
                color: Theme.contentBackground

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 0

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 30
                        color: Theme.headerBackground

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Packets (" + window.diff.pool.count + ")"
                            font.family: Theme.uiFont
                            font.pixelSize: Theme.uiSmall
                            font.weight: Font.DemiBold
                            color: Theme.label
                        }
                    }

                    Text {
                        visible: window.diff.pool.count === 0
                        Layout.fillWidth: true
                        Layout.margins: 14
                        text: "Select a packet in the main table and press Ctrl+Y to add it here."
                        wrapMode: Text.WordWrap
                        textFormat: Text.PlainText
                        font.family: Theme.uiFont
                        font.pixelSize: Theme.uiSmall
                        color: Theme.secondaryLabel
                    }

                    ListView {
                        id: poolList
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        model: window.diff.pool
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds

                        delegate: Rectangle {
                            id: poolRow

                            required property string entryId
                            required property string packetId
                            required property int number
                            required property string summary
                            required property string side

                            width: poolList.width
                            height: 46
                            color: side !== ""
                                ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.14)
                                : (poolMouse.containsMouse
                                    ? Qt.rgba(Theme.label.r, Theme.label.g, Theme.label.b, 0.05)
                                    : "transparent")

                            MouseArea {
                                id: poolMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.NoButton
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                anchors.rightMargin: 8
                                spacing: 6

                                SideButton {
                                    label: "L"
                                    active: poolRow.side === "left"
                                    onClicked: window.diff.setSide(poolRow.entryId, "left")
                                }
                                SideButton {
                                    label: "R"
                                    active: poolRow.side === "right"
                                    onClicked: window.diff.setSide(poolRow.entryId, "right")
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 1

                                    Text {
                                        text: "#" + poolRow.number
                                        font.family: Theme.monoFont
                                        font.pixelSize: Theme.uiSmall
                                        color: Theme.label
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: poolRow.summary
                                        textFormat: Text.PlainText
                                        elide: Text.ElideRight
                                        font.family: Theme.uiFont
                                        font.pixelSize: Theme.uiSmall
                                        color: Theme.secondaryLabel
                                    }
                                }

                                FlatButton {
                                    text: "×"
                                    onClicked: window.diff.removeEntry(poolRow.entryId)
                                }
                            }
                        }
                    }
                }
            }

            Rectangle {
                Layout.preferredWidth: 1
                Layout.fillHeight: true
                color: Theme.separator
            }

            // Comparison content
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                Text {
                    anchors.centerIn: parent
                    width: parent.width - 80
                    visible: !window.diff.ready
                    text: window.diff.error !== ""
                        ? window.diff.error
                        : window.diff.loading
                            ? "Loading packets…"
                            : window.diff.pool.count === 0
                                ? "No packet selected for comparison."
                                : window.diff.pool.count === 1
                                    ? "Add a second packet (Ctrl+Y) to compare."
                                    : "Assign one packet to Left and another to Right."
                    textFormat: Text.PlainText
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSize
                    color: window.diff.error !== "" ? Theme.systemRed : Theme.secondaryLabel
                }

                ListView {
                    id: sideView
                    anchors.fill: parent
                    visible: window.diff.ready && window.diff.contentKind === "details"
                        && window.diff.displayMode === "sideBySide"
                    model: window.diff.sideBySideRows
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { }

                    delegate: Rectangle {
                        required property var modelData
                        required property int index

                        width: ListView.view.width
                        height: 20
                        color: modelData.changed
                            ? (modelData.leftEmpty
                                ? window.addTint
                                : modelData.rightEmpty ? window.removeTint : window.changeTint)
                            : (index % 2 ? Theme.rowAlternate : "transparent")

                        RowLayout {
                            anchors.fill: parent
                            spacing: 0

                            Text {
                                Layout.preferredWidth: Math.max(1, sideView.width / 2 - 1)
                                Layout.fillHeight: true
                                leftPadding: 8
                                text: modelData.left
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                verticalAlignment: Text.AlignVCenter
                                font.family: Theme.monoFont
                                font.pixelSize: Theme.packetFontSize
                                color: Theme.label
                            }

                            Rectangle {
                                width: 1
                                Layout.fillHeight: true
                                color: Theme.separator
                            }

                            Text {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                leftPadding: 8
                                text: modelData.right
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                verticalAlignment: Text.AlignVCenter
                                font.family: Theme.monoFont
                                font.pixelSize: Theme.packetFontSize
                                color: Theme.label
                            }
                        }
                    }
                }

                ListView {
                    id: unifiedView
                    anchors.fill: parent
                    visible: window.diff.ready && window.diff.contentKind === "details"
                        && window.diff.displayMode === "unified"
                    model: window.diff.unifiedRows
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { }

                    delegate: Rectangle {
                        required property var modelData
                        required property int index

                        width: ListView.view.width
                        height: 20
                        color: modelData.changed
                            ? (modelData.marker === "+" ? window.addTint : window.removeTint)
                            : (index % 2 ? Theme.rowAlternate : "transparent")

                        RowLayout {
                            anchors.fill: parent
                            spacing: 4

                            Text {
                                Layout.preferredWidth: 18
                                Layout.fillHeight: true
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                text: modelData.marker
                                font.family: Theme.monoFont
                                font.pixelSize: Theme.packetFontSize
                                color: modelData.marker === "+"
                                    ? Theme.systemGreen
                                    : modelData.marker === "-" ? Theme.systemRed : Theme.secondaryLabel
                            }

                            Text {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                verticalAlignment: Text.AlignVCenter
                                text: modelData.text
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                font.family: Theme.monoFont
                                font.pixelSize: Theme.packetFontSize
                                color: Theme.label
                            }
                        }
                    }
                }

                // Byte comparison (upstream DiffBinaryViewController)
                ColumnLayout {
                    anchors.fill: parent
                    visible: window.diff.ready && window.diff.contentKind === "bytes"
                    spacing: 0

                    // Hex search bar (upstream: hidden until ⌘F, side follows
                    // the focused pane; the port toggles the side explicitly).
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 34
                        visible: window.searchActive
                        color: Theme.headerBackground

                        Rectangle { width: parent.width; height: 1; color: Theme.separator }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            spacing: 8

                            SideButton {
                                label: "L"
                                active: window.searchSide === "left"
                                onClicked: window.searchSide = "left"
                            }
                            SideButton {
                                label: "R"
                                active: window.searchSide === "right"
                                onClicked: window.searchSide = "right"
                            }

                            TextField {
                                id: searchField
                                Layout.preferredWidth: 300
                                placeholderText: "Find hex bytes, e.g. 48 65 6C 6C 6F"
                                font.family: Theme.monoFont
                                font.pixelSize: Theme.uiSmall
                                color: Theme.label
                                background: Rectangle {
                                    radius: 6
                                    color: Theme.contentBackground
                                    border.width: searchField.activeFocus ? 1 : 0
                                    border.color: Theme.accent
                                }
                                Keys.onReturnPressed: window.findNext()
                                Keys.onEscapePressed: window.closeSearch()
                            }

                            FlatButton {
                                text: "Find Next"
                                onClicked: window.findNext()
                            }
                            FlatButton {
                                text: "Done"
                                onClicked: window.closeSearch()
                            }

                            Text {
                                Layout.fillWidth: true
                                text: window.searchStatus
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                font.family: Theme.uiFont
                                font.pixelSize: Theme.uiSmall
                                color: window.searchStatus === "No matches"
                                       || window.searchStatus === "Enter pairs of hex digits"
                                    ? Theme.systemRed : Theme.secondaryLabel
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: 0

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: 0

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 26
                            color: Theme.headerBackground

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 16
                                text: window.diff.leftTitle
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                font.family: Theme.uiSmall
                                font.pixelSize: Theme.uiSmall
                                color: Theme.label
                            }
                        }

                        HexView {
                            id: leftHexView
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            bytes: window.diff.leftBytes
                            highlights: window.byteHighlights("left")
                            highlightColor: Qt.rgba(Theme.systemOrange.r, Theme.systemOrange.g,
                                                    Theme.systemOrange.b, 0.30)
                            selectionColor: Theme.selection
                            textColor: Theme.label
                            secondaryTextColor: Theme.secondaryLabel
                            backgroundColor: Theme.contentBackground
                            fontFamily: Theme.monoFont
                            pixelSize: Theme.packetFontSize
                        }
                    }

                    Rectangle {
                        Layout.preferredWidth: 1
                        Layout.fillHeight: true
                        color: Theme.separator
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: 0

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 26
                            color: Theme.headerBackground

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 16
                                text: window.diff.rightTitle
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                font.family: Theme.uiSmall
                                font.pixelSize: Theme.uiSmall
                                color: Theme.label
                            }
                        }

                        HexView {
                            id: rightHexView
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            bytes: window.diff.rightBytes
                            highlights: window.byteHighlights("right")
                            highlightColor: Qt.rgba(Theme.systemOrange.r, Theme.systemOrange.g,
                                                    Theme.systemOrange.b, 0.30)
                            selectionColor: Theme.selection
                            textColor: Theme.label
                            secondaryTextColor: Theme.secondaryLabel
                            backgroundColor: Theme.contentBackground
                            fontFamily: Theme.monoFont
                            pixelSize: Theme.packetFontSize
                        }
                    }
                    }
                }
            }
        }

        // Footer ----------------------------------------------------------------
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 26
            color: Theme.headerBackground

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: window.diff.error !== ""
                    ? window.diff.error
                    : !window.diff.ready
                        ? ""
                        : window.diff.contentKind === "bytes"
                            ? (window.diff.byteChanges.length === 0
                                ? "No byte differences"
                                : window.byteCursor >= 0
                                    ? "Difference " + (window.byteCursor + 1) + " of "
                                      + window.diff.byteChanges.length + " · "
                                      + window.diff.byteChanges[window.byteCursor].description
                                    : window.diff.byteChanges.length + " changed range(s) · "
                                      + "F7 / Shift+F7 to navigate · Ctrl+F to find hex bytes")
                            : window.diff.differenceCount === 0
                                ? "No differences"
                                : window.diff.differenceCount + " changed line(s) · F7 / Shift+F7 to navigate"
                textFormat: Text.PlainText
                elide: Text.ElideRight
                font.family: Theme.uiFont
                font.pixelSize: Theme.uiSmall
                color: window.diff.error !== "" ? Theme.systemRed : Theme.secondaryLabel
            }
        }
    }

    // New Left/Right frames reset the byte-change cursor and selection.
    Connections {
        target: window.diff
        function onBytesChanged() {
            window.byteCursor = -1
            leftHexView.select(-1, 0)
            rightHexView.select(-1, 0)
        }
    }

    // Segmented control copied from FollowStreamWindow (same design tokens).
    component SegmentPill: Rectangle {
        id: pillRoot
        property var labels: []
        property int value: 0
        signal picked(int index)

        height: 24
        radius: 6
        color: Theme.contentBackground
        border.width: 1
        border.color: Theme.separator
        implicitWidth: pillRow.implicitWidth + 4
        opacity: enabled ? 1 : 0.4

        Row {
            id: pillRow
            anchors.fill: parent
            anchors.margins: 2

            Repeater {
                model: pillRoot.labels

                delegate: Rectangle {
                    required property string modelData
                    required property int index
                    property bool pickedSegment: pillRoot.value === index

                    height: parent ? parent.height : 20
                    radius: 4
                    color: pickedSegment ? Theme.selection : "transparent"
                    width: Math.max(48, textMetrics.advanceWidth + 20)

                    TextMetrics {
                        id: textMetrics
                        text: modelData
                        font.pixelSize: Theme.uiSmall
                        font.family: Theme.uiFont
                    }

                    Text {
                        anchors.centerIn: parent
                        text: modelData
                        font.family: Theme.uiFont
                        font.pixelSize: Theme.uiSmall
                        color: pickedSegment ? "white" : Theme.label
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: pillRoot.enabled
                        onClicked: pillRoot.picked(index)
                    }
                }
            }
        }
    }

    component FlatButton: Rectangle {
        id: button
        property string text
        signal clicked

        implicitWidth: Math.max(26, buttonLabel.implicitWidth + 16)
        implicitHeight: 24
        radius: 5
        color: buttonMouse.containsMouse && button.enabled
            ? Qt.rgba(Theme.label.r, Theme.label.g, Theme.label.b, 0.08)
            : "transparent"
        border.width: 1
        border.color: Theme.separator
        opacity: button.enabled ? 1 : 0.4

        Text {
            id: buttonLabel
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

    component SideButton: Rectangle {
        id: sideButton
        property string label
        property bool active
        signal clicked

        width: 24
        height: 22
        radius: 4
        color: active
            ? Theme.selection
            : (sideMouse.containsMouse
                ? Qt.rgba(Theme.label.r, Theme.label.g, Theme.label.b, 0.08)
                : "transparent")
        border.width: 1
        border.color: active ? Theme.selection : Theme.separator

        Text {
            anchors.centerIn: parent
            text: sideButton.label
            font.family: Theme.uiFont
            font.pixelSize: Theme.uiSmall
            font.weight: Font.DemiBold
            color: sideButton.active ? "white" : Theme.label
        }

        MouseArea {
            id: sideMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: sideButton.clicked()
        }
    }
}
