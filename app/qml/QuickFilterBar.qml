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

    function focusDisplayFilter() {
        filterField.forceActiveFocus()
        filterField.selectAll()
    }

    // Save-as dialog state: the expression captured when the dialog opens, so
    // editing the field afterwards cannot save a mismatched query.
    property string pendingSaveQuery: ""

    function commitSaveFilter() {
        const error = session.saveFilter(nameField.text, pendingSaveQuery)
        if (error.length > 0) {
            errorLabel.text = error
            return
        }
        saveFilterPopup.close()
    }

    property var selectedIDs: []
    // Quick filters can be set before this bar appears (CI startup hook) or
    // by an outside actor (saved-filter restore). Chips must show the
    // session's truth, so mirror it whenever the two sets disagree.
    // toggleChip writes local state before calling session, so the mirror
    // never loops back into an edit.
    function syncSelectedIDs() {
        const sessionIds = session.quickFilters
        const local = selectedIDs
        if (sessionIds.length !== local.length) {
            selectedIDs = sessionIds.slice()
            return
        }
        for (var i = 0; i < sessionIds.length; ++i) {
            if (sessionIds[i] !== local[i]) {
                selectedIDs = sessionIds.slice()
                return
            }
        }
    }
    Component.onCompleted: syncSelectedIDs()
    Connections {
        target: root.session
        function onQuickFiltersChanged() {
            root.syncSelectedIDs()
        }
    }
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

        Flickable {
            Layout.fillWidth: true
            Layout.preferredHeight: parent.height
            contentWidth: chipRow.width
            clip: true
            flickableDirection: Flickable.HorizontalFlick
            boundsBehavior: Flickable.StopAtBounds

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

            TextField {
                id: filterField
                anchors.fill: parent
                anchors.leftMargin: 8
                // Leave room for the save, pin and clear affordances.
                anchors.rightMargin: filterField.text.length > 0 ? 54 : 8
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

            // Pin the current expression into the sidebar Favorites group
            // (upstream PacketCustomFilter group handling).
            Text {
                id: pinGlyph
                anchors.right: parent.right
                anchors.rightMargin: 22
                anchors.verticalCenter: parent.verticalCenter
                visible: filterField.text.trim().length > 0
                readonly property bool pinned:
                    root.session.pinnedFilters.indexOf(filterField.text.trim()) >= 0
                text: pinned ? "★" : "☆"
                font.pixelSize: 12
                color: pinned ? Theme.systemOrange : Theme.secondaryLabel

                ToolTip.visible: pinMouse.containsMouse
                ToolTip.text: pinned ? "Unpin filter" : "Pin filter"
                ToolTip.delay: 500

                MouseArea {
                    id: pinMouse
                    anchors.fill: parent
                    anchors.margins: -4
                    hoverEnabled: true
                    onClicked: {
                        const expression = filterField.text.trim()
                        if (expression.length === 0)
                            return
                        if (root.session.pinnedFilters.indexOf(expression) >= 0)
                            root.session.unpinFilter(expression)
                        else
                            root.session.pinFilter(expression)
                    }
                }
            }

            // Save the current expression under a name in the sidebar Favorites.
            Text {
                id: saveGlyph
                anchors.right: parent.right
                anchors.rightMargin: 38
                anchors.verticalCenter: parent.verticalCenter
                visible: filterField.text.trim().length > 0
                text: "⊕"
                font.pixelSize: 12
                color: saveMouse.containsMouse ? Theme.accent : Theme.secondaryLabel

                ToolTip.visible: saveMouse.containsMouse
                ToolTip.text: "Save filter…"
                ToolTip.delay: 500

                MouseArea {
                    id: saveMouse
                    anchors.fill: parent
                    anchors.margins: -4
                    hoverEnabled: true
                    onClicked: {
                        const expression = filterField.text.trim()
                        if (expression.length === 0)
                            return
                        root.pendingSaveQuery = expression
                        saveFilterPopup.open()
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

    // Named-filter dialog (upstream saveCustomFilter): Enter saves, Escape
    // cancels, and validation errors surface inline.
    Popup {
        id: saveFilterPopup
        parent: root
        x: root.width - width - 16
        y: root.height + 6
        width: 280
        padding: 12
        modal: true
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            color: Theme.contentBackground
            border.width: 1
            border.color: Theme.separator
            radius: 8
        }

        onOpened: {
            nameField.text = ""
            errorLabel.text = ""
            nameField.forceActiveFocus()
        }

        contentItem: ColumnLayout {
            spacing: 8

            Text {
                text: "Save display filter"
                font.family: Theme.uiFont
                font.pixelSize: Theme.uiSmall
                font.weight: Font.DemiBold
                color: Theme.secondaryLabel
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 26
                radius: 6
                color: Theme.windowBackground
                border.width: 1
                border.color: nameField.activeFocus ? Theme.accent : Theme.separator

                TextField {
                    id: nameField
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    background: null
                    padding: 0
                    verticalAlignment: TextInput.AlignVCenter
                    placeholderText: "Filter name"
                    placeholderTextColor: Theme.secondaryLabel
                    color: Theme.label
                    selectionColor: Theme.accent
                    selectedTextColor: "white"
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSmall
                    selectByMouse: true
                    onAccepted: root.commitSaveFilter()
                }
            }

            Text {
                id: errorLabel
                visible: text.length > 0
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                font.family: Theme.uiFont
                font.pixelSize: Theme.uiSmall
                color: Theme.systemRed
            }

            RowLayout {
                Layout.alignment: Qt.AlignRight
                spacing: 8

                DialogButton {
                    text: "Cancel"
                    onClicked: saveFilterPopup.close()
                }
                DialogButton {
                    text: "Save"
                    primary: true
                    onClicked: root.commitSaveFilter()
                }
            }
        }
    }

    component DialogButton: Rectangle {
        id: button

        property string text
        property bool primary: false
        signal clicked

        implicitWidth: label.implicitWidth + 24
        implicitHeight: 24
        radius: 6
        color: button.primary
            ? (buttonMouse.containsMouse
                ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.85)
                : Theme.accent)
            : (buttonMouse.containsMouse
                ? Qt.rgba(Theme.label.r, Theme.label.g, Theme.label.b, 0.08)
                : "transparent")
        border.width: button.primary ? 0 : 1
        border.color: Theme.separator

        Text {
            id: label
            anchors.centerIn: parent
            text: button.text
            font.family: Theme.uiFont
            font.pixelSize: Theme.uiSmall
            color: button.primary ? "white" : Theme.label
        }

        MouseArea {
            id: buttonMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: button.clicked()
        }
    }

    // CI hook: capture the save-filter dialog without a mouse click. The timer
    // waits for the startup display filter (TCPVIEWER_FILTER) to arrive. Each
    // tab/layout pane owns a bar, including the hidden split pane, so only the
    // visible bar may open the dialog.
    Timer {
        interval: 1500
        repeat: false
        running: root.visible && root.width > 0
            && session.envValue("TCPVIEWER_SHOW_SAVE_DIALOG") === "1"
            && !saveFilterPopup.visible
            && filterField.text.trim().length > 0
        onTriggered: {
            root.pendingSaveQuery = filterField.text.trim()
            saveFilterPopup.open()
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
