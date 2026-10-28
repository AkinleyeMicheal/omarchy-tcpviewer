import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Omarchy.TCPViewer
import "OverviewFormat.js" as Format

// Ranked Overview rows (upstream CaptureOverviewRowsCard): leading app icon,
// service port badge, warning pill, split sent/received bar and bytes value.
// Each row is clickable and opens the matching packets in the packet table.
Item {
    id: root

    // Rows are built by Overview.qml:
    // { title, badgeText, glyph, tint, valueText, detailText, issueCount,
    //   sentFraction, receivedFraction, unknownFraction, usesSplit,
    //   clickable, actionKind, actionValue, help }
    property var rows: []
    property string emptyText: "No traffic in this packet range."

    signal rowActivated(var row)

    readonly property real maximumBytes: {
        var maximum = 0
        for (var i = 0; i < rows.length; i++)
            maximum = Math.max(maximum, Number(rows[i].bytes) || 0)
        return maximum
    }

    ListView {
        id: list

        anchors.fill: parent
        visible: root.rows.length > 0
        model: root.rows
        spacing: 0
        clip: true
        interactive: false
        boundsBehavior: Flickable.StopAtBounds

        delegate: Item {
            id: delegateRow

            required property var modelData

            width: list.width
            height: 38

            readonly property real bytes: Number(modelData.bytes) || 0
            readonly property real share: root.maximumBytes > 0
                ? Math.min(1, bytes / root.maximumBytes) : 0
            readonly property bool clickable: modelData.clickable === true

            Rectangle {
                anchors.fill: parent
                radius: 6
                color: Theme.rowAlternate
                opacity: rowHover.containsMouse && delegateRow.clickable ? 1 : 0
            }

            Row {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                height: 30
                spacing: 10

                Item {
                    width: 40
                    height: parent.height

                    Rectangle {
                        visible: delegateRow.modelData.badgeText !== undefined
                                 && String(delegateRow.modelData.badgeText).length > 0
                        width: 40
                        height: 22
                        radius: 6
                        anchors.verticalCenter: parent.verticalCenter
                        color: Qt.rgba(Theme.systemMint.r, Theme.systemMint.g,
                                       Theme.systemMint.b, 0.14)

                        Text {
                            anchors.centerIn: parent
                            text: delegateRow.modelData.badgeText || ""
                            font.family: Theme.uiFont
                            font.pixelSize: 10
                            font.weight: Font.DemiBold
                            color: Theme.systemMint
                        }
                    }

                    Rectangle {
                        visible: delegateRow.modelData.badgeText === undefined
                                 || String(delegateRow.modelData.badgeText).length === 0
                        width: 22
                        height: 22
                        radius: 6
                        anchors.verticalCenter: parent.verticalCenter
                        color: delegateRow.modelData.tint || Theme.accent

                        Text {
                            anchors.centerIn: parent
                            text: delegateRow.modelData.glyph || "•"
                            font.family: Theme.uiFont
                            font.pixelSize: 11
                            font.weight: Font.DemiBold
                            color: "#ffffff"
                        }
                    }
                }

                Column {
                    width: parent.width - 50
                    spacing: 4
                    anchors.verticalCenter: parent.verticalCenter

                    RowLayout {
                        width: parent.width
                        spacing: 6

                        Rectangle {
                            id: warningPill

                            visible: Number(delegateRow.modelData.issueCount) > 0
                            width: warningText.implicitWidth + 9
                            height: 15
                            radius: 7.5
                            color: Qt.rgba(Theme.systemRed.r, Theme.systemRed.g,
                                           Theme.systemRed.b, 0.14)
                            Layout.alignment: Qt.AlignVCenter

                            Text {
                                id: warningText

                                anchors.centerIn: parent
                                text: "⚠ " + Format.count(delegateRow.modelData.issueCount)
                                font.family: Theme.uiFont
                                font.pixelSize: 9
                                font.weight: Font.DemiBold
                                color: Theme.systemRed
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            elide: Text.ElideMiddle
                            text: delegateRow.modelData.title || ""
                            font.family: Theme.uiFont
                            font.pixelSize: 12
                            font.weight: Font.Medium
                            color: Theme.label
                        }

                        Text {
                            Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            text: delegateRow.modelData.valueText || ""
                            font.family: Theme.monoFont
                            font.pixelSize: 11
                            font.weight: Font.DemiBold
                            color: Theme.label
                        }
                    }

                    RowLayout {
                        width: parent.width
                        spacing: 8

                        Rectangle {
                            id: track

                            Layout.fillWidth: true
                            height: 4
                            radius: 2
                            color: Theme.separator
                            clip: true

                            Row {
                                width: track.width * delegateRow.share
                                height: track.height

                                Rectangle {
                                    width: track.width * (Number(delegateRow.modelData.sentFraction) || 0)
                                    height: track.height
                                    color: Theme.systemPurple
                                }
                                Rectangle {
                                    width: track.width * (Number(delegateRow.modelData.receivedFraction) || 0)
                                    height: track.height
                                    color: Theme.systemBlue
                                }
                                Rectangle {
                                    width: track.width * (Number(delegateRow.modelData.unknownFraction) || 0)
                                    height: track.height
                                    color: delegateRow.modelData.usesSplit === true
                                        ? Theme.systemGray : Theme.accent
                                }
                            }
                        }

                        Text {
                            Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            text: delegateRow.modelData.detailText || ""
                            font.family: Theme.uiFont
                            font.pixelSize: 9
                            color: Theme.secondaryLabel
                        }
                    }
                }
            }

            MouseArea {
                id: rowHover

                anchors.fill: parent
                hoverEnabled: true
                cursorShape: delegateRow.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                    if (delegateRow.clickable)
                        root.rowActivated(delegateRow.modelData)
                }

                ToolTip.visible: containsMouse && delegateRow.modelData.help !== undefined
                                 && String(delegateRow.modelData.help).length > 0
                ToolTip.text: delegateRow.modelData.help || ""
                ToolTip.delay: 500
            }
        }
    }

    Label {
        anchors.centerIn: parent
        width: Math.min(parent.width - 16, 280)
        visible: root.rows.length === 0
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        text: root.emptyText
        font.family: Theme.uiFont
        font.pixelSize: Theme.uiSmall
        color: Theme.secondaryLabel
    }
}
