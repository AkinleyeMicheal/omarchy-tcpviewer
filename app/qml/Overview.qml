import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Omarchy.TCPViewer
import "OverviewFormat.js" as Format

// Overview page: the aggregate dashboard the owner sees first. Ported from
// upstream CaptureOverviewViewController/CaptureOverviewDashboardView: a row
// of metric tiles plus an adaptive grid of chart cards (upstream default set:
// Packets, Throughput, Protocols, Top Apps, Top Domains & IPs, TCP Analysis;
// Conversations/Services/Packet Lengths wait in the "+" picker). Data comes
// from capture.overview; the daemon caches per revision and this page polls
// at 2 s while visible.
Rectangle {
    id: overviewPage

    required property SessionController session

    color: Theme.windowBackground

    readonly property var overview: session ? session.overview : ({})

    // Upstream card pool; the defaults match CaptureOverviewCard.defaults.
    readonly property var allCards: [
        "packets", "throughput", "protocols", "topApps", "topDestinations",
        "tcpAnalysis", "conversations", "services", "packetLengths",
    ]
    readonly property var defaultCards: [
        "packets", "throughput", "protocols", "topApps", "topDestinations", "tcpAnalysis",
    ]
    property var cards: {
        // Stored picker order; unknown or duplicate entries are skipped later.
        var stored = session ? session.overviewCards() : []
        return stored.length > 0 ? stored.slice() : defaultCards.slice()
    }
    onCardsChanged: if (session) session.setOverviewCards(cards)
    readonly property var visibleCards: {
        var out = []
        for (var i = 0; i < cards.length; i++) {
            var name = String(cards[i])
            if (allCards.indexOf(name) >= 0 && out.indexOf(name) < 0)
                out.push(name)
        }
        return out
    }
    readonly property var hiddenCards: {
        var hidden = []
        for (var i = 0; i < allCards.length; i++) {
            if (visibleCards.indexOf(allCards[i]) < 0)
                hidden.push(allCards[i])
        }
        return hidden
    }
    readonly property bool hasData: {
        var totals = overview.totals ? overview.totals : {}
        return (Number(totals.packets) || 0) > 0
    }

    // Same-size cards, as many per row as fit (upstream's adaptive grid).
    readonly property real cardOuterWidth: 340
    readonly property real cardSpacing: 14
    readonly property int cardColumns: Math.max(1, Math.floor((width + cardSpacing) / (cardOuterWidth + cardSpacing)))
    readonly property real cardWidth: (width - (cardColumns - 1) * cardSpacing) / cardColumns
    readonly property real cardHeight: 300

    function addCard(kind) {
        var next = visibleCards.slice()
        if (next.indexOf(kind) < 0) {
            next.push(kind)
            cards = next
        }
    }

    function removeCard(kind) {
        var next = visibleCards.slice()
        var index = next.indexOf(kind)
        if (index >= 0) {
            next.splice(index, 1)
            cards = next
        }
    }

    function cardTitle(kind) {
        switch (String(kind)) {
        case "packets": return "Packets"
        case "throughput": return "Throughput"
        case "protocols": return "Protocols"
        case "topApps": return "Top Apps"
        case "topDestinations": return "Top Domains & IPs"
        case "tcpAnalysis": return "TCP Analysis"
        case "conversations": return "Top Conversations"
        case "services": return "Services & Ports"
        case "packetLengths": return "Packet Lengths"
        }
        return String(kind)
    }

    Component.onCompleted: session.requestOverview()

    // Pull new aggregates while the page is visible; the daemon answers the
    // repeat requests from its revision cache.
    Timer {
        interval: 2000
        running: overviewPage.visible && overviewPage.session.connected
        repeat: true
        triggeredOnStart: false
        onTriggered: overviewPage.session.requestOverview()
    }

    Flickable {
        id: scroller

        anchors.fill: parent
        contentWidth: width
        contentHeight: column.height + 24
        clip: true
        ScrollBar.vertical: ScrollBar {}

        Column {
            id: column

            x: 16
            y: 14
            width: overviewPage.width - 32
            spacing: 14

            // Header: page title + the source this snapshot describes.
            RowLayout {
                width: parent.width
                spacing: 10

                Text {
                    text: "Overview"
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiTitle
                    font.weight: Font.DemiBold
                    color: Theme.label
                }
                Text {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSmall
                    color: Theme.secondaryLabel
                    text: {
                        var status = overviewPage.session.status
                        var raw = status.path || status.display_name || status.interface || ""
                        if (raw.length === 0)
                            return ""
                        // Only the file's basename in chrome; full paths and
                        // live capture wording stay out of the page header.
                        var name = String(raw).split("/").pop()
                        return status.kind === "offline" ? name : "Live on " + name
                    }
                }
            }

            OverviewMetrics {
                width: parent.width
                overview: overviewPage.overview
                visible: overviewPage.hasData
            }

            // Card grid ------------------------------------------------------
            Flow {
                id: cardGrid
                width: parent.width
                spacing: overviewPage.cardSpacing
                visible: overviewPage.hasData

                Repeater {
                    model: overviewPage.visibleCards

                    delegate: OverviewCard {
                        title: overviewPage.cardTitle(modelData)
                        width: overviewPage.cardWidth
                        height: overviewPage.cardHeight
                        onRemoveRequested: overviewPage.removeCard(kind)
                    }
                }
            }

            // "+" picker row: hidden cards return here (upstream picker).
            Row {
                spacing: 10
                visible: overviewPage.hasData && overviewPage.hiddenCards.length > 0

                Button {
                    id: addCardButton
                    flat: true
                    implicitWidth: 34
                    implicitHeight: 28
                    text: "+"

                    onClicked: addCardMenu.popup(addCardButton.x + 8, addCardButton.y + addCardButton.height + 4)
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Add a card"
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSmall
                    color: Theme.secondaryLabel
                }
            }

            Menu {
                id: addCardMenu

                Repeater {
                    model: overviewPage.hiddenCards

                    delegate: MenuItem {
                        required property var modelData

                        text: overviewPage.cardTitle(modelData)
                        onTriggered: overviewPage.addCard(modelData)
                    }
                }
            }

            // Empty capture message ------------------------------------------
            Column {
                width: parent.width
                spacing: 6
                visible: !overviewPage.hasData && !overviewPage.session.loading

                Text {
                    text: "No packets yet"
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSize
                    font.weight: Font.DemiBold
                    color: Theme.label
                }
                Text {
                    text: "Start a capture or open a capture file to populate the Overview."
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSmall
                    color: Theme.secondaryLabel
                }
            }
        }
    }

    // ---------------------------------------------------------------------
    // Inline components (self-contained: they only read overviewPage ids and
    // their own properties).
    // ---------------------------------------------------------------------

    // The five summary tiles, computed like upstream metricPresentations().
    component OverviewMetrics: Flow {
        id: metrics

        required property var overview

        spacing: 12

        Repeater {
            model: {
                var totals = metrics.overview.totals ? metrics.overview.totals : {}
                var packets = Number(totals.packets) || 0
                var firstMs = Number(metrics.overview.first_packet_ms) || 0
                var lastMs = Number(metrics.overview.last_packet_ms) || 0
                var duration = Math.max(0, lastMs - firstMs)
                var spanSeconds = Math.max(0, duration / 1000)
                var pps = spanSeconds >= 1 ? packets / spanSeconds : 0
                var ppsDetail = spanSeconds < 1
                    ? "In " + Format.span(duration)
                    : (pps >= 1 ? Format.count(pps) + " packets/s avg" : "Avg <1 packet/s")
                var bytes = Number(totals.bytes) || 0
                var sent = Number(totals.sent_bytes) || 0
                var received = Number(totals.received_bytes) || 0
                var trafficDetail = (sent > 0 || received > 0)
                    ? "\u2191 " + Format.bytes(sent) + "   \u2193 " + Format.bytes(received)
                    : "Original packet bytes"
                var tcp = Number(metrics.overview.tcp_packet_count) || 0
                var issues = Number(totals.issue_packets) || 0
                var issueDetail = issues > 0
                    ? Format.percent(issues, tcp) + " of TCP packets"
                    : "No flagged packets"
                var apps = Number(metrics.overview.app_count) || 0
                var domains = Number(metrics.overview.domain_count) || 0
                return [
                    { title: "Packets", value: Format.count(packets), detail: ppsDetail,
                      color: Theme.label },
                    { title: "Data Transferred", value: Format.bytes(bytes), detail: trafficDetail,
                      color: Theme.label },
                    { title: "Average Throughput",
                      value: Format.rate(spanSeconds > 0 ? bytes / spanSeconds : 0),
                      detail: Format.span(duration) + " captured", color: Theme.label },
                    { title: "TCP Issues", value: Format.count(issues), detail: issueDetail,
                      color: issues > 0 ? Theme.systemRed : Theme.systemGreen },
                    { title: "Apps", value: Format.count(apps),
                      detail: Format.count(domains) + (domains === 1 ? " domain" : " domains"),
                      color: Theme.label },
                ]
            }

            delegate: Rectangle {
                required property var modelData

                width: Math.max(170, (metrics.width - 4 * 12) / 5)
                height: 86
                radius: 10
                color: Theme.contentBackground
                border.color: Theme.separator

                Column {
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 3

                    Text {
                        text: modelData.title
                        font.family: Theme.uiFont
                        font.pixelSize: Theme.uiSmall
                        color: Theme.secondaryLabel
                    }
                    Text {
                        text: modelData.value
                        font.family: Theme.uiFont
                        font.pixelSize: 22
                        font.weight: Font.DemiBold
                        color: modelData.color
                    }
                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        text: modelData.detail
                        font.family: Theme.uiFont
                        font.pixelSize: Theme.uiSmall
                        color: Theme.secondaryLabel
                    }
                }
            }
        }
    }

    // Generic card chrome: title header with a remove button and content slot.
    component OverviewCard: Rectangle {
        id: card

        required property var modelData
        property string kind: modelData ? String(modelData) : ""
        property string title
        signal removeRequested()

        radius: 10
        color: Theme.contentBackground
        border.color: Theme.separator

        Item {
            id: header

            x: 14
            y: 8
            width: parent.width - 28
            height: 24

            Text {
                width: parent.width - removeButton.width
                elide: Text.ElideRight
                anchors.verticalCenter: parent.verticalCenter
                text: card.title
                font.family: Theme.uiFont
                font.pixelSize: Theme.uiSize
                font.weight: Font.DemiBold
                color: Theme.label
            }
            ToolButton {
                id: removeButton
                width: 20
                height: 20
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                flat: true
                hoverEnabled: true
                text: "\u00D7"
                ToolTip.visible: removeButton.hovered
                ToolTip.text: "Remove from Overview"
                ToolTip.delay: 400

                onClicked: card.removeRequested()
            }
        }

        // Content: one of the chart canvases or the row lists.
        Loader {
            id: content

            x: 14
            y: 34
            width: card.width - 28
            height: card.height - 48

            sourceComponent: {
                switch (card.kind) {
                case "packets": return packetsChart
                case "throughput": return rateChart
                case "packetLengths": return lengthsChart
                case "protocols":
                case "topApps":
                case "topDestinations":
                case "services": return shareRowsComponent
                case "conversations": return conversationsComponent
                case "tcpAnalysis": return issuesComponent
                }
                return emptyComponent
            }

            Component {
                id: emptyComponent

                Item { }
            }

            Component {
                id: packetsChart

                TimelineCanvas { anchors.fill: parent }
            }
            Component {
                id: rateChart

                RateCanvas { anchors.fill: parent }
            }
            Component {
                id: lengthsChart

                PacketLengthsCanvas { anchors.fill: parent }
            }
            Component {
                id: shareRowsComponent

                ShareRowsList { anchors.fill: parent; kind: card.kind }
            }
            Component {
                id: conversationsComponent

                ConversationRowsList { anchors.fill: parent }
            }
            Component {
                id: issuesComponent

                TcpAnalysisRowsList { anchors.fill: parent }
            }
        }
    }

    // ------------------------------------------------------------------
    // Charts (Canvas redraws on data or size change)
    // ------------------------------------------------------------------

    component TimelineCanvas: Canvas {
        id: timelineCanvas

        readonly property var points: {
            var overview = overviewPage.overview
            return overview.timeline ? overview.timeline : []
        }
        onPointsChanged: requestPaint()
        onWidthChanged: requestPaint()
        onPaint: {
            var ctx = getContext("2d")
            var w = width
            var h = height
            var labelSpace = 16
            var baseline = h - labelSpace - 2
            ctx.clearRect(0, 0, w, h)
            if (points.length === 0) {
                ctx.fillStyle = Theme.secondaryLabel
                ctx.font = "11px sans-serif"
                ctx.fillText("No packets", 4, 14)
                return
            }
            var maxPackets = 1
            var i
            for (i = 0; i < points.length; i++) {
                var totals = points[i].totals ? points[i].totals : {}
                maxPackets = Math.max(maxPackets, Number(totals.packets) || 0)
            }
            var slotWidth = w / points.length
            var barWidth = Math.max(2, slotWidth - 4)
            var scale = baseline / maxPackets
            for (i = 0; i < points.length; i++) {
                var columnTotals = points[i].totals ? points[i].totals : {}
                var packets = Number(columnTotals.packets) || 0
                var issues = Number(columnTotals.issue_packets) || 0
                if (packets <= 0)
                    continue
                var x = i * slotWidth + (slotWidth - barWidth) / 2
                var columnHeight = Math.max(1, packets * scale)
                ctx.fillStyle = "#5b8bd4"
                ctx.fillRect(x, baseline - columnHeight, barWidth, columnHeight)
                if (issues > 0) {
                    var issueHeight = issues / packets * columnHeight
                    ctx.fillStyle = Theme.systemRed
                    ctx.fillRect(x, baseline - columnHeight, barWidth, Math.min(columnHeight, issueHeight))
                }
            }
            ctx.strokeStyle = Theme.separator
            ctx.lineWidth = 1
            ctx.beginPath()
            ctx.moveTo(0, baseline + 0.5)
            ctx.lineTo(w, baseline + 0.5)
            ctx.stroke()
            // Sparse time labels: first, middle, last slot.
            ctx.fillStyle = Theme.secondaryLabel
            ctx.font = "10px sans-serif"
            if (points.length === 1) {
                ctx.fillText(Format.clockTime(points[0].date_ms), 2, baseline + 12)
            } else {
                ctx.fillText(Format.clockTime(points[0].date_ms), 2, baseline + 12)
                var middle = Math.floor((points.length - 1) / 2)
                var midText = Format.clockTime(points[middle].date_ms)
                ctx.fillText(midText, w / 2 - ctx.measureText(midText).width / 2, baseline + 12)
                var lastText = Format.clockTime(points[points.length - 1].date_ms)
                ctx.fillText(lastText, w - ctx.measureText(lastText).width - 2, baseline + 12)
            }
            var maxLabel = Format.count(maxPackets) + (maxPackets === 1 ? " packet/slot" : " packets/slot")
            ctx.font = "10px sans-serif"
            ctx.fillStyle = Theme.secondaryLabel
            ctx.fillText(maxLabel, 2, 10)
        }
    }

    component RateCanvas: Canvas {
        id: rateCanvas

        readonly property var points: {
            var overview = overviewPage.overview
            return overview.timeline ? overview.timeline : []
        }
        readonly property real intervalMs: Number(overviewPage.overview.timeline_interval_ms) || 1000
        // Received and sent when the capture knows the local side; otherwise
        // one total series (upstream CaptureOverviewThroughputSeries.series).
        readonly property bool hasDirections: {
            for (var i = 0; i < points.length; i++) {
                var totals = points[i].totals ? points[i].totals : {}
                if ((Number(totals.sent_bytes) || 0) > 0 || (Number(totals.received_bytes) || 0) > 0)
                    return true
            }
            return false
        }
        readonly property var series: hasDirections
            ? [
                { key: "sent_bytes", label: "Sent", color: Theme.systemGreen },
                { key: "received_bytes", label: "Received", color: Theme.systemBlue },
              ]
            : [
                { key: "bytes", label: "Total", color: Theme.systemOrange },
              ]
        // Peak label mirrors the upstream subtitle: the busiest slot's bytes
        // expressed per second.
        readonly property real peakRate: {
            var peak = 0
            for (var i = 0; i < points.length; i++) {
                var totals = points[i].totals ? points[i].totals : {}
                peak = Math.max(peak, Number(totals.bytes) || 0)
            }
            return peak / Math.max(1, intervalMs / 1000)
        }
        onPointsChanged: requestPaint()
        onWidthChanged: requestPaint()
        onPaint: {
            var ctx = getContext("2d")
            var w = width
            var h = height
            var labelSpace = 16
            var baseline = h - labelSpace - 2
            ctx.clearRect(0, 0, w, h)
            if (points.length < 2) {
                ctx.fillStyle = Theme.secondaryLabel
                ctx.font = "11px sans-serif"
                ctx.fillText("Not enough packets for a rate series", 4, 14)
                return
            }
            var maxSlotBytes = 1
            for (var m = 0; m < points.length; m++) {
                var peakTotals = points[m].totals ? points[m].totals : {}
                maxSlotBytes = Math.max(maxSlotBytes, Number(peakTotals.bytes) || 0)
            }
            var scale = baseline / maxSlotBytes
            var slotSeconds = Math.max(1, intervalMs / 1000)
            for (var s = 0; s < series.length; s++) {
                ctx.strokeStyle = String(series[s].color)
                ctx.lineWidth = 1.5
                ctx.beginPath()
                for (var i = 0; i < points.length; i++) {
                    var totals = points[i].totals ? points[i].totals : {}
                    var value = Number(totals[series[s].key]) || 0
                    var x = i * (w / (points.length - 1))
                    var y = baseline - (value / slotSeconds) * (scale * slotSeconds)
                    if (i === 0) {
                        ctx.moveTo(x, y)
                    } else {
                        ctx.lineTo(x, y)
                    }
                }
                ctx.stroke()
            }
            ctx.strokeStyle = Theme.separator
            ctx.lineWidth = 1
            ctx.beginPath()
            ctx.moveTo(0, baseline + 0.5)
            ctx.lineTo(w, baseline + 0.5)
            ctx.stroke()
            ctx.fillStyle = Theme.secondaryLabel
            ctx.font = "10px sans-serif"
            ctx.fillText(Format.clockTime(points[0].date_ms), 2, baseline + 12)
            var lastText = Format.clockTime(points[points.length - 1].date_ms)
            ctx.fillText(lastText, w - ctx.measureText(lastText).width - 2, baseline + 12)
            // Peak legend: title at left, series legend at right (upstream
            // legend item labels).
            ctx.fillStyle = Theme.label
            ctx.font = "11px sans-serif"
            var legendRight = [];
            for (var l = 0; l < series.length; l++) legendRight.push(series[l].label)
            ctx.fillText("Peak " + Format.rate(peakRate), 2, 12)
            var label = legendRight.join("  ·  ")
            ctx.fillStyle = Theme.secondaryLabel
            ctx.fillText(label, w - ctx.measureText(label).width - 6, 12)
        }
    }

    component PacketLengthsCanvas: Canvas {
        id: lengthsCanvas

        readonly property var counts: {
            var overview = overviewPage.overview
            return overview.packet_lengths ? overview.packet_lengths : []
        }
        onCountsChanged: requestPaint()
        onWidthChanged: requestPaint()
        onPaint: {
            var ctx = getContext("2d")
            var w = width
            var h = height
            var labelSpace = 16
            var baseline = h - labelSpace - 2
            ctx.clearRect(0, 0, w, h)
            if (counts.length === 0) {
                ctx.fillStyle = Theme.secondaryLabel
                ctx.font = "11px sans-serif"
                ctx.fillText("No packets", 4, 14)
                return
            }
            var max = 1
            for (var i = 0; i < counts.length; i++)
                max = Math.max(max, Number(counts[i]) || 0)
            var slotWidth = w / counts.length
            for (var j = 0; j < counts.length; j++) {
                var value = Number(counts[j]) || 0
                var barHeight = value * (baseline / max)
                var barWidth = Math.max(8, slotWidth - 8)
                var x = j * slotWidth + (slotWidth - barWidth) / 2
                ctx.fillStyle = "#5b8bd4"
                if (barHeight > 0)
                    ctx.fillRect(x, baseline - barHeight, barWidth, barHeight)
                ctx.fillStyle = Theme.secondaryLabel
                ctx.font = "10px sans-serif"
                var label = Format.lengthBucketLabel(j)
                ctx.fillText(label, x + barWidth / 2 - ctx.measureText(label).width / 2, baseline + 12)
            }
            ctx.strokeStyle = Theme.separator
            ctx.lineWidth = 1
            ctx.beginPath()
            ctx.moveTo(0, baseline + 0.5)
            ctx.lineTo(w, baseline + 0.5)
            ctx.stroke()
            ctx.fillStyle = Theme.secondaryLabel
            ctx.font = "10px sans-serif"
            ctx.fillText(Format.lengthBucketTitle(0) + " to " + Format.lengthBucketTitle(counts.length - 1), 2, 10)
        }
    }

    // Share rows: protocols, top apps, destinations, and services with a
    // proportional byte bar. Rows for apps/domains/IPs apply the same tree
    // scope the sidebar would select (upstream row actions).
    component ShareRowsList: ListView {
        id: shareRows

        required property string kind
        readonly property var rows: {
            var overview = overviewPage.overview
            var input
            switch (kind) {
            case "protocols": input = overview.protocols; break
            case "topApps": input = overview.top_apps; break
            case "topDestinations": input = overview.top_destinations; break
            case "services": {
                var serviceRows = []
                var services = overview.top_services ? overview.top_services : []
                for (var i = 0; i < services.length; i++) {
                    var service = services[i]
                    var name = service.service_name
                        ? service.transport.toUpperCase() + " " + service.port + " \u00B7 " + service.service_name
                        : service.transport.toUpperCase() + " " + service.port
                    serviceRows.push({ title: name, totals: service.totals, kind: "service", key: "" })
                }
                return serviceRows
            }
            }
            var rows = []
            var source = input ? input : []
            for (var j = 0; j < source.length; j++) {
                var entry = source[j]
                rows.push({
                    title: String(entry.title),
                    totals: entry.totals ? entry.totals : {},
                    kind: entry.kind ? String(entry.kind) : "",
                    key: entry.key ? String(entry.key) : "",
                })
            }
            return rows
        }
        readonly property real maxBytes: {
            var max = 0
            for (var i = 0; i < rows.length; i++) {
                var totals = rows[i].totals ? rows[i].totals : {}
                max = Math.max(max, Number(totals.bytes) || 0)
            }
            return max
        }

        model: rows
        spacing: 8
        clip: true
        interactive: false

        delegate: Item {
            id: shareRow

            required property var modelData

            width: shareRows.width
            height: 32

            readonly property var rowTotals: modelData.totals ? modelData.totals : {}
            readonly property real bytes: Number(rowTotals.bytes) || 0
            readonly property real share: shareRows.maxBytes > 0 ? bytes / shareRows.maxBytes : 0
            readonly property color tint: shareRows.kind === "services" || shareRows.kind === "topApps"
                ? Theme.accent : Theme.protocolTint(modelData.title)
            readonly property bool clickable:
                (modelData.kind === "domain" || modelData.kind === "ip" || modelData.kind === "app")
                && modelData.key.length > 0

            function applyRowFilter() {
                var session = overviewPage.session
                if (modelData.kind === "app")
                    session.selectTreeFilter("app:" + modelData.key)
                else if (modelData.kind === "domain")
                    session.selectTreeFilter("domain:" + modelData.key)
                else if (modelData.kind === "ip")
                    session.selectTreeFilter("ip:" + modelData.key)
            }

            MouseArea {
                id: shareRowArea

                anchors.fill: parent
                hoverEnabled: true
                cursorShape: shareRow.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: if (shareRow.clickable) shareRow.applyRowFilter()
            }
            Rectangle {
                anchors.fill: parent
                radius: 6
                color: Theme.rowAlternate
                opacity: shareRowArea.containsMouse && shareRow.clickable ? 1 : 0
            }

            Column {
                anchors.fill: parent
                spacing: 3

                RowLayout {
                    width: parent.width
                    spacing: 8

                    Text {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        text: shareRow.modelData.title
                        font.family: Theme.uiFont
                        font.pixelSize: Theme.uiSize
                        color: Theme.label
                    }
                    Text {
                        text: Format.bytes(shareRow.bytes)
                        font.family: Theme.uiFont
                        font.pixelSize: Theme.uiSmall
                        color: Theme.secondaryLabel
                    }
                }
                Rectangle {
                    width: parent.width
                    height: 5
                    radius: 2.5
                    color: Theme.separator

                    Rectangle {
                        width: parent.width * shareRow.share
                        height: parent.height
                        radius: 2.5
                        color: shareRow.tint
                    }
                }
            }
        }

        Label {
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            visible: shareRows.rows.length === 0
            text: {
                switch (shareRows.kind) {
                case "topApps": return "Apps appear once live traffic is attributed to local processes."
                case "topDestinations": return "No destinations in this packet range."
                case "protocols": return "No protocols in this packet range."
                default: return "No services in this packet range."
                }
            }
            font.family: Theme.uiFont
            font.pixelSize: Theme.uiSmall
            color: Theme.secondaryLabel
        }
    }

    component ConversationRowsList: ListView {
        id: conversationRows

        readonly property var rows: {
            var overview = overviewPage.overview
            return overview.top_conversations ? overview.top_conversations : []
        }

        model: rows
        spacing: 8
        clip: true
        interactive: false

        delegate: Item {
            required property var modelData

            width: conversationRows.width
            height: 26

            Text {
                width: parent.width - 76
                elide: Text.ElideRight
                anchors.verticalCenter: parent.verticalCenter
                text: {
                    var label = modelData.client_address + ":" + modelData.client_port
                        + " \u21C4 " + modelData.server_address + ":" + modelData.server_port
                    if (modelData.domain_name)
                        label += "  \u00B7 " + modelData.domain_name
                    if (modelData.app_name)
                        label += "  \u00B7 " + modelData.app_name
                    return label
                }
                font.family: Theme.uiFont
                font.pixelSize: Theme.uiSmall
                color: Theme.label
            }
            Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: Format.bytes(Number((modelData.totals ? modelData.totals : {}).bytes) || 0)
                font.family: Theme.uiFont
                font.pixelSize: Theme.uiSmall
                color: Theme.secondaryLabel
            }
        }

        Label {
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            visible: conversationRows.rows.length === 0
            text: "No conversations in this packet range."
            font.family: Theme.uiFont
            font.pixelSize: Theme.uiSmall
            color: Theme.secondaryLabel
        }
    }

    component TcpAnalysisRowsList: ListView {
        id: issueRows

        readonly property var rows: {
            var overview = overviewPage.overview
            return overview.tcp_issues ? overview.tcp_issues : []
        }

        model: rows
        spacing: 4
        clip: true
        interactive: false

        delegate: ItemDelegate {
            id: issueRow

            required property var modelData

            width: issueRows.width
            height: 32

            contentItem: RowLayout {
                spacing: 10

                Text {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    text: Format.issueLabel(issueRow.modelData.kind)
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSize
                    color: Theme.label
                }
                Rectangle {
                    implicitWidth: 52
                    implicitHeight: 20
                    radius: 10
                    color: Theme.systemRed
                    Layout.alignment: Qt.AlignVCenter

                    Text {
                        anchors.centerIn: parent
                        text: Format.count(issueRow.modelData.packets)
                        font.family: Theme.uiFont
                        font.pixelSize: Theme.uiSmall
                        font.weight: Font.DemiBold
                        color: "#ffffff"
                    }
                }
            }

            background: Rectangle {
                radius: 6
                color: issueRow.hovered ? Theme.rowAlternate : "transparent"
            }

            onClicked: {
                // Paste this issue's fixed Wireshark display filter.
                overviewPage.session.applyFilter(String(issueRow.modelData.filter))
            }
        }

        Label {
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            visible: issueRows.rows.length === 0
            text: "No flagged packets \u2014 healthy capture."
            font.family: Theme.uiFont
            font.pixelSize: Theme.uiSmall
            color: Theme.secondaryLabel
        }
    }
}
