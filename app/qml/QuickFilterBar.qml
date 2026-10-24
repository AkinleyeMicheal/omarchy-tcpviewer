import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Omarchy.TCPViewer

// Quick filter chips and the display-filter field (PacketQuickFilterViewController
// and the upstream display filter). Chips are local predicates in the daemon;
// the text field is a sticky source-level Wireshark display filter.
Rectangle {
    id: root

    required property SessionController session

    implicitHeight: Theme.quickFilterHeight
    color: Theme.contentBackground

    // Workspace mode (upstream NetworkInspectorWorkspaceMode): the segmented
    // control toggles the Overview dashboard and the packet table.
    property string workspaceMode: "packets"

    function focusDisplayFilter() {
        filterField.forceActiveFocus()
        filterField.selectAll()
    }

    property var selectedIDs: []
    readonly property var chips: [
        { id: "all", label: "All" },
        { id: "tcp", label: "TCP" },
        { id: "udp", label: "UDP" },
        { id: "dns", label: "DNS" },
        { id: "http", label: "HTTP" },
        { id: "tls", label: "TLS" },
        { id: "websocket", label: "WebSocket" },
        { id: "clientHello", label: "Client Hello" },
        { id: "serverHello", label: "Server Hello" },
        { id: "errors", label: "Errors" }
    ]

    function toggleChip(id) {
        if (id === "all") {
            selectedIDs = []
        } else {
            var next = selectedIDs.slice()
            var index = next.indexOf(id)
            if (index >= 0)
                next.splice(index, 1)
            else
                next.push(id)
            selectedIDs = next
        }
        session.setQuickFilters(selectedIDs)
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        spacing: 8

        // Segmented mode toggle (upstream workspace mode picker).
        Row {
            id: modeToggle
            Layout.preferredHeight: 24
            spacing: 0

            Repeater {
                model: [
                    { id: "overview", label: "Overview" },
                    { id: "packets", label: "Packets" },
                ]

                delegate: Rectangle {
                    id: modeSegment

                    required property var modelData
                    property int segmentIndex: index

                    width: segmentLabel.implicitWidth + 24
                    height: 24
                    radius: modeSegment.segmentIndex === 0 ? 6 : 0
                    color: root.workspaceMode === modeSegment.modelData.id
                        ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.16)
                        : (segmentMouse.containsMouse
                            ? Qt.rgba(Theme.label.r, Theme.label.g, Theme.label.b, 0.06)
                            : "transparent")
                    border.width: 1
                    border.color: Theme.separator

                    Text {
                        id: segmentLabel
                        anchors.centerIn: parent
                        text: modeSegment.modelData.label
                        font.family: Theme.uiFont
                        font.pixelSize: Theme.uiSmall
                        font.weight: Font.Medium
                        color: root.workspaceMode === modeSegment.modelData.id
                            ? Theme.accent : Theme.label
                    }

                    MouseArea {
                        id: segmentMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.workspaceMode = modeSegment.modelData.id
                    }
                }
            }
        }

        Flickable {
            Layout.fillWidth: true
            Layout.preferredHeight: parent.height
            contentWidth: chipRow.width
            clip: true
            flickableDirection: Flickable.HorizontalFlick
            boundsBehavior: Flickable.StopAtBounds
            visible: root.workspaceMode === "packets"

            Row {
                id: chipRow
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8

                Repeater {
                    model: root.chips

                    delegate: Rectangle {
                        id: chip

                        required property var modelData

                        readonly property bool active: modelData.id === "all"
                            ? root.selectedIDs.length === 0
                            : root.selectedIDs.indexOf(modelData.id) >= 0

                        width: chipLabel.implicitWidth + 24
                        height: Theme.quickFilterButtonHeight
                        radius: 6
                        color: active
                            ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.16)
                            : (chipMouse.containsMouse
                                ? Qt.rgba(Theme.label.r, Theme.label.g, Theme.label.b, 0.06)
                                : "transparent")

                        Text {
                            id: chipLabel
                            anchors.centerIn: parent
                            text: chip.modelData.label
                            font.family: Theme.uiFont
                            font.pixelSize: Theme.uiSmall
                            font.weight: Font.Medium
                            color: chip.active ? Theme.accent : Theme.label
                        }

                        MouseArea {
                            id: chipMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: root.toggleChip(chip.modelData.id)
                        }
                    }
                }
            }
        }

        Rectangle {
            Layout.preferredWidth: 270
            Layout.preferredHeight: 24
            radius: 6
            color: Theme.windowBackground
            border.width: 1
            border.color: filterField.activeFocus ? Theme.accent : Theme.separator
            visible: root.workspaceMode === "packets"

            TextField {
                id: filterField
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: filterField.text.length > 0 ? 22 : 8
                background: null
                padding: 0
                verticalAlignment: TextInput.AlignVCenter
                placeholderText: "Display filter"
                placeholderTextColor: Theme.secondaryLabel
                color: Theme.label
                selectionColor: Theme.accent
                selectedTextColor: "white"
                font.family: Theme.monoFont
                font.pixelSize: Theme.uiSmall
                selectByMouse: true
                onAccepted: root.session.applyFilter(text)

                Connections {
                    target: root.session
                    function onFilterTextChanged() {
                        if (!filterField.activeFocus)
                            filterField.text = root.session.filterText
                    }
                }
            }

            Text {
                anchors.right: parent.right
                anchors.rightMargin: 7
                anchors.verticalCenter: parent.verticalCenter
                visible: filterField.text.length > 0
                text: "×"
                font.pixelSize: 12
                color: Theme.secondaryLabel

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        filterField.text = ""
                        root.session.applyFilter("")
                    }
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
