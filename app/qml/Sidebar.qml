import QtQuick
import QtQuick.Controls
import Omarchy.TCPViewer

// Upstream packet-source tree (SidebarViewController / PacketSourceListService):
// Capture/Files sources, then All -> Apps (app -> domains/IPs) and Domains
// (domain -> IPs under the IP Addresses pseudo-domain). Counts and filtering
// are computed from the loaded packet summaries in SourceTreeModel.
Rectangle {
    id: root

    required property SessionController session

    color: Theme.dark ? "#232323" : "#f6f6f6"

    function basename(path) {
        var value = String(path || "")
        var slash = value.lastIndexOf("/")
        return slash >= 0 ? value.substring(slash + 1) : value
    }

    function sourceKind(source) {
        return String(source.kind || "")
    }

    function focusFilter() {
        filterField.forceActiveFocus()
        filterField.selectAll()
    }

    function glyphFor(kind) {
        switch (String(kind)) {
        case "all": return "◉"
        case "group": return "▤"
        case "app": return "●"
        case "domain": return "◍"
        case "ip": return "◇"
        default: return "·"
        }
    }

    readonly property var liveSources: {
        var result = []
        for (var i = 0; i < session.sources.length; ++i) {
            if (sourceKind(session.sources[i]) === "live")
                result.push(session.sources[i])
        }
        return result
    }

    readonly property var fileSources: {
        var result = []
        for (var i = 0; i < session.sources.length; ++i) {
            var kind = sourceKind(session.sources[i])
            if (kind !== "live")
                result.push(session.sources[i])
        }
        return result
    }

    ListView {
        id: treeList
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: filterArea.top
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.session.sourceTree

        // Structural tree updates reset the flat model. Keep the user's
        // scroll position instead of jumping to the top during live capture.
        property real preservedContentY: 0
        property bool restoringContentY: false
        onContentYChanged: {
            if (!restoringContentY)
                preservedContentY = contentY
        }

        Connections {
            target: root.session.sourceTree
            function onModelReset() {
                treeList.restoringContentY = true
                var targetY = treeList.preservedContentY
                Qt.callLater(function() {
                    treeList.contentY = Math.min(targetY,
                        Math.max(0, treeList.contentHeight - treeList.height))
                    treeList.restoringContentY = false
                })
            }
        }

        header: Item {
            width: treeList.width
            height: headerColumn.height + 12

            Column {
                id: headerColumn
                y: 6
                width: parent.width

                GroupHeader { text: "Capture" }

                Repeater {
                    model: root.liveSources
                    delegate: SourceRow {
                        required property var modelData
                        width: treeList.width
                        source: modelData
                    }
                }

                SidebarPlaceholder {
                    visible: root.liveSources.length === 0
                    width: treeList.width
                    text: "No live capture"
                }

                GroupHeader { text: "Files" }

                Repeater {
                    model: root.fileSources
                    delegate: SourceRow {
                        required property var modelData
                        width: treeList.width
                        source: modelData
                    }
                }

                SidebarPlaceholder {
                    visible: root.fileSources.length === 0
                    width: treeList.width
                    text: "No open files"
                }

                GroupHeader { text: "All" }
            }
        }

        delegate: TreeRow {
            width: treeList.width
            nodeId: model.nodeId
            title: model.title
            nodeCount: model.count
            kind: model.kind
            depth: model.depth
            expanded: model.expanded
            hasChildren: model.hasChildren
            selected: model.selected
        }

        footer: Item {
            width: treeList.width
            height: showEmpty ? 34 : 8

            readonly property bool showEmpty: root.session.currentSourceID !== ""
                && root.session.sourceTree.count <= 1

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 20
                anchors.verticalCenter: parent.verticalCenter
                visible: parent.showEmpty
                text: "No packets"
                font.family: Theme.uiFont
                font.pixelSize: Theme.uiSize
                color: Theme.secondaryLabel
                opacity: 0.75
            }
        }
    }

    // Upstream sidebar has a filter field pinned to the bottom of the tree.
    Rectangle {
        id: filterArea
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 34
        color: parent.color

        Rectangle {
            anchors.fill: parent
            anchors.margins: 6
            radius: 6
            color: Theme.windowBackground
            border.width: 1
            border.color: filterField.activeFocus ? Theme.accent : Theme.separator
        }

        TextField {
            id: filterField
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            background: null
            padding: 0
            verticalAlignment: TextInput.AlignVCenter
            placeholderText: "Filter"
            placeholderTextColor: Theme.secondaryLabel
            color: Theme.label
            selectionColor: Theme.accent
            selectedTextColor: "white"
            font.family: Theme.monoFont
            font.pixelSize: Theme.uiSmall
            selectByMouse: true
            onTextChanged: {
                const value = text
                treeList.positionViewAtBeginning()
                root.session.sourceTree.filterText = value
            }
        }
    }

    component GroupHeader: Item {
        id: header

        property string text

        width: parent ? parent.width : 0
        height: 26

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            text: header.text
            font.family: Theme.uiFont
            font.pixelSize: Theme.uiSmall
            font.weight: Font.DemiBold
            color: Theme.secondaryLabel
        }
    }

    component SidebarPlaceholder: Item {
        id: placeholder

        property string text

        width: parent ? parent.width : 0
        height: 28

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 20
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: placeholder.text
            elide: Text.ElideRight
            font.family: Theme.uiFont
            font.pixelSize: Theme.uiSize
            color: Theme.secondaryLabel
            opacity: 0.75
        }
    }

    component TreeRow: Item {
        id: row

        property string nodeId
        property string title
        property int nodeCount
        property string kind
        property int depth
        property bool expanded
        property bool hasChildren
        property bool selected

        readonly property bool hovered: mouse.containsMouse

        height: Theme.sidebarRowHeight

        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            radius: 6
            color: row.selected
                ? Theme.selection
                : (row.hovered ? Qt.rgba(Theme.label.r, Theme.label.g, Theme.label.b, 0.06)
                               : "transparent")
        }

        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton
            onClicked: root.session.selectTreeFilter(row.nodeId)
        }

        Item {
            id: chevron
            anchors.left: parent.left
            anchors.leftMargin: 10 + row.depth * 14
            anchors.verticalCenter: parent.verticalCenter
            width: 14
            height: parent.height

            Text {
                anchors.centerIn: parent
                visible: row.hasChildren
                text: row.expanded ? "▾" : "▸"
                font.family: Theme.uiFont
                font.pixelSize: 10
                color: row.selected ? "white" : Theme.secondaryLabel
            }

            MouseArea {
                anchors.fill: parent
                enabled: row.hasChildren
                onClicked: root.session.toggleTreeExpanded(row.nodeId)
            }
        }

        Text {
            id: glyph
            anchors.left: chevron.right
            anchors.leftMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            text: root.glyphFor(row.kind)
            font.family: Theme.uiFont
            font.pixelSize: row.kind === "app" ? 9 : 12
            color: row.selected ? "white" : Theme.secondaryLabel
        }

        Text {
            anchors.left: glyph.right
            anchors.leftMargin: 7
            anchors.right: countLabel.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: row.title
            textFormat: Text.PlainText
            elide: Text.ElideMiddle
            font.family: Theme.uiFont
            font.pixelSize: Theme.uiSize
            color: row.selected ? "white" : Theme.label
        }

        Text {
            id: countLabel
            anchors.right: parent.right
            anchors.rightMargin: 22
            anchors.verticalCenter: parent.verticalCenter
            text: Number(row.nodeCount || 0).toLocaleString(Qt.locale(), "f", 0)
            font.family: Theme.monoFont
            font.pixelSize: Theme.uiSmall
            color: row.selected ? Qt.rgba(1, 1, 1, 0.8) : Theme.secondaryLabel
        }
    }

    component SourceRow: Item {
        id: row

        required property var source

        height: Theme.sidebarRowHeight

        readonly property bool selected: root.session.currentSourceID === String(source.source_id)
        readonly property bool isLive: String(source.kind) === "live"
        readonly property string title: isLive
            ? "Live: " + String(source.interface || "Capture")
            : root.basename(source.path)
        readonly property bool hovered: mouse.containsMouse

        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            radius: 6
            color: row.selected
                ? Theme.selection
                : (row.hovered ? Qt.rgba(Theme.label.r, Theme.label.g, Theme.label.b, 0.06)
                               : "transparent")
        }

        Text {
            id: glyph
            anchors.left: parent.left
            anchors.leftMargin: 18
            anchors.verticalCenter: parent.verticalCenter
            text: row.isLive ? "●" : "▤"
            font.family: Theme.uiFont
            font.pixelSize: row.isLive ? 9 : 12
            color: row.selected ? "white" : (row.isLive ? Theme.systemGreen : Theme.secondaryLabel)
        }

        Text {
            anchors.left: glyph.right
            anchors.leftMargin: 8
            anchors.right: countLabel.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: row.title
            textFormat: Text.PlainText
            elide: Text.ElideMiddle
            font.family: Theme.uiFont
            font.pixelSize: Theme.uiSize
            color: row.selected ? "white" : Theme.label
        }

        Text {
            id: countLabel
            anchors.right: parent.right
            anchors.rightMargin: 22
            anchors.verticalCenter: parent.verticalCenter
            text: Number(source.packet_count || 0).toLocaleString(Qt.locale(), "f", 0)
            font.family: Theme.monoFont
            font.pixelSize: Theme.uiSmall
            color: row.selected ? Qt.rgba(1, 1, 1, 0.8) : Theme.secondaryLabel
        }

        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton
            onClicked: root.session.selectSource(String(row.source.source_id))
        }

        Rectangle {
            id: closeButton
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            width: 16
            height: 16
            radius: 8
            visible: row.hovered && !row.isLive
            color: closeMouse.containsMouse ? Qt.rgba(0, 0, 0, 0.12) : "transparent"

            Text {
                anchors.centerIn: parent
                text: "×"
                font.family: Theme.uiFont
                font.pixelSize: 12
                color: row.selected ? "white" : Theme.secondaryLabel
            }

            MouseArea {
                id: closeMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: root.session.closeSource(String(row.source.source_id))
            }
        }
    }
}
