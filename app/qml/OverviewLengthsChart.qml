import QtQuick
import Omarchy.TCPViewer
import "OverviewFormat.js" as Format

// Wireshark packet-length histogram (upstream CaptureOverviewPacketLengthCard):
// seven size buckets, a numeric count axis and a hover tooltip.
Item {
    id: root

    property var counts: []
    property int totalPackets: 0
    property int totalBytes: 0
    property int hoverIndex: -1

    readonly property real plotLeft: 8
    readonly property real plotRight: 6
    // Leave headroom for the count annotation above the tallest bar.
    readonly property real plotTop: 18
    readonly property real plotBottom: Math.max(plotTop + 1, height - 22)
    readonly property real plotWidth: Math.max(0, width - plotLeft - plotRight)
    readonly property real plotHeight: Math.max(0, plotBottom - plotTop)
    readonly property real maximum: {
        var maximum = 0
        for (var i = 0; i < counts.length; i++)
            maximum = Math.max(maximum, Number(counts[i]) || 0)
        return maximum
    }

    function rgba(color, alpha) {
        return "rgba(" + Math.round(color.r * 255) + ","
                + Math.round(color.g * 255) + ","
                + Math.round(color.b * 255) + "," + alpha + ")"
    }

    function slotWidth() {
        return counts.length > 0 ? plotWidth / counts.length : plotWidth
    }

    function slotCenter(index) {
        return plotLeft + (index + 0.5) * slotWidth()
    }

    Canvas {
        id: canvas

        anchors.fill: parent

        onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            if (counts.length === 0 || plotWidth <= 0 || plotHeight <= 0)
                return

            ctx.font = "9px " + Theme.canvasFont
            ctx.textBaseline = "middle"

            var slot = slotWidth()
            var barWidth = Math.max(8, Math.min(28, slot * 0.6))
            // Keep room above the tallest bar for its count annotation.
            var usableHeight = Math.max(1, plotHeight - 14)
            for (var i = 0; i < counts.length; i++) {
                var count = Number(counts[i]) || 0
                var barHeight = maximum > 0 ? (count / maximum) * usableHeight : 0
                var x = plotLeft + i * slot + (slot - barWidth) / 2
                var barTop = plotBottom - barHeight
                var dimmed = hoverIndex >= 0 && hoverIndex !== i
                ctx.fillStyle = root.rgba(Theme.systemPink,
                                          dimmed ? 0.3 : (hoverIndex === i ? 0.95 : 0.72))
                ctx.beginPath()
                ctx.moveTo(x, plotBottom)
                ctx.lineTo(x, barTop + 2)
                ctx.quadraticCurveTo(x, barTop, x + 2, barTop)
                ctx.lineTo(x + barWidth - 2, barTop)
                ctx.quadraticCurveTo(x + barWidth, barTop,
                                     x + barWidth, barTop + 2)
                ctx.lineTo(x + barWidth, plotBottom)
                ctx.closePath()
                ctx.fill()

                if (count > 0) {
                    ctx.fillStyle = hoverIndex === i
                        ? Theme.label : Theme.secondaryLabel
                    ctx.font = "9px " + Theme.canvasFont
                    ctx.textAlign = "center"
                    ctx.textBaseline = "alphabetic"
                    ctx.fillText(Format.count(count),
                                 x + barWidth / 2, barTop - 4)
                }

                ctx.fillStyle = Theme.secondaryLabel
                ctx.font = "9px " + Theme.canvasFont
                ctx.textAlign = "center"
                ctx.textBaseline = "alphabetic"
                ctx.fillText(Format.lengthBucketLabel(i),
                             root.slotCenter(i), root.height - 4)
            }

            ctx.strokeStyle = Theme.separator
            ctx.lineWidth = 1
            ctx.beginPath()
            ctx.moveTo(plotLeft, plotBottom + 0.5)
            ctx.lineTo(width - plotRight, plotBottom + 0.5)
            ctx.stroke()
        }
    }

    MouseArea {
        id: hoverArea

        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        onPositionChanged: (mouse) => {
            if (counts.length === 0 || mouse.x < plotLeft
                    || mouse.x > width - plotRight) {
                hoverIndex = -1
                return
            }
            var index = Math.floor((mouse.x - plotLeft) / slotWidth())
            hoverIndex = Math.max(0, Math.min(counts.length - 1, index))
        }
        onExited: hoverIndex = -1
    }

    Rectangle {
        visible: hoverIndex >= 0 && hoverIndex < counts.length
        z: 5
        width: 178
        height: tooltipColumn.implicitHeight + 14
        radius: 8
        color: Theme.headerBackground
        border.color: Theme.separator
        x: hoverIndex >= 0 && hoverIndex < counts.length
            ? Math.max(0, Math.min(root.width - width, root.slotCenter(hoverIndex) - width / 2))
            : 0
        y: 2

        Column {
            id: tooltipColumn

            x: 8
            y: 7
            width: parent.width - 16
            spacing: 4

            Text {
                width: parent.width
                text: root.hoverIndex >= 0 && root.hoverIndex < root.counts.length
                    ? Format.lengthBucketTitle(root.hoverIndex) : ""
                font.family: Theme.uiFont
                font.pixelSize: 10
                font.weight: Font.DemiBold
                color: Theme.label
            }
            Text {
                width: parent.width
                text: root.hoverIndex >= 0 && root.hoverIndex < root.counts.length
                    ? Format.count(root.counts[root.hoverIndex]) + " packets · "
                      + Format.percent(root.counts[root.hoverIndex], root.totalPackets)
                    : ""
                font.family: Theme.monoFont
                font.pixelSize: 10
                color: Theme.secondaryLabel
            }
        }
    }

    onCountsChanged: canvas.requestPaint()
    onHoverIndexChanged: canvas.requestPaint()
    onWidthChanged: canvas.requestPaint()
    onHeightChanged: canvas.requestPaint()
    Component.onCompleted: canvas.requestPaint()
}
