import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import Omarchy.TCPViewer

// Follow Stream window (upstream FollowStreamWindowController.swift /
// FollowStreamViewController.swift): settings segmented controls, endpoint
// summary, bounded transcript, dedicated search row, and export menu.
Window {
    id: window

    required property FollowSessionController follow
    required property SessionController session

    width: 1200
    height: 760
    minimumWidth: 1100
    minimumHeight: 560
    color: Theme.windowBackground
    title: follow.model.hasStream ? follow.model.streamTitle : "Follow Stream"

    // 0 text, 1 hex (upstream FollowStreamRepresentation).
    property int representation: follow.startupRepresentation >= 0
        ? follow.startupRepresentation : 0

    function openAndRaise() {
        show()
        requestActivate()
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Settings row ---------------------------------------------------------
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 40
            color: Theme.headerBackground

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 10

                Text {
                    text: "Settings:"
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSize
                    font.weight: Font.DemiBold
                    color: Theme.label
                }

                SegmentPill {
                    labels: ["Both", "Client → Server", "Server → Client"]
                    value: window.follow.model.directionFilter
                    onPicked: (index) => { window.follow.model.directionFilter = index }
                }

                SegmentPill {
                    labels: ["Text", "Hex"]
                    value: window.representation
                    onPicked: (index) => { window.representation = index }
                }

                Item { Layout.fillWidth: true }

                Text {
                    text: "Stream:"
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSize
                    color: Theme.label
                }

                Text {
                    text: window.follow.model.hasStream
                        ? window.follow.model.streamTitle.replace("· Stream ", "")
                        : "—"
                    font.family: Theme.monoFont
                    font.pixelSize: Theme.uiSize
                    color: Theme.label
                }
            }
        }

        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.separator }

        // Summary + status ------------------------------------------------------
        ColumnLayout {
            Layout.fillWidth: true
            Layout.margins: 12
            spacing: 2

            Text {
                Layout.fillWidth: true
                visible: window.follow.model.hasStream
                text: window.follow.model.summaryLabel
                elide: Text.ElideMiddle
                font.family: Theme.uiFont
                font.pixelSize: Theme.uiSize
                font.weight: Font.DemiBold
                color: Theme.label
            }

            Text {
                Layout.fillWidth: true
                visible: window.follow.model.hasStream
                text: window.follow.model.statusText
                elide: Text.ElideMiddle
                font.family: Theme.uiFont
                font.pixelSize: Theme.uiSmall
                color: Theme.secondaryLabel
            }
        }

        // Transcript --------------------------------------------------------------
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ListView {
                id: transcript
                property var matchRows: []
                property int matchIndex: -1

                anchors.fill: parent
                model: window.follow.model
                clip: true
                spacing: 24
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { }

                // Upstream search cycles the transcript matches; jumping centers
                // the record that contains the next hit.
                function showNextMatch(step) {
                    if (matchRows.length === 0)
                        return
                    var index = (matchIndex + step) % matchRows.length
                    if (index < 0)
                        index += matchRows.length
                    matchIndex = index
                    positionViewAtIndex(matchRows[index], ListView.Center)
                }

                delegate: Column {
                    id: record
                    width: transcript.width - 28
                    x: 14
                    spacing: 4

                    readonly property bool isClient: model.direction === 0
                    readonly property color directionColor: isClient ? Theme.systemBlue : Theme.systemOrange

                    Item {
                        width: parent.width
                        height: headerText.height

                        Text {
                            id: headerText
                            text: (record.isClient ? "→ Client to Server" : "← Server to Client")
                                + " · Packet " + model.packetID + " · " + model.byteCount + " B"
                            font.family: Theme.uiFont
                            font.pixelSize: Theme.uiSmall
                            font.weight: Font.DemiBold
                            color: record.directionColor
                        }

                        // Hover reveals the record's packet in the main window
                        // (upstream FollowStreamTextView reveal button).
                        Rectangle {
                            id: revealButton
                            anchors.right: parent.right
                            visible: headerArea.containsMouse
                            width: revealLabel.width + 14
                            height: 20
                            radius: 4
                            color: headerArea.containsMouse ? Theme.selection : "transparent"
                            border.width: 1
                            border.color: Theme.selection

                            Text {
                                id: revealLabel
                                anchors.centerIn: parent
                                text: "Reveal ↗"
                                font.family: Theme.uiFont
                                font.pixelSize: Theme.uiSmall
                                color: Theme.contentBackground
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    window.session.selectPacket(String(model.packetID))
                                    revealButton.forceActiveFocus()
                                }
                            }
                        }

                        MouseArea {
                            id: headerArea
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: window.session.selectPacket(String(model.packetID))
                        }
                    }

                    Text {
                        width: parent.width
                        visible: window.representation === 0
                        text: model.textPayload
                        color: Theme.label
                        font.family: Theme.monoFont
                        font.pixelSize: Theme.packetFontSize
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        textFormat: Text.PlainText
                    }

                    Text {
                        width: parent.width
                        visible: window.representation === 1
                        text: model.hexPayload
                        color: Theme.label
                        font.family: Theme.monoFont
                        font.pixelSize: Theme.packetFontSize
                        textFormat: Text.PlainText
                    }
                }

                // Empty / initial state.
                Text {
                    anchors.centerIn: parent
                    visible: !window.follow.loading && !window.follow.model.hasStream
                             && window.follow.model.followError === ""
                    text: "No stream followed yet.\nUse the packet table's context menu, then this window shows it."
                    horizontalAlignment: Text.AlignHCenter
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSize
                    color: Theme.secondaryLabel
                }
            }

            // Loading overlay (upstream showLoading()).
            Column {
                anchors.centerIn: parent
                spacing: 10
                visible: window.follow.loading

                BusyIndicator {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 26
                    height: 26
                    running: window.follow.loading
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: window.follow.model.hasStream ? "Following stream…" : "Loading stream…"
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSize
                    color: Theme.secondaryLabel
                }
            }

            // Error state (upstream show(error): non-destructive, same window).
            Text {
                anchors.centerIn: parent
                visible: !window.follow.loading && window.follow.model.followError !== ""
                width: Math.min(parent.width - 80, 520)
                text: window.follow.model.followError
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                font.family: Theme.uiFont
                font.pixelSize: Theme.uiSize
                color: Theme.label
            }
        }

        // Search + export row -------------------------------------------------------
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 40
            color: Theme.headerBackground

            Rectangle { width: parent.width; height: 1; color: Theme.separator }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 8

                TextField {
                    id: searchField
                    Layout.preferredWidth: 260
                    placeholderText: "Search transcript ⌘F"
                    enabled: window.follow.model.hasStream
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSmall
                    color: Theme.label
                    background: Rectangle {
                        radius: 6
                        color: Theme.contentBackground
                        border.width: searchField.activeFocus ? 1 : 0
                        border.color: Theme.accent
                    }

                    onTextChanged: {
                        transcript.matchRows = text.length > 0
                            ? window.follow.model.searchRows(text) : []
                        transcript.matchIndex = -1
                        transcript.showNextMatch(1)
                    }

                    Keys.onReturnPressed: transcript.showNextMatch(1)
                    Keys.onEscapePressed: text = ""
                }

                Text {
                    text: {
                        var count = transcript.matchRows.length
                        var number = transcript.matchIndex < 0 ? 0 : transcript.matchIndex + 1
                        return number + " of " + count
                    }
                    font.family: Theme.monoFont
                    font.pixelSize: Theme.uiSmall
                    color: Theme.secondaryLabel
                }

                ToolButton {
                    enabled: transcript.matchRows.length > 0
                    text: "↑"
                    onClicked: transcript.showNextMatch(-1)
                    ToolTip.visible: hovered
                    ToolTip.text: "Previous match"
                }

                ToolButton {
                    enabled: transcript.matchRows.length > 0
                    text: "↓"
                    onClicked: transcript.showNextMatch(1)
                    ToolTip.visible: hovered
                    ToolTip.text: "Next match"
                }

                Item { Layout.fillWidth: true }

                ToolButton {
                    text: "Save Transcript…"
                    enabled: window.follow.model.hasStream && !window.follow.loading
                    onClicked: {
                        saveDialog.mode = "transcript"
                        saveDialog.open()
                    }
                    ToolTip.visible: hovered
                    ToolTip.text: "Save the transcript as text"
                }

                ToolButton {
                    text: "Export Client Bytes…"
                    enabled: window.follow.model.hasStream && !window.follow.loading
                    onClicked: {
                        saveDialog.mode = "client"
                        saveDialog.open()
                    }
                    ToolTip.visible: hovered
                    ToolTip.text: "Export the client-side payload bytes"
                }

                ToolButton {
                    text: "Export Server Bytes…"
                    enabled: window.follow.model.hasStream && !window.follow.loading
                    onClicked: {
                        saveDialog.mode = "server"
                        saveDialog.open()
                    }
                    ToolTip.visible: hovered
                    ToolTip.text: "Export the server-side payload bytes"
                }
            }
        }
    }

    // Upstream NSSegmentedControl: a light chip row with the active segment tinted.
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

        Row {
            id: pillRow
            anchors.fill: parent
            anchors.margins: 2

            Repeater {
                model: pillRoot.labels

                delegate: Rectangle {
                    required property string modelData
                    required property int index
                    property bool picked_segment: pillRoot.value === index

                    height: parent ? parent.height : 20
                    radius: 4
                    color: picked_segment ? Theme.selection : "transparent"
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
                        color: parent.picked_segment ? Theme.contentBackground : Theme.secondaryLabel
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: pillRoot.picked(index)
                    }
                }
            }
        }
    }

    FileDialog {
        id: saveDialog
        property string mode: "transcript"
        fileMode: FileDialog.SaveFile
        nameFilters: mode === "transcript" ? ["Text files (*.txt)"] : ["Binary files (*.bin)"]
        onAccepted: {
            const asText = mode === "transcript"
            const payload = asText
                ? window.follow.model.transcriptText(window.follow.model.directionFilter)
                : window.follow.model.transcriptRaw(mode === "client" ? 1 : 2)
            const wrote = asText
                ? window.follow.saveFile(selectedFile, payload)
                : window.follow.saveFile(selectedFile, payload)
            if (!wrote)
                window.session.setError("Could not write to the selected file")
        }
    }
}
