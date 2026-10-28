import QtQuick
import QtQuick.Controls
import Omarchy.TCPViewer
import "OverviewFormat.js" as Format

// Protocol share donut (upstream CaptureOverviewProtocolsCard): a 62% inner
// radius ring with a small angular gap, hover dimming and a centered count.
Item {
    id: root

    // Each row: { title, bytes, fraction, color }
    property var rows: []
    property int hoveredIndex: -1

    readonly property int sliceCount: rows ? rows.length : 0
    readonly property real innerRatio: 0.62

    function rgba(color, alpha) {
        return "rgba(" + Math.round(color.r * 255) + ","
                + Math.round(color.g * 255) + ","
                + Math.round(color.b * 255) + "," + alpha + ")"
    }

    function indexAt(px, py) {
        if (sliceCount === 0)
            return -1
        var cx = width / 2
        var cy = height / 2
        var radius = Math.min(width, height) / 2
        var dx = px - cx
        var dy = py - cy
        var distance = Math.sqrt(dx * dx + dy * dy)
        if (distance < radius * innerRatio || distance > radius)
            return -1
        var angle = Math.atan2(dx, -dy)
        if (angle < 0)
            angle += Math.PI * 2
        var target = angle / (Math.PI * 2)
        var accumulated = 0
        for (var i = 0; i < rows.length; i++) {
            accumulated += Math.max(0, Number(rows[i].fraction) || 0)
            if (target <= accumulated)
                return i
        }
        return rows.length - 1
    }

    Canvas {
        id: canvas

        anchors.fill: parent

        onPaint: {
            var ctx = getContext("2d")
            var w = width
            var h = height
            ctx.clearRect(0, 0, w, h)
            if (root.sliceCount === 0) {
                ctx.fillStyle = Theme.secondaryLabel
                ctx.font = "11px " + Theme.canvasFont
                ctx.textAlign = "center"
                ctx.fillText("No packets", w / 2, h / 2)
                return
            }
            var cx = w / 2
            var cy = h / 2
            var outer = Math.min(w, h) / 2 - 1
            var inner = outer * root.innerRatio
            var start = -Math.PI / 2
            var gap = 0.022 // ~1.3 degrees, like Swift Charts' angularInset.
            for (var i = 0; i < root.rows.length; i++) {
                var row = root.rows[i]
                var fraction = Math.max(0, Number(row.fraction) || 0)
                if (fraction <= 0)
                    continue
                var end = start + fraction * Math.PI * 2
                var a0 = start + gap / 2
                var a1 = end - gap / 2
                if (a1 <= a0) {
                    a0 = start
                    a1 = end
                }
                ctx.beginPath()
                ctx.arc(cx, cy, outer, a0, a1, false)
                ctx.arc(cx, cy, inner, a1, a0, true)
                ctx.closePath()
                ctx.fillStyle = row.color ? row.color : Theme.chartColor(i)
                var dimmed = root.hoveredIndex >= 0 && root.hoveredIndex !== i
                ctx.globalAlpha = dimmed ? 0.38 : 1
                ctx.fill()
                ctx.globalAlpha = 1
                start = end
            }
            ctx.beginPath()
            ctx.arc(cx, cy, inner - 1, 0, Math.PI * 2)
            ctx.strokeStyle = Theme.contentBackground
            ctx.lineWidth = 1
            ctx.stroke()
        }
    }

    MouseArea {
        id: hoverArea

        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        onPositionChanged: (mouse) => {
            root.hoveredIndex = root.indexAt(mouse.x, mouse.y)
        }
        onExited: root.hoveredIndex = -1
    }

    Column {
        anchors.centerIn: parent
        spacing: 0
        visible: root.sliceCount > 0

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.sliceCount
            font.family: Theme.uiFont
            font.pixelSize: 16
            font.weight: Font.DemiBold
            color: Theme.label
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.sliceCount === 1 ? "protocol" : "protocols"
            font.family: Theme.uiFont
            font.pixelSize: 10
            color: Theme.secondaryLabel
        }
    }

    ToolTip {
        visible: hoverArea.containsMouse && root.hoveredIndex >= 0
                && root.hoveredIndex < root.rows.length
        delay: 300
        text: {
            if (root.hoveredIndex < 0 || root.hoveredIndex >= root.rows.length)
                return ""
            var row = root.rows[root.hoveredIndex]
            return row.title + " · " + Format.percent(row.bytes, root.totalBytes())
                  + "\n" + Format.bytes(row.bytes) + " of " + Format.bytes(root.totalBytes())
        }
    }

    function totalBytes() {
        var total = 0
        for (var i = 0; i < rows.length; i++)
            total += Number(rows[i].bytes) || 0
        return total
    }

    onRowsChanged: canvas.requestPaint()
    onHoveredIndexChanged: canvas.requestPaint()
    onWidthChanged: canvas.requestPaint()
    onHeightChanged: canvas.requestPaint()
    Component.onCompleted: canvas.requestPaint()
}
