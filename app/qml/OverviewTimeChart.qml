import QtQuick
import Omarchy.TCPViewer
import "OverviewFormat.js" as Format

// Time-series plot shared by the Packets and Throughput cards. Packets are
// stacked 1-second bars (normal + TCP issues); throughput is an area/line
// chart (sent/received when the capture has direction metadata, otherwise a
// single total series). Axes, gridlines, peak values and hover details match
// upstream CaptureOverviewChartCards' Swift Charts presentation.
Item {
    id: root

    property var points: []
    property real intervalMs: 1000
    property string mode: "packets" // "packets" | "throughput"
    property bool interactive: true

    // Plot geometry. axisWidth leaves room for byte/s labels; bottomAxis for
    // four clock labels.
    readonly property real axisWidth: mode === "throughput" ? 54 : 40
    readonly property real plotLeft: axisWidth
    readonly property real plotRight: 6
    readonly property real plotTop: 6
    readonly property real plotBottom: Math.max(plotTop + 1, height - 18)
    readonly property real plotWidth: Math.max(0, width - plotLeft - plotRight)
    readonly property real plotHeight: Math.max(0, plotBottom - plotTop)
    readonly property real intervalSeconds: Math.max(0.001, intervalMs / 1000)

    readonly property var slots: {
        var result = []
        var list = points ? points : []
        for (var i = 0; i < list.length; i++) {
            var point = list[i] ? list[i] : {}
            var totals = point.totals ? point.totals : {}
            var packets = Number(totals.packets) || 0
            var issues = Math.min(packets, Number(totals.issue_packets) || 0)
            var bytes = Number(totals.bytes) || 0
            var sent = Number(totals.sent_bytes) || 0
            var received = Number(totals.received_bytes) || 0
            var unknown = Number(totals.unclassified_bytes) || 0
            if (sent + received + unknown <= 0)
                unknown = bytes
            result.push({
                date_ms: Number(point.date_ms) || 0,
                packets: packets,
                issues: issues,
                bytes: bytes,
                sent: sent,
                received: received,
                unknown: unknown
            })
        }
        return result
    }

    readonly property bool directional: {
        for (var i = 0; i < slots.length; i++) {
            if (slots[i].sent > 0 || slots[i].received > 0)
                return true
        }
        return false
    }

    readonly property real maxValue: {
        var maximum = 0
        for (var i = 0; i < slots.length; i++) {
            var slot = slots[i]
            if (mode === "throughput") {
                if (directional) {
                    maximum = Math.max(maximum, slot.sent / intervalSeconds,
                                       slot.received / intervalSeconds)
                } else {
                    maximum = Math.max(maximum, slot.bytes / intervalSeconds)
                }
            } else {
                maximum = Math.max(maximum, slot.packets / intervalSeconds)
            }
        }
        return maximum
    }

    readonly property real stepValue: niceStep(maxValue, 4, mode !== "throughput")
    readonly property real axisMax: stepValue * 4

    property int hoverIndex: -1

    function niceStep(maximum, ticks, integerOnly) {
        if (!(maximum > 0))
            return 1
        var rough = maximum / Math.max(1, ticks)
        var power = Math.pow(10, Math.floor(Math.log(rough) / Math.LN10))
        var fraction = rough / power
        if (integerOnly)
            return Math.max(1, Math.ceil(maximum / Math.max(1, ticks)))
        var nice = fraction <= 1 ? 1 : fraction <= 2 ? 2
                 : fraction <= 2.5 ? 2.5 : fraction <= 5 ? 5 : 10
        return nice * power
    }

    function rgba(color, alpha) {
        return "rgba(" + Math.round(color.r * 255) + ","
                + Math.round(color.g * 255) + ","
                + Math.round(color.b * 255) + "," + alpha + ")"
    }

    function tickLabel(value) {
        return mode === "throughput" ? Format.rate(value) : Format.count(value)
    }

    function slotWidth() {
        return slots.length > 0 ? plotWidth / slots.length : plotWidth
    }

    function slotCenter(index) {
        return plotLeft + (index + 0.5) * slotWidth()
    }

    function hoverRows() {
        if (hoverIndex < 0 || hoverIndex >= slots.length)
            return []
        var slot = slots[hoverIndex]
        if (mode === "throughput") {
            if (directional) {
                return [
                    { color: receivedColor, label: "Received", value: Format.rate(slot.received / intervalSeconds) },
                    { color: sentColor, label: "Sent", value: Format.rate(slot.sent / intervalSeconds) },
                    { color: Theme.secondaryLabel, label: "Bytes", value: Format.bytes(slot.bytes) }
                ]
            }
            return [
                { color: packetsColor, label: "Throughput", value: Format.rate(slot.bytes / intervalSeconds) },
                { color: Theme.secondaryLabel, label: "Bytes", value: Format.bytes(slot.bytes) }
            ]
        }
        return [
            { color: packetsColor, label: "Packets", value: Format.count(slot.packets) },
            { color: issueColor, label: "TCP issues", value: Format.count(slot.issues) },
            { color: Theme.secondaryLabel, label: "Bytes", value: Format.bytes(slot.bytes) }
        ]
    }

    // Colors are properties so the Canvas repaints when the theme changes.
    readonly property color packetsColor: Theme.systemBlue
    readonly property color issueColor: Theme.systemRed
    readonly property color sentColor: Theme.systemPurple
    readonly property color receivedColor: Theme.systemCyan
    readonly property color unknownColor: Theme.systemGray

    function roundedTopRect(ctx, x, y, w, h, radius) {
        var r = Math.max(0, Math.min(radius, w / 2, h))
        ctx.beginPath()
        ctx.moveTo(x, y + h)
        ctx.lineTo(x, y + r)
        ctx.quadraticCurveTo(x, y, x + r, y)
        ctx.lineTo(x + w - r, y)
        ctx.quadraticCurveTo(x + w, y, x + w, y + r)
        ctx.lineTo(x + w, y + h)
        ctx.closePath()
        ctx.fill()
    }

    function drawSeries(ctx, color, values) {
        if (values.length === 0)
            return
        var firstX = slotCenter(0)
        var lastX = slotCenter(values.length - 1)
        var gradient = ctx.createLinearGradient(0, plotTop, 0, plotBottom)
        gradient.addColorStop(0, rgba(color, 0.28))
        gradient.addColorStop(1, rgba(color, 0.02))

        ctx.beginPath()
        ctx.moveTo(firstX, plotBottom)
        for (var i = 0; i < values.length; i++)
            ctx.lineTo(slotCenter(i), plotBottom - (values[i] / axisMax) * plotHeight)
        ctx.lineTo(lastX, plotBottom)
        ctx.closePath()
        ctx.fillStyle = gradient
        ctx.fill()

        ctx.beginPath()
        for (var j = 0; j < values.length; j++) {
            var x = slotCenter(j)
            var y = plotBottom - (values[j] / axisMax) * plotHeight
            if (j === 0)
                ctx.moveTo(x, y)
            else
                ctx.lineTo(x, y)
        }
        ctx.strokeStyle = color
        ctx.lineWidth = 1.8
        ctx.lineJoin = "round"
        ctx.lineCap = "round"
        ctx.stroke()
    }

    Canvas {
        id: canvas

        anchors.fill: parent

        onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            if (root.plotWidth <= 0 || root.plotHeight <= 0)
                return
            if (root.slots.length === 0) {
                ctx.fillStyle = Theme.secondaryLabel
                ctx.font = "11px " + Theme.canvasFont
                ctx.textAlign = "left"
                ctx.textBaseline = "alphabetic"
                ctx.fillText("No packets", 2, 16)
                return
            }

            // Horizontal grid and value labels.
            ctx.font = "9px " + Theme.canvasFont
            ctx.textBaseline = "middle"
            for (var tick = 0; tick <= 4; tick++) {
                var y = root.plotBottom - root.plotHeight * (tick / 4)
                ctx.strokeStyle = tick === 0 ? Theme.separator : root.rgba(Theme.label, 0.07)
                ctx.lineWidth = 1
                ctx.setLineDash(tick === 0 ? [] : [2, 3])
                ctx.beginPath()
                ctx.moveTo(root.plotLeft, y + 0.5)
                ctx.lineTo(root.width - root.plotRight, y + 0.5)
                ctx.stroke()
                ctx.setLineDash([])
                ctx.fillStyle = Theme.secondaryLabel
                ctx.textAlign = "right"
                ctx.fillText(root.tickLabel(root.axisMax * tick / 4),
                             root.plotLeft - 6, y)
            }

            // Hovered slot background.
            if (root.hoverIndex >= 0 && root.hoverIndex < root.slots.length) {
                ctx.fillStyle = root.rgba(Theme.label, 0.05)
                ctx.fillRect(root.plotLeft + root.hoverIndex * root.slotWidth(),
                             root.plotTop, root.slotWidth(), root.plotHeight)
            }

            if (root.mode === "throughput") {
                var receivedValues = []
                var sentValues = []
                var totalValues = []
                for (var i = 0; i < root.slots.length; i++) {
                    receivedValues.push(root.slots[i].received / root.intervalSeconds)
                    sentValues.push(root.slots[i].sent / root.intervalSeconds)
                    totalValues.push(root.slots[i].bytes / root.intervalSeconds)
                }
                if (root.directional) {
                    root.drawSeries(ctx, root.receivedColor, receivedValues)
                    root.drawSeries(ctx, root.sentColor, sentValues)
                } else {
                    root.drawSeries(ctx, root.packetsColor, totalValues)
                }

                if (root.hoverIndex >= 0 && root.hoverIndex < root.slots.length) {
                    var hoverX = root.slotCenter(root.hoverIndex)
                    var hoverValues = root.directional
                        ? [root.slots[root.hoverIndex].received / root.intervalSeconds,
                           root.slots[root.hoverIndex].sent / root.intervalSeconds]
                        : [root.slots[root.hoverIndex].bytes / root.intervalSeconds]
                    var hoverColors = root.directional
                        ? [root.receivedColor, root.sentColor]
                        : [root.packetsColor]
                    for (var d = 0; d < hoverValues.length; d++) {
                        var dotY = root.plotBottom - (hoverValues[d] / root.axisMax) * root.plotHeight
                        ctx.beginPath()
                        ctx.arc(hoverX, dotY, 3.2, 0, Math.PI * 2)
                        ctx.fillStyle = hoverColors[d]
                        ctx.fill()
                        ctx.strokeStyle = Theme.contentBackground
                        ctx.lineWidth = 1.5
                        ctx.stroke()
                    }
                    ctx.strokeStyle = root.rgba(Theme.secondaryLabel, 0.35)
                    ctx.lineWidth = 1
                    ctx.setLineDash([2, 3])
                    ctx.beginPath()
                    ctx.moveTo(hoverX, root.plotTop)
                    ctx.lineTo(hoverX, root.plotBottom)
                    ctx.stroke()
                    ctx.setLineDash([])
                }
            } else {
                var slotW = root.slotWidth()
                var barW = Math.max(2, Math.min(16, slotW * 0.62))
                for (var b = 0; b < root.slots.length; b++) {
                    var slot = root.slots[b]
                    var totalHeight = (slot.packets / root.intervalSeconds
                                       / root.axisMax) * root.plotHeight
                    var issueHeight = (slot.issues / root.intervalSeconds
                                       / root.axisMax) * root.plotHeight
                    var normalHeight = Math.max(0, totalHeight - issueHeight)
                    var x = root.plotLeft + b * slotW + (slotW - barW) / 2
                    if (normalHeight > 0) {
                        ctx.fillStyle = root.packetsColor
                        root.roundedTopRect(ctx, x, root.plotBottom - normalHeight,
                                            barW, normalHeight, issueHeight > 0 ? 0 : 2)
                    }
                    if (issueHeight > 0) {
                        ctx.fillStyle = root.issueColor
                        root.roundedTopRect(ctx, x, root.plotBottom - totalHeight,
                                            barW, issueHeight, 2)
                    }
                }
                if (root.hoverIndex >= 0 && root.hoverIndex < root.slots.length) {
                    var hoverX2 = root.slotCenter(root.hoverIndex)
                    var hoverSlot = root.slots[root.hoverIndex]
                    var hoverTotal = (hoverSlot.packets / root.intervalSeconds
                                      / root.axisMax) * root.plotHeight
                    if (hoverTotal > 0) {
                        ctx.fillStyle = root.rgba(Theme.label, 0.28)
                        ctx.fillRect(hoverX2 - 1, root.plotBottom - hoverTotal, 2, hoverTotal)
                    }
                }
            }

            // Time labels: first, thirds, last; the edge labels are aligned
            // inward so they cannot be clipped by the card content column.
            var indices = [0]
            if (root.slots.length > 1) {
                indices.push(Math.floor((root.slots.length - 1) / 3))
                indices.push(Math.floor(2 * (root.slots.length - 1) / 3))
                indices.push(root.slots.length - 1)
            }
            var unique = []
            for (var n = 0; n < indices.length; n++) {
                if (unique.indexOf(indices[n]) < 0)
                    unique.push(indices[n])
            }
            ctx.font = "9px " + Theme.canvasFont
            ctx.textBaseline = "alphabetic"
            for (var k = 0; k < unique.length; k++) {
                var index = unique[k]
                var labelX = root.slotCenter(index)
                ctx.fillStyle = Theme.secondaryLabel
                ctx.textAlign = index === 0 ? "left"
                    : index === root.slots.length - 1 ? "right" : "center"
                ctx.fillText(Format.clockTime(root.slots[index].date_ms),
                             labelX, root.height - 3)
            }
        }
    }

    MouseArea {
        id: hoverArea

        anchors.fill: parent
        hoverEnabled: root.interactive
        acceptedButtons: Qt.NoButton
        onPositionChanged: (mouse) => {
            if (!root.interactive || root.slots.length === 0) {
                root.hoverIndex = -1
                return
            }
            if (mouse.x < root.plotLeft || mouse.x > root.width - root.plotRight) {
                root.hoverIndex = -1
                return
            }
            var index = Math.floor((mouse.x - root.plotLeft) / root.slotWidth())
            root.hoverIndex = Math.max(0, Math.min(root.slots.length - 1, index))
        }
        onExited: root.hoverIndex = -1
    }

    // Hover tooltip, placed above the plot like upstream's chart tooltip.
    Rectangle {
        id: tooltip

        visible: root.interactive && root.hoverIndex >= 0 && root.slots.length > 0
        z: 5
        width: 178
        height: tooltipColumn.implicitHeight + 14
        radius: 8
        color: Theme.headerBackground
        border.color: Theme.separator
        x: root.hoverIndex >= 0 && root.slots.length > 0
            ? Math.max(0, Math.min(root.width - width,
                                   root.slotCenter(root.hoverIndex) - width / 2))
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
                text: root.hoverIndex >= 0 && root.hoverIndex < root.slots.length
                    ? Format.clockTime(root.slots[root.hoverIndex].date_ms) : ""
                font.family: Theme.uiFont
                font.pixelSize: 10
                font.weight: Font.DemiBold
                color: Theme.label
            }

            Repeater {
                model: root.hoverRows()

                delegate: Row {
                    required property var modelData

                    width: tooltipColumn.width
                    height: 14

                    Rectangle {
                        width: 7
                        height: 7
                        radius: 3.5
                        anchors.verticalCenter: parent.verticalCenter
                        color: modelData.color
                    }
                    Text {
                        x: 12
                        width: parent.width - 12 - valueText.width
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        text: modelData.label
                        font.family: Theme.uiFont
                        font.pixelSize: 10
                        color: Theme.secondaryLabel
                    }
                    Text {
                        id: valueText

                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.value
                        font.family: Theme.monoFont
                        font.pixelSize: 10
                        color: Theme.label
                    }
                }
            }
        }
    }

    onSlotsChanged: canvas.requestPaint()
    onModeChanged: canvas.requestPaint()
    onHoverIndexChanged: canvas.requestPaint()
    onDirectionalChanged: canvas.requestPaint()
    onAxisMaxChanged: canvas.requestPaint()
    onWidthChanged: canvas.requestPaint()
    onHeightChanged: canvas.requestPaint()
    onPacketsColorChanged: canvas.requestPaint()
    onIssueColorChanged: canvas.requestPaint()
    onSentColorChanged: canvas.requestPaint()
    onReceivedColorChanged: canvas.requestPaint()
    Component.onCompleted: canvas.requestPaint()
}
