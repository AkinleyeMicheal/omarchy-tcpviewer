import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Omarchy.TCPViewer
import "OverviewFormat.js" as Format

// TCP analysis card (upstream CaptureOverviewTCPAnalysisCard): one segmented
// bar for every flagged packet and a clickable legend with the exact count
// and share for each Wireshark expert flag.
Item {
    id: root

    // Rows: { kind, title, count, percentText, color, filter, help }
    property var rows: []
    property int tcpPackets: 0
    property int totalPackets: 0
    property string emptyTitle: "No TCP problems detected"
    property string emptyDetail: "No retransmissions, lost segments, zero windows or resets."

    signal filterActivated(string filter)

    readonly property int segmentTotal: {
        var total = 0
        for (var i = 0; i < rows.length; i++)
            total += Number(rows[i].count) || 0
        return total
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 10
        visible: root.rows.length > 0

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 10
            radius: 5
            color: Theme.separator
            clip: true

            Row {
                width: parent.width
                height: parent.height

                Repeater {
                    model: root.rows

                    delegate: Rectangle {
                        required property var modelData

                        width: root.segmentTotal > 0
                            ? parent.width * (Number(modelData.count) || 0) / root.segmentTotal
                            : 0
                        height: parent.height
                        color: modelData.color || Theme.systemRed
                    }
                }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            Repeater {
                model: root.rows

                delegate: Item {
                    id: issueRow

                    required property var modelData

                    Layout.fillWidth: true
                    Layout.preferredHeight: 24

                    Rectangle {
                        anchors.fill: parent
                        radius: 5
                        color: Theme.rowAlternate
                        opacity: issueHover.containsMouse ? 1 : 0
                    }

                    RowLayout {
                        anchors.fill: parent
                        spacing: 8

                        Rectangle {
                            width: 8
                            height: 8
                            radius: 4
                            Layout.alignment: Qt.AlignVCenter
                            color: issueRow.modelData.color || Theme.systemRed
                        }

                        Text {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            text: issueRow.modelData.title || ""
                            font.family: Theme.uiFont
                            font.pixelSize: 12
                            color: Theme.label
                        }

                        Text {
                            text: issueRow.modelData.countText || ""
                            font.family: Theme.monoFont
                            font.pixelSize: 11
                            font.weight: Font.DemiBold
                            color: Theme.label
                        }

                        Text {
                            Layout.preferredWidth: 38
                            horizontalAlignment: Text.AlignRight
                            text: issueRow.modelData.percentText || ""
                            font.family: Theme.monoFont
                            font.pixelSize: 10
                            color: Theme.secondaryLabel
                        }
                    }

                    MouseArea {
                        id: issueHover

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.filterActivated(issueRow.modelData.filter || "")
                        ToolTip.visible: containsMouse
                        ToolTip.text: issueRow.modelData.help || ""
                        ToolTip.delay: 500
                    }
                }
            }
        }
    }

    Column {
        anchors.centerIn: parent
        width: Math.min(parent.width - 16, 280)
        spacing: 8
        visible: root.rows.length === 0

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 42
            height: 42
            radius: 21
            color: Qt.rgba(Theme.systemGreen.r, Theme.systemGreen.g,
                           Theme.systemGreen.b, 0.14)

            Text {
                anchors.centerIn: parent
                text: "✓"
                font.family: Theme.uiFont
                font.pixelSize: 22
                font.weight: Font.DemiBold
                color: Theme.systemGreen
            }
        }

        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: root.emptyTitle
            font.family: Theme.uiFont
            font.pixelSize: 13
            font.weight: Font.DemiBold
            color: Theme.label
        }

        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: root.emptyDetail
            font.family: Theme.uiFont
            font.pixelSize: 11
            color: Theme.secondaryLabel
        }
    }
}
