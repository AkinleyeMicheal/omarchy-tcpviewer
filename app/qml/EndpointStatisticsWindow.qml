import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Omarchy.TCPViewer

// Endpoint statistics window (upstream EndpointStatisticsWindowController):
// one pane per endpoint group, busiest-first table, footer totals strip.
Window {
    id: window

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

    // Fixed column widths; the sum fits the default window width.
    readonly property var columnWidths: [
        180, 70, 90, 110, 120, 70, 80, 90, 84, 90, 84, 110
    ]
    readonly property var columnTitles: [
        "Address", "Port", "Protocol", "Client", "Domain", "Packets",
        "Bytes", "Tx Packets", "Tx Bytes", "Rx Packets", "Rx Bytes", "Summary"
    ]
    readonly property var groupTitles: [
        "Apps", "Domains", "IPv4", "IPv6", "TCP", "UDP"
    ]

    function openAndRaise() {
        stats.rebuild(session.packets)
        show()
        requestActivate()
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Group tabs with live counts ---------------------------------------
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
                            text: parent.modelData + " (" + parent.count + ")"
                            font.family: Theme.uiFont
                            font.pixelSize: Theme.uiSmall
                            font.weight: parent.selected ? Font.DemiBold : Font.Normal
                            color: parent.selected ? Theme.contentBackground : Theme.label
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: stats.group = index
                        }
                    }
                }

                Item { Layout.fillWidth: true }
            }
        }

        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.separator }

        // Table ---------------------------------------------------------------
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            // Pinned header row shares the delegate's column metrics.
            Rectangle {
                id: headerRow
                width: parent.width
                height: 24
                color: Theme.headerBackground
                z: 2

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: 10

                    spacing: 0

                    Repeater {
                        model: window.columnWidths

                        delegate: Text {
                            required property int index
                            width: window.columnWidths[index]
                            height: headerRow.height - 1
                            verticalAlignment: Text.AlignVCenter
                            text: window.columnTitles[index]
                            font.family: Theme.uiFont
                            font.pixelSize: Theme.uiSmall
                            font.weight: Font.DemiBold
                            color: Theme.secondaryLabel
                            elide: Text.ElideRight
                           maximumLineCount: 1
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
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { }

                delegate: Rectangle {
                    width: table.width
                    height: 22
                    color: index === table.currentIndex
                        ? Theme.selection : (index % 2 === 1 ? Theme.rowAlternate : "transparent")

                    Row {
                        anchors.fill: parent
                        anchors.leftMargin: 10

                        Repeater {
                            model: 12

                            delegate: Text {
                                required property int index
                                width: window.columnWidths[index]
                                height: 22
                                verticalAlignment: Text.AlignVCenter
                                rightPadding: 8
                                textFormat: Text.PlainText
                                text: {
                                    switch (index) {
                                    case 0: return model.address
                                    case 1: return model.port
                                    case 2: return model.protocol
                                    case 3: return model.client
                                    case 4: return model.domain
                                    case 5: return model.packets
                                    case 6: return model.bytes
                                    case 7: return model.txPackets
                                    case 8: return model.txBytes
                                    case 9: return model.rxPackets
                                    case 10: return model.rxBytes
                                    default: return model.summary
                                    }
                                }
                                font.family: index < 5 ? Theme.uiFont : Theme.monoFont
                                font.pixelSize: Theme.uiSmall
                                color: index === table.currentIndex
                                    ? Theme.contentBackground
                                    : (index >= 5 ? Theme.secondaryLabel : Theme.label)
                                elide: Text.ElideRight
                            }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: table.currentIndex = index
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
