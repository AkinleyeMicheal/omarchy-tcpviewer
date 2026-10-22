import QtQuick
import QtQuick.Controls
import Omarchy.TCPViewer

// Packet inspector (PacketInspectorViewController): detail-tree filter bar,
// Wireshark outline, and the hex/ASCII pane in a vertical split (70/30).
Rectangle {
    id: root

    required property SessionController session

    color: Theme.contentBackground

    function detailColor(kind, severity, byteOffset) {
        if (severity === "error")
            return Theme.systemRed
        if (severity === "warning" || kind === "warning")
            return Theme.systemOrange
        if (kind === "message")
            return Theme.secondaryLabel
        return byteOffset >= 0 ? Theme.label : Theme.secondaryLabel
    }

    Rectangle {
        id: filterBar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 34
        color: Theme.contentBackground

        Rectangle {
            anchors.fill: parent
            anchors.margins: 6
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            radius: 6
            color: Theme.windowBackground
            border.width: 1
            border.color: inspectorFilter.activeFocus ? Theme.accent : Theme.separator

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 7
                anchors.verticalCenter: parent.verticalCenter
                text: "⌕"
                font.pixelSize: 11
                color: Theme.secondaryLabel
            }

            TextField {
                id: inspectorFilter
                anchors.fill: parent
                anchors.leftMargin: 22
                anchors.rightMargin: 6
                background: null
                padding: 0
                verticalAlignment: TextInput.AlignVCenter
                placeholderText: "Filter Key and Value"
                placeholderTextColor: Theme.secondaryLabel
                color: Theme.label
                selectionColor: Theme.accent
                selectedTextColor: "white"
                font.family: Theme.monoFont
                font.pixelSize: Theme.uiSmall
                selectByMouse: true
                text: root.session.autoDetailFilter
                onTextChanged: root.session.detailModel.setFilterText(text)

                Connections {
                    target: root.session
                    function onSelectedPacketIDChanged() {
                        // Filter text persists across packets, matching upstream.
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

    SplitView {
        id: detailSplit
        anchors.top: filterBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        orientation: Qt.Vertical

        handle: Rectangle {
            implicitHeight: 1
            color: Theme.separator
        }

        Item {
            id: detailPane
            SplitView.fillHeight: true
            SplitView.minimumHeight: 160

            ListView {
                id: tree
                anchors.fill: parent
                clip: true
                model: root.session.detailModel
                currentIndex: -1
                visible: root.session.selectedPacketID !== "" && root.session.detailError === ""

                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: Item {
                    id: row

                    required property int index
                    required property string name
                    required property string value
                    required property string kind
                    required property string severity
                    required property int depth
                    required property bool hasChildren
                    required property bool expanded
                    required property int byteOffset
                    required property int byteLength

                    readonly property bool selected: ListView.isCurrentItem
                    readonly property bool hovered: rowMouse.containsMouse
                    readonly property real indent: 6 + depth * 14

                    width: ListView.view.width
                    height: 20

                    Rectangle {
                        anchors.fill: parent
                        color: row.selected
                            ? Qt.rgba(Theme.selection.r, Theme.selection.g, Theme.selection.b, 0.20)
                            : (row.hovered
                                ? Qt.rgba(Theme.label.r, Theme.label.g, Theme.label.b, 0.05)
                                : "transparent")
                    }

                    Text {
                        id: disclosure
                        x: row.indent
                        anchors.verticalCenter: parent.verticalCenter
                        width: 10
                        text: row.hasChildren ? (row.expanded ? "▾" : "▸") : ""
                        font.pixelSize: 9
                        color: Theme.secondaryLabel

                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.session.detailModel.toggleExpanded(row.index)
                        }
                    }

                    Text {
                        anchors.left: disclosure.right
                        anchors.leftMargin: 4
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: row.value !== "" ? row.name + ": " + row.value : row.name
                        elide: Text.ElideRight
                        font.family: Theme.monoFont
                        font.pixelSize: Theme.packetFontSize
                        font.weight: row.kind === "layer"
                            ? (row.depth === 0 ? Font.Bold : Font.DemiBold)
                            : Font.Normal
                        color: root.detailColor(row.kind, row.severity, row.byteOffset)
                    }

                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        anchors.leftMargin: row.indent + 14
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton
                        onClicked: tree.currentIndex = row.index
                        onDoubleClicked: {
                            if (row.hasChildren)
                                root.session.detailModel.toggleExpanded(row.index)
                        }
                    }
                }

                Connections {
                    target: root.session.detailModel
                    function onModelReset() {
                        // ListView assigns currentIndex 0 after a reset; wait one frame.
                        var target = root.session.autoSelectDetailRow >= 0
                            ? Math.min(root.session.autoSelectDetailRow, root.session.detailModel.rowCount() - 1)
                            : -1
                        Qt.callLater(function() { tree.currentIndex = target })
                    }
                }

                Connections {
                    target: root.session
                    function onSelectedPacketIDChanged() {
                        tree.currentIndex = -1
                        tree.contentY = 0
                    }
                }
            }

            Column {
                anchors.centerIn: parent
                spacing: 6
                visible: root.session.detailLoading && root.session.detailModel.rowCount === 0

                BusyIndicator {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 22
                    height: 22
                    running: visible
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Decoding packet…"
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSmall
                    color: Theme.secondaryLabel
                }
            }

            Text {
                anchors.centerIn: parent
                width: Math.min(parent.width - 40, 320)
                visible: root.session.detailError !== ""
                text: root.session.detailError
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                font.family: Theme.uiFont
                font.pixelSize: Theme.uiSmall
                color: Theme.systemRed
            }

            EmptyState {
                anchors.fill: parent
                visible: root.session.selectedPacketID === "" && !root.session.detailLoading
                glyph: "▤"
                title: "No Packet Selected"
                message: "Select a packet to inspect its protocol tree and bytes."
                showStartAction: false
                showOpenAction: false
            }
        }

        HexView {
            id: hex
            SplitView.preferredHeight: Math.max(120, detailSplit.height * 0.30)
            SplitView.minimumHeight: 120

            bytes: root.session.packetBytes
            highlightOffset: tree.currentIndex >= 0
                ? root.session.detailModel.byteOffsetAt(tree.currentIndex) : -1
            highlightLength: tree.currentIndex >= 0
                ? root.session.detailModel.byteLengthAt(tree.currentIndex) : 0
            fontFamily: Theme.monoFont
            pixelSize: Math.max(9, Theme.packetFontSize - 1)
            textColor: Theme.label
            secondaryTextColor: Theme.secondaryLabel
            highlightColor: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.30)
            backgroundColor: Theme.contentBackground
        }
    }
}
