import QtQuick
import QtQuick.Controls
import Omarchy.TCPViewer

// One Overview chart card (upstream CaptureOverviewCardView): a tinted icon,
// a one-line title/subtitle header, a hover remove affordance and a content
// slot. The content child fills the slot, which is inset 16px like upstream.
Rectangle {
    id: card

    property string title
    property string subtitle
    property string glyph: "•"
    property color tint: Theme.accent

    // Empty-state body (upstream CaptureOverviewCardView placeholder): when
    // emptyMessage is non-empty the content slot is replaced by a centered
    // tinted glyph, message and optional detail line.
    property string emptyMessage: ""
    property string emptyDetail: ""

    signal removeRequested()

    default property alias contentData: contentHost.data

    implicitWidth: 360
    implicitHeight: 340
    radius: 18
    color: Theme.contentBackground
    border.width: 1
    border.color: cardHover.hovered ? Qt.rgba(tint.r, tint.g, tint.b, 0.45)
                                     : Theme.separator
    clip: false

    HoverHandler {
        id: cardHover
    }

    // Header: tinted 24px icon tile, title, one-line subtitle.
    Item {
        id: header

        x: 16
        y: 14
        width: card.width - 32
        height: 28

        Rectangle {
            id: iconTile

            width: 24
            height: 24
            radius: 7
            color: card.tint
            anchors.verticalCenter: parent.verticalCenter

            Text {
                anchors.centerIn: parent
                text: card.glyph
                color: "#ffffff"
                font.family: Theme.uiFont
                font.pixelSize: 13
                font.weight: Font.DemiBold
            }
        }

        Column {
            anchors.left: iconTile.right
            anchors.leftMargin: 8
            anchors.right: removeButton.left
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0

            Text {
                width: parent.width
                elide: Text.ElideRight
                text: card.title
                font.family: Theme.uiFont
                font.pixelSize: 13
                font.weight: Font.DemiBold
                color: Theme.label
            }
            Text {
                width: parent.width
                elide: Text.ElideRight
                text: card.subtitle
                font.family: Theme.uiFont
                font.pixelSize: 11
                color: Theme.secondaryLabel
            }
        }

        ToolButton {
            id: removeButton

            width: 20
            height: 20
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            flat: true
            opacity: cardHover.hovered ? 1 : 0
            text: "×"
            font.family: Theme.uiFont
            font.pixelSize: 14
            ToolTip.visible: hovered
            ToolTip.text: "Remove from Overview"
            ToolTip.delay: 400

            onClicked: card.removeRequested()
        }
    }

    // Content slot. Children declared inside an OverviewCard are parented here
    // and can use anchors.fill: parent. Hidden while the empty state shows.
    Item {
        id: contentHost

        x: 16
        y: 54
        width: card.width - 32
        height: card.height - 70
        clip: true
        visible: card.emptyMessage.length === 0
    }

    // Empty-state body: centered tinted glyph tile, message and detail line.
    Column {
        anchors.centerIn: contentHost
        spacing: 8
        visible: card.emptyMessage.length > 0

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 40
            height: 40
            radius: 12
            color: Qt.rgba(card.tint.r, card.tint.g, card.tint.b, 0.14)

            Text {
                anchors.centerIn: parent
                text: card.glyph
                font.family: Theme.uiFont
                font.pixelSize: 16
                color: card.tint
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: contentHost.width - 16
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: card.emptyMessage
            font.family: Theme.uiFont
            font.pixelSize: Theme.uiSmall
            font.weight: Font.DemiBold
            color: Theme.secondaryLabel
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: contentHost.width - 16
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            visible: card.emptyDetail.length > 0
            text: card.emptyDetail
            font.family: Theme.uiFont
            font.pixelSize: 11
            color: Theme.secondaryLabel
            opacity: 0.8
        }
    }

    TapHandler {
        acceptedButtons: Qt.RightButton
        onTapped: removeMenu.popup()
    }

    Menu {
        id: removeMenu

        MenuItem {
            text: "Remove from Overview"
            onTriggered: card.removeRequested()
        }
    }
}
