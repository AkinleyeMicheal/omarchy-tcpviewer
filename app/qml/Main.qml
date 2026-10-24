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
    property bool inspectorVisible: true
    property string inspectorPlacement: "trailing"
    // Workspace mode (upstream NetworkInspectorWorkspaceMode): "packets" or
    // "overview". TCPVIEWER_CAPTURE_MODE seeds it for CI/screenshot runs; the
    // seed arrives in onCompleted because sibling ids are not ready before.
    property string captureMode: "packets"

    // Workspace tabs + split panes (upstream TCPViewerWindowController):
    // every tab is a workspace; a tab may show a second side-by-side pane.
    property int tabCount: 1
    property int activeTab: 0
    // Focused workspace routes inspector fetches (per-pane selection state).
    property string focusedPaneID: "0:0"

    Action { id: openpcapAction; shortcut: "Ctrl+O"; onTriggered: openDialog.open() }
    Action { id: newTabAction; shortcut: "Ctrl+T"; onTriggered: window.newTab() }
    Action { id: closeTabAction; shortcut: "Ctrl+W"; onTriggered: window.closeActiveTab() }
    Action { id: quitAction; shortcut: "Ctrl+Q"; onTriggered: Qt.quit() }
    Action { id: focusFilterAction; shortcut: "Ctrl+F"; onTriggered: window.focusDisplayFilter() }
    Action { id: focusInspectorFilterAction; shortcut: "Ctrl+Alt+F"; onTriggered: window.focusInspectorFilter() }
    Action { id: focusSidebarFilterAction; shortcut: "Ctrl+Shift+F"; onTriggered: sidebar.focusFilter() }
    Action { id: clearPacketsAction; shortcut: "Ctrl+K"; onTriggered: session.clearPackets() }
    Action { id: showSidebarAction; shortcut: "Ctrl+B"; onTriggered: window.toggleSidebar() }
    Action { id: showInspectorAction; shortcut: "Ctrl+Shift+I"; onTriggered: window.toggleInspector() }
    Action { id: endpointsStatsAction; shortcut: "Ctrl+Shift+S"; onTriggered: statsWindow.openAndRaise() }
    Action { id: openDiffAction; shortcut: "Ctrl+Alt+Y"; onTriggered: diffWindow.openAndRaise() }
    Action { id: addSelectedDiffAction; shortcut: "Ctrl+Y"; onTriggered: window.addSelectedToDiff() }

    menuBar: MenuBar {
        id: menuBar

        Menu {
            title: qsTr("&File")
            MenuItem {
                text: qsTr("New Tab")
                action: newTabAction
            }
            MenuItem {
                text: qsTr("Open…")
                action: openpcapAction
            }
            MenuItem {
                text: qsTr("Close")
                action: closeTabAction
            }
            MenuSeparator {}
            MenuItem {
                text: qsTr("Export as pcap…")
                enabled: session.currentSourceID !== ""
                onTriggered: exportPcapDialog.open()
            }
            MenuItem {
                text: qsTr("Export as pcapng…")
                enabled: session.currentSourceID !== ""
                onTriggered: exportPcapngDialog.open()
            }
            MenuItem {
                text: qsTr("Export Session…")
                enabled: session.currentSourceID !== ""
                onTriggered: exportSessionDialog.open()
            }
            MenuSeparator {}
            MenuItem {
                text: qsTr("Quit TCP Viewer")
                action: quitAction
            }
        }

        Menu {
            title: qsTr("&Edit")
            MenuItem {
                text: qsTr("Filter")
                action: focusFilterAction
            }
            MenuSeparator {}
            MenuItem {
                text: qsTr("Clear All Packets")
                action: clearPacketsAction
            }
        }

        Menu {
            title: qsTr("&View")
            MenuItem {
                text: qsTr("Focus Sidebar Filter")
                action: focusSidebarFilterAction
            }
            MenuItem {
                text: qsTr("Focus Packet Detail Filter")
                action: focusInspectorFilterAction
            }
            MenuSeparator {}
            MenuItem {
                text: qsTr("Show Sidebar")
                action: showSidebarAction
            }
            MenuItem {
                text: qsTr("Show Inspector")
                action: showInspectorAction
            }
            MenuItem {
                text: qsTr("Toggle Split View")
                onTriggered: window.toggleSplitView()
            }
        }

        Menu {
            title: qsTr("&Tools")
            MenuItem {
                text: qsTr("Follow TCP Stream")
                enabled: session.selectedPacketID !== ""
                onTriggered: follow.follow(session.selectedPacketID)
            }
        }

        Menu {
            title: qsTr("&Statistics")
            MenuItem {
                text: qsTr("Endpoints…")
                action: endpointsStatsAction
            }
        }

        Menu {
            title: qsTr("&Diff")
            MenuItem {
                text: qsTr("Open Diff View…")
                action: openDiffAction
            }
            MenuItem {
                text: qsTr("Add Selected Items to Diff Pool…")
                action: addSelectedDiffAction
            }
        }
    }
    function activeWorkspace() {
        var tab = tabsRepeater.itemAt(activeTab)
        return tab ? tab.firstPane : null
    }

    function focusDisplayFilter() {
        var pane = activeWorkspace()
        if (pane)
            pane.focusDisplayFilter()
    }

    function focusInspectorFilter() {
        var pane = activeWorkspace()
        if (pane) {
            inspectorVisible = true
            pane.focusInspectorFilter()
        }
    }

    function toggleSidebar() { sidebarVisible = !sidebarVisible }
    function toggleInspector() { inspectorVisible = !inspectorVisible }
    function toggleSplitView() { toggleSplit() }

    function newTab() {
        // Upstream: ⌘T adds a workspace tab. Tabs share the current source in
        // this port; each tab keeps its own panes, selection and inspector.
        tabCount += 1
        activeTab = tabCount - 1
        focusedPaneID = (tabCount - 1) + ":0"
    }

    function closeActiveTab() {
        if (tabCount <= 1)
            return
        tabCount -= 1
        if (activeTab >= tabCount)
            activeTab = tabCount - 1
        focusedPaneID = activeTab + ":0"
    }

    function toggleSplit() {
        var tab = tabsRepeater.itemAt(activeTab)
        if (tab)
            tab.splitVisible = !tab.splitVisible
    }

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
        if (session.currentSourceID !== "") {
            if (session.status.kind === "offline")
                return session.loading ? "Loading capture…" : "Loaded"
            return session.loading ? "Loading capture…" : "Capture ready"
        }
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
                visible: !session.interfacesHidden
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
                visible: !session.interfacesHidden
                color: !session.connected
                    ? Theme.separator
                    : (session.capturing ? Theme.systemRed : Theme.accent)

                Text {
                    anchors.centerIn: parent
                    text: session.capturing ? "Stop" : "Start"
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSmall
                    font.weight: Font.DemiBold
                    color: "white"
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        if (session.capturing)
                            session.stopCapture()
                        else
                            session.startCapture(session.selectedInterface)
                    }
                }
            }

            ToolbarButton {
                text: "Open…"
                tooltip: "Open Capture"
                onClicked: openDialog.open()
            }
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6

            ToolbarButton {
                glyph: "Σ"
                width: 28
                tooltip: "Endpoint Statistics"
                onClicked: statsWindow.openAndRaise()
            }

            ToolbarButton {
                glyph: "◫"
                width: 28
                tooltip: "Toggle Split View"
                onClicked: window.toggleSplit()
            }

            ToolbarButton {
                glyph: "▤"
                width: 28
                tooltip: window.inspectorVisible ? "Hide Inspector" : "Show Inspector"
                onClicked: window.inspectorVisible = !window.inspectorVisible
            }

            ToolbarButton {
                glyph: window.inspectorPlacement === "trailing" ? "⇅" : "☰"
                width: 28
                tooltip: window.inspectorPlacement === "trailing"
                    ? "Move Inspector to Bottom" : "Move Inspector to Side"
                onClicked: {
                    window.inspectorPlacement =
                        window.inspectorPlacement === "trailing" ? "bottom" : "trailing"
                }
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
                textFormat: Text.PlainText
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

    // Tab bar (upstream TCPViewerWorkspaceTabBar); only shown past one tab.
    Rectangle {
        id: tabBarStrip
        anchors.top: toolbar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: window.tabCount > 1 ? 30 : 0
        visible: height > 0
        color: Theme.headerBackground

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8
            spacing: 4

            Repeater {
                model: window.tabCount

                delegate: Rectangle {
                    required property int index

                    width: 168
                    height: 22
                    radius: 6
                    color: window.activeTab === index
                        ? Theme.contentBackground : "transparent"
                    border.width: window.activeTab === index ? 1 : 0
                    border.color: Theme.separator

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Capture " + (parent.index + 1)
                        font.family: Theme.uiFont
                        font.pixelSize: Theme.uiSmall
                        font.weight: window.activeTab === parent.index ? Font.DemiBold : Font.Normal
                        color: Theme.label
                    }

                    Text {
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        visible: window.tabCount > 1
                        text: "×"
                        font.pixelSize: 12
                        color: closeMouse.containsMouse ? Theme.label : Theme.secondaryLabel

                        MouseArea {
                            id: closeMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: {
                                window.tabCount -= 1
                                if (window.activeTab >= window.tabCount)
                                    window.activeTab = window.tabCount - 1
                                window.focusedPaneID = window.activeTab + ":0"
                            }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: window.activeTab = parent.index
                    }
                }
            }

            ToolbarButton {
                glyph: "+"
                width: 24
                tooltip: "New Tab"
                onClicked: window.newTab()
            }

            Item { Layout.fillWidth: true }
        }
    }

    // Main split: sidebar | workspace panes -------------------------------------
    SplitView {
        anchors.top: tabBarStrip.bottom
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
            id: contentHost
            color: "transparent"

            StackLayout {
                id: tabHost
                anchors.fill: parent
                currentIndex: window.activeTab

                Repeater {
                    id: tabsRepeater
                    model: window.tabCount

                    delegate: Item {
                        id: tabContent
                        required property int index

                        // Split is remembered per tab; the launch hook seeds tab 0.
                        property bool splitVisible: session.startupSplit && index === 0
                        property alias firstPane: pane0
                        property alias secondPane: pane1

                        clip: true

                        SplitView {
                            id: paneSplit
                            anchors.fill: parent
                            orientation: Qt.Horizontal

                            handle: Rectangle {
                                implicitWidth: 1
                                implicitHeight: 1
                                color: Theme.separator
                            }

                            Workspace {
                                id: pane0
                                paneID: tabContent.index + ":0"
                                controller: session
                                isPrimary: tabContent.index === 0
                                SplitView.fillWidth: true
                                SplitView.minimumWidth: 420
                            }

                            Workspace {
                                id: pane1
                                paneID: tabContent.index + ":1"
                                controller: session
                                isPrimary: false
                                visible: tabContent.splitVisible
                                SplitView.fillWidth: true
                                SplitView.minimumWidth: 420
                            }
                        }
                    }
                }
            }
        }
    }

    // Follow reveal lands in the active tab's first pane (main window pane 0).
    Connections {
        target: session
        function onRevealRequested(packetID) {
            var tab = tabsRepeater.itemAt(window.activeTab)
            if (tab)
                tab.firstPane.revealPacket(String(packetID))
        }
    }

    FileDialog {
        id: openDialog
        title: "Open Capture"
        fileMode: FileDialog.OpenFiles
        nameFilters: ["Capture files (*.pcap *.pcapng)", "All files (*)"]
        onAccepted: session.importFiles(selectedFiles)
    }

    FileDialog {
        id: exportPcapDialog
        title: "Export as pcap"
        fileMode: FileDialog.SaveFile
        defaultSuffix: "pcap"
        nameFilters: ["pcap (*.pcap)"]
        onAccepted: session.exportAll(fileDialogPath(selectedFile), "pcap")
    }

    FileDialog {
        id: exportPcapngDialog
        title: "Export as pcapng"
        fileMode: FileDialog.SaveFile
        defaultSuffix: "pcapng"
        nameFilters: ["pcapng (*.pcapng)"]
        onAccepted: session.exportAll(fileDialogPath(selectedFile), "pcapng")
    }

    FileDialog {
        id: exportSessionDialog
        title: "Export Session"
        fileMode: FileDialog.SaveFile
        defaultSuffix: "tcpviewersession"
        nameFilters: ["TCPViewer session (*.tcpviewersession)"]
        onAccepted: session.exportSession(fileDialogPath(selectedFile))
    }

    // Bench + dialog helpers: inline components resolve document ids
    // unreliably, so they reach these through window properties/functions.
    readonly property bool benchEnabled: bench.enabled
    readonly property string benchView: bench.view
    readonly property bool benchFollowIds: bench.follow

    function openContextMenu(index, globalX, globalY) {
        rowContextMenu.openFor(index, globalX, globalY)
    }

    function fileDialogPath(file) {
        const value = String(file)
        if (value.startsWith("file://"))
            return decodeURIComponent(value.slice("file://".length))
        return value
    }

    // Upstream Diff menu (⌘Y): snapshot the selected packet into the pool.
    function addSelectedToDiff() {
        if (session.selectedPacketID === "")
            return
        const row = session.packets.rowForPacketID(session.selectedPacketID)
        if (row < 0)
            return
        diff.addPacket(session.currentSourceID, session.selectedPacketID,
                       session.packets.numberAt(row), session.packets.summaryAt(row))
        diffWindow.openAndRaise()
    }

    function openCaptureDialog() {
        openDialog.open()
    }

    // Follow Stream -------------------------------------------------------------
    FollowSessionController {
        id: follow
    }

    FollowStreamWindow {
        id: followWindow
        visible: false
        follow: follow
        session: session
    }

    Connections {
        target: follow
        // Open or raise the workspace after the response lands, matching
        // upstream FollowStreamWindowController.present().
        function onFollowReady() {
            followWindow.openAndRaise()
        }
    }

    // Row context menu (upstream Tools ▸ "Follow TCP Stream" menu item keeps the
    // title per protocol; here it lives on the table's right-click menu).
    Menu {
        id: rowContextMenu
        property int pendingRow: -1
        property string pendingProtocol: ""

        function openFor(index, globalX, globalY) {
            pendingRow = index
            pendingProtocol = String(session.packets.protocolAt(index)).toUpperCase()
            popup(globalX, globalY)
        }

        MenuItem {
            text: rowContextMenu.pendingProtocol.indexOf("TCP") >= 0
                ? "Follow TCP Stream" : "Follow UDP Stream"
            onTriggered: follow.follow(String(session.packets.packetIDAt(rowContextMenu.pendingRow)))
        }

        MenuItem {
            text: "Diff Selected Packet"
            onTriggered: {
                const row = rowContextMenu.pendingRow
                if (row < 0)
                    return
                diff.addPacket(session.currentSourceID, session.packets.packetIDAt(row),
                               session.packets.numberAt(row), session.packets.summaryAt(row))
                diffWindow.openAndRaise()
            }
        }
    }

    // Diff window (upstream DiffWindowController).
    DiffController {
        id: diff
    }

    DiffWindow {
        id: diffWindow
        diff: diff
    }

    // Endpoint statistics (toolbar Σ), upstream Tools item.
    EndpointStatisticsModel {
        id: endpointStats
    }

    EndpointStatisticsWindow {
        id: statsWindow
        visible: false
        stats: endpointStats
        session: session
    }

    Component.onCompleted: {
        // CI/screenshot hooks: workspace mode seed, statistics window, benchmark.
        window.captureMode = session.startupCaptureMode
        if (session.startupWindowWidth > 0)
            window.width = session.startupWindowWidth
        if (session.startupWindowHeight > 0)
            window.height = session.startupWindowHeight
        var tabs = session.startupTabs
        if (tabs > window.tabCount)
            window.tabCount = tabs
        if (session.startupStatistics)
            statsTimer.start()
        if (session.startupDiffPackets !== "")
            diffTimer.start()
        if (bench.enabled)
            bench.start(session.packets, window)
    }

    Timer {
        id: statsTimer
        interval: 1500
        repeat: false
        onTriggered: statsWindow.openAndRaise()
    }

    // CI/screenshot hook: wait for the capture rows, then compare the IDs.
    Timer {
        id: diffTimer
        interval: 400
        repeat: true
        onTriggered: {
            const ids = session.startupDiffPackets.split(",")
            const rows = []
            for (let i = 0; i < ids.length; ++i) {
                const row = session.packets.rowForPacketID(ids[i].trim())
                if (row < 0)
                    return
                rows.push(row)
            }
            diffTimer.stop()
            for (let i = 0; i < rows.length; ++i) {
                const row = rows[i]
                diff.addPacket(session.currentSourceID, session.packets.packetIDAt(row),
                               session.packets.numberAt(row), session.packets.summaryAt(row))
            }
            diffWindow.openAndRaise()
        }
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

    // One workspace pane (upstream per-pane root controller): filter bar, error
    // strip, table stack and status strip share the table area; the pane-owned
    // inspector is the split tail.
    component Workspace: Rectangle {
        id: workspace

        required property string paneID
        required property SessionController controller
        property bool isPrimary: true
        // Focused workspace routes inspector fetches for session selections.
        readonly property bool focused: window.focusedPaneID === paneID

        function focusPane() {
            window.focusedPaneID = workspace.paneID
        }

        function focusDisplayFilter() {
            quickFilter.focusDisplayFilter()
        }

        function focusInspectorFilter() {
            paneInspectorView.focusFilter()
        }

        function presentPacket(packetID) {
            focusPane()
            controller.selectPacket(packetID)
            if (!window.benchEnabled)
                paneInspector.select(packetID, controller.currentSourceID)
        }

        // Reveal path (follow-window): highlight this pane and fetch here.
        function revealPacket(packetID) {
            focusPane()
            controller.selectPacket(packetID)
            paneTable.selectedIndex = packetID === ""
                ? -1 : controller.packets.rowForPacketID(packetID)
            if (!window.benchEnabled)
                paneInspector.select(packetID, controller.currentSourceID)
        }

        color: Theme.contentBackground

        PacketInspector { id: paneInspector }

        SplitView {
            id: paneLayout
            anchors.fill: parent
            orientation: window.inspectorPlacement === "bottom" ? Qt.Vertical : Qt.Horizontal

            handle: Rectangle {
                implicitWidth: 1
                implicitHeight: 1
                color: Theme.separator
            }

            // Table area -----------------------------------------------------
            Item {
                id: tableArea
                SplitView.fillWidth: true
                SplitView.fillHeight: true
                SplitView.minimumWidth: 420
                SplitView.minimumHeight: 160

                QuickFilterBar {
                    id: quickFilter
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: Theme.quickFilterHeight
                    session: controller
                    workspaceMode: window.captureMode
                    onWorkspaceModeChanged: {
                        if (window.captureMode !== workspaceMode)
                            window.captureMode = workspaceMode
                    }
                }

                Rectangle {
                    id: errorBanner
                    anchors.top: quickFilter.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: controller.errorText !== "" ? 28 : 0
                    visible: height > 0
                    color: Theme.dark ? "#3a2323" : "#fdecec"

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        anchors.right: dismissError.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: controller.errorText
                textFormat: Text.PlainText
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
                            onClicked: controller.clearError()
                        }
                    }
                }

                StatusStrip {
                    id: statusStrip
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: Theme.statusStripHeight
                    session: controller
                }

                Item {
                    id: viewport
                    anchors.top: errorBanner.visible ? errorBanner.bottom : quickFilter.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: statusStrip.top

                    PacketTableView {
                        id: paneTable
                        anchors.fill: parent
                        model: session.packets
                        columnLayout: session.columnLayout
                        customColumns: session.customColumns
                        follow: true
                        visible: (!window.benchEnabled || workspace.isPrimary)
                            && window.captureMode === "packets"
                            && (window.benchEnabled ? window.benchView === "table" : (controller.packets.count > 0))
                        onRowClicked: function(index) {
                            if (window.benchEnabled)
                                return
                            workspace.presentPacket(controller.packets.packetIDAt(index))
                        }
                        onRowContextClicked: function(index, globalX, globalY) {
                            if (window.benchEnabled)
                                return
                            window.openContextMenu(index, globalX, globalY)
                        }
                    }

                    PacketTableListView {
                        id: listTable
                        anchors.fill: parent
                        model: session.packets
                        follow: window.benchFollowIds
                        visible: window.benchEnabled && workspace.isPrimary && window.benchView === "list"
                    }

                    Overview {
                        id: overviewPane
                        anchors.fill: parent
                        session: controller
                        visible: window.captureMode === "overview"
                    }

                    Column {
                        anchors.centerIn: parent
                        spacing: 8
                        visible: !window.benchEnabled && window.captureMode === "packets"
                                 && controller.loading && controller.packets.count === 0

                        BusyIndicator {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 24
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
                        visible: !window.benchEnabled && window.captureMode === "packets"
                                 && controller.packets.count === 0
                                 && !controller.loading && controller.currentSourceID === ""
                        onStartCaptureRequested: session.startCapture(session.selectedInterface)
                        onOpenFileRequested: window.openCaptureDialog()
                    }

                    EmptyState {
                        anchors.fill: parent
                        visible: !window.benchEnabled && window.captureMode === "packets"
                                 && controller.packets.count === 0
                                 && !controller.loading && controller.currentSourceID !== ""
                        glyph: "⌁"
                        title: "No Packets"
                        message: "This capture contains no packets, or the current filter hides them all."
                        showStartAction: false
                        showOpenAction: false
                    }
                }
            }

            // Inspector (pane-owned detail + hex state) ----------------------
            Inspector {
                id: paneInspectorView
                inspector: paneInspector
                session: controller
                visible: window.inspectorVisible && !window.benchEnabled
                         && window.captureMode !== "overview"
                SplitView.preferredWidth: window.inspectorVisible
                    && window.captureMode !== "overview"
                    && window.inspectorPlacement === "trailing" ? 360 : 0
                SplitView.minimumWidth: window.inspectorVisible
                    && window.captureMode !== "overview"
                    && window.inspectorPlacement === "trailing" ? 240 : 0
                SplitView.maximumWidth: window.inspectorPlacement === "trailing" ? 600 : 0
                SplitView.preferredHeight: window.inspectorPlacement === "bottom" ? 280 : 0
                SplitView.minimumHeight: window.inspectorPlacement === "bottom" ? 160 : 0
                SplitView.maximumHeight: window.inspectorPlacement === "bottom" ? 560 : 0
            }
        }

        Connections {
            target: session
            function onSelectedPacketIDChanged() {
                // Highlight mirrors the global selection; the focused pane also
                // drives its inspector (upstream per-pane inspector state).
                paneTable.selectedIndex = session.selectedPacketID === ""
                    ? -1
                    : controller.packets.rowForPacketID(session.selectedPacketID)
                if (workspace.focused && !window.benchEnabled)
                    paneInspector.select(session.selectedPacketID, controller.currentSourceID)
            }
        }
    }
}
