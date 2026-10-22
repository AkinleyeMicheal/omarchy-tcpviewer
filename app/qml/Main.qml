import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import Omarchy.TCPViewer

ApplicationWindow {
    id: window

    width: 1440
    height: 900
    minimumWidth: 900
    minimumHeight: 560
    visible: true
    title: qsTr("Omarchy TCPViewer")
    color: Theme.windowBackground

    property bool sidebarVisible: true

    SessionController {
        id: session
        Component.onCompleted: start()
    }

    Benchmark { id: bench }

    readonly property var interfaceItems: {
        var items = []
        for (var i = 0; i < session.interfaces.length; ++i) {
            var iface = session.interfaces[i]
            var label = iface.friendly_name ? iface.friendly_name + " (" + iface.id + ")" : iface.id
            items.push({ id: String(iface.id), label: label })
        }
        return items
    }

    function statusText() {
        if (!session.connected)
            return "Connecting to tcpviewerd…"
        if (session.capturing)
            return "Capturing on " + String(session.status.interface || session.selectedInterface || "interface")
        if (session.currentSourceID !== "")
            return session.loading ? "Loading capture…" : "Capture ready"
        return "Ready"
    }

    // Toolbar -----------------------------------------------------------------
    Rectangle {
        id: toolbar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 48
        color: Theme.contentBackground

        Row {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            ToolbarButton {
                glyph: "☰"
                width: 28
                tooltip: "Toggle Sidebar"
                onClicked: window.sidebarVisible = !window.sidebarVisible
            }

            ComboBox {
                id: interfaceCombo
                width: 230
                height: 28
                model: window.interfaceItems
                textRole: "label"
                enabled: session.interfaces.length > 0 && !session.capturing
                font.family: Theme.uiFont
                font.pixelSize: Theme.uiSize

                function syncSelection() {
                    for (var i = 0; i < model.length; ++i) {
                        if (model[i].id === session.selectedInterface) {
                            currentIndex = i
                            return
                        }
                    }
                    currentIndex = model.length > 0 ? 0 : -1
                }

                Component.onCompleted: syncSelection()
                onActivated: {
                    if (index >= 0 && index < model.length)
                        session.selectedInterface = model[index].id
                }
                onModelChanged: syncSelection()

                Connections {
                    target: session
                    function onSelectedInterfaceChanged() { interfaceCombo.syncSelection() }
                    function onInterfacesChanged() { interfaceCombo.syncSelection() }
                }

                background: Rectangle {
                    radius: 6
                    color: Theme.windowBackground
                    border.width: 1
                    border.color: interfaceCombo.activeFocus ? Theme.accent : Theme.separator
                }

                contentItem: Text {
                    leftPadding: 10
                    rightPadding: 24
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    text: interfaceCombo.displayText
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSize
                    color: Theme.label
                }

                indicator: Text {
                    x: interfaceCombo.width - 18
                    y: (interfaceCombo.height - implicitHeight) / 2
                    text: "⌄"
                    font.pixelSize: 11
                    color: Theme.secondaryLabel
                }

                delegate: Item {
                    required property var modelData
                    required property int index
                    width: interfaceCombo.width
                    height: 26

                    Rectangle {
                        anchors.fill: parent
                        radius: 4
                        color: index === interfaceCombo.highlightedIndex
                            ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.16)
                            : (interfaceMouse.containsMouse
                                ? Qt.rgba(Theme.label.r, Theme.label.g, Theme.label.b, 0.06)
                                : "transparent")
                    }

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 8
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.label
                        elide: Text.ElideRight
                        font.family: Theme.uiFont
                        font.pixelSize: Theme.uiSize
                        color: Theme.label
                    }

                    MouseArea {
                        id: interfaceMouse
                        anchors.fill: parent
                        hoverEnabled: true
                    }
                }

                popup: Popup {
                    y: interfaceCombo.height + 4
                    width: interfaceCombo.width
                    padding: 4

                    background: Rectangle {
                        radius: 8
                        color: Theme.contentBackground
                        border.width: 1
                        border.color: Theme.separator
                    }

                    contentItem: ListView {
                        implicitHeight: contentHeight
                        model: interfaceCombo.popup.visible ? interfaceCombo.delegateModel : null
                        currentIndex: interfaceCombo.highlightedIndex
                        clip: true
                    }
                }
            }

            Rectangle {
                id: captureButton
                width: 76
                height: 28
                radius: 6
                color: !session.connected
                    ? Theme.separator
                    : (session.capturing ? Theme.systemRed : Theme.accent)

                Text {
                    anchors.centerIn: parent
                    text: session.capturing ? "Stop" : "Start"
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSize
                    font.weight: Font.DemiBold
                    color: "white"
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: session.connected
                    onClicked: {
                        if (session.capturing)
                            session.stopCapture()
                        else
                            session.startCapture(session.selectedInterface)
                    }
                }
            }

            ToolbarButton {
                visible: session.capturing
                glyph: session.capturePhase === "paused" ? "▶" : "❚❚"
                width: 28
                tooltip: session.capturePhase === "paused" ? "Resume Capture" : "Pause Capture"
                onClicked: {
                    if (session.capturePhase === "paused")
                        session.resumeCapture()
                    else
                        session.pauseCapture()
                }
            }

            ToolbarButton {
                text: "Open…"
                tooltip: "Open Capture"
                onClicked: openDialog.open()
            }
        }

        Row {
            anchors.centerIn: parent
            spacing: 6

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 7
                height: 7
                radius: 3.5
                color: session.connected ? Theme.systemGreen : Theme.systemRed
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: window.statusText()
                font.family: Theme.uiFont
                font.pixelSize: Theme.uiSmall
                color: Theme.secondaryLabel
            }

            BusyIndicator {
                anchors.verticalCenter: parent.verticalCenter
                width: 16
                height: 16
                running: session.loading
                visible: running
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

    // Main split --------------------------------------------------------------
    SplitView {
        anchors.top: toolbar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        orientation: Qt.Horizontal

        handle: Rectangle {
            implicitWidth: 1
            implicitHeight: 1
            color: Theme.separator
        }

        Sidebar {
            id: sidebar
            session: session
            visible: window.sidebarVisible
            SplitView.preferredWidth: Theme.sidebarDefaultWidth
            SplitView.minimumWidth: Theme.sidebarMinimumWidth
            SplitView.maximumWidth: 480
        }

        Rectangle {
            id: workspace
            color: Theme.contentBackground
            SplitView.fillWidth: true
            SplitView.minimumWidth: 480

            QuickFilterBar {
                id: quickFilter
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: Theme.quickFilterHeight
                session: session
            }

            Rectangle {
                id: errorBanner
                anchors.top: quickFilter.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                height: session.errorText !== "" ? 28 : 0
                visible: height > 0
                color: Theme.dark ? "#3a2323" : "#fdecec"

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    anchors.right: dismissError.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: session.errorText
                    elide: Text.ElideRight
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSmall
                    color: Theme.systemRed
                }

                Text {
                    id: dismissError
                    anchors.right: parent.right
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: "×"
                    font.pixelSize: 12
                    color: Theme.secondaryLabel

                    MouseArea {
                        anchors.fill: parent
                        onClicked: session.clearError()
                    }
                }
            }

            StatusStrip {
                id: statusStrip
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: Theme.statusStripHeight
                session: session
            }

            Item {
                id: viewport
                anchors.top: errorBanner.visible ? errorBanner.bottom : quickFilter.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: statusStrip.top

                PacketTableView {
                    id: productionTable
                    anchors.fill: parent
                    model: session.packets
                    follow: true
                    visible: bench.enabled ? bench.view === "table" : (session.packets.count > 0)
                }

                PacketTableListView {
                    id: listTable
                    anchors.fill: parent
                    model: session.packets
                    follow: bench.follow
                    visible: bench.enabled && bench.view === "list"
                }

                Column {
                    anchors.centerIn: parent
                    spacing: 8
                    visible: !bench.enabled && session.loading && session.packets.count === 0

                    BusyIndicator {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 24
                        height: 24
                        running: visible
                    }

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "Loading…"
                        font.family: Theme.uiFont
                        font.pixelSize: Theme.uiSize
                        color: Theme.secondaryLabel
                    }
                }

                EmptyState {
                    anchors.fill: parent
                    visible: !bench.enabled && session.packets.count === 0
                             && !session.loading && session.currentSourceID === ""
                    onStartCaptureRequested: session.startCapture(session.selectedInterface)
                    onOpenFileRequested: openDialog.open()
                }

                EmptyState {
                    anchors.fill: parent
                    visible: !bench.enabled && session.packets.count === 0
                             && !session.loading && session.currentSourceID !== ""
                    glyph: "⌁"
                    title: "No Packets"
                    message: "This capture contains no packets, or the current filter hides them all."
                    showStartAction: false
                    showOpenAction: false
                }
            }
        }
    }

    FileDialog {
        id: openDialog
        title: "Open Capture"
        fileMode: FileDialog.OpenFiles
        nameFilters: ["Capture files (*.pcap *.pcapng)", "All files (*)"]
        onAccepted: session.importFiles(selectedFiles)
    }

    Shortcut {
        sequences: ["Ctrl+O"]
        onActivated: openDialog.open()
    }

    Component.onCompleted: {
        if (bench.enabled)
            bench.start(session.packets, window)
    }

    component ToolbarButton: Rectangle {
        id: button

        property string text
        property string glyph
        property string tooltip
        signal clicked

        width: button.text !== "" ? buttonLabel.implicitWidth + 20 : 28
        height: 28
        radius: 6
        color: mouse.containsMouse
            ? Qt.rgba(Theme.label.r, Theme.label.g, Theme.label.b, 0.08)
            : "transparent"

        Text {
            id: buttonLabel
            anchors.centerIn: parent
            text: button.glyph !== "" ? button.glyph : button.text
            font.family: Theme.uiFont
            font.pixelSize: button.glyph !== "" ? 13 : Theme.uiSize
            color: Theme.label
        }

        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: button.clicked()
        }

        ToolTip.visible: mouse.containsMouse && button.tooltip !== ""
        ToolTip.text: button.tooltip
    }
}
