import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import Omarchy.TCPViewer
import "OverviewFormat.js" as Format

// Overview page: the aggregate dashboard the owner sees first. Ported from
// upstream CaptureOverviewViewController/CaptureOverviewDashboardView: five
// summary tiles, then a 3-column grid of fixed-height chart cards followed by
// the in-grid Add Chart cell. The default eight cards are the upstream six
// defaults plus Top Conversations and Services & Ports, so the Services card
// is the last chart immediately before Add Chart and the grid stays full.
Rectangle {
    id: overviewPage

    required property SessionController session

    // The dashboard hands control back to the packet workspace (upstream:
    // showPacketsFromOverview clears the scope filters and selects All Packets).
    signal requestMode(string mode)
    signal requestEndpoints()

    color: Theme.windowBackground

    readonly property var overview: session ? session.overview : ({})

    // Upstream card pool. Services is deliberately last in the defaults: it is
    // the last chart card before the Add Chart cell, as in the current app.
    readonly property var allCards: [
        "packets", "throughput", "protocols", "topApps", "topDestinations",
        "tcpAnalysis", "conversations", "services", "packetLengths",
    ]
    readonly property var defaultCards: [
        "packets", "throughput", "protocols", "topApps", "topDestinations",
        "tcpAnalysis", "conversations", "services",
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

    readonly property var overviewTotals: overview && overview.totals ? overview.totals : ({})
    readonly property real totalPackets: Number(overviewTotals.packets) || 0
    readonly property real totalBytes: Number(overviewTotals.bytes) || 0
    readonly property real totalIssues: Number(overviewTotals.issue_packets) || 0
    readonly property real totalSentBytes: Number(overviewTotals.sent_bytes) || 0
    readonly property real totalReceivedBytes: Number(overviewTotals.received_bytes) || 0
    readonly property real tcpPackets: Number(overview && overview.tcp_packet_count) || 0
    readonly property real appCount: Number(overview && overview.app_count) || 0
    readonly property real domainCount: Number(overview && overview.domain_count) || 0
    readonly property var timelinePoints: overview && overview.timeline ? overview.timeline : []
    readonly property real timelineInterval: Number(overview && overview.timeline_interval_ms) || 1000
    readonly property bool throughputSplit: totalSentBytes > 0 || totalReceivedBytes > 0

    readonly property bool hasData: totalPackets > 0

    // A capture source exists (live or opened file). Drives the per-card
    // empty-state detail copy when the dashboard has no packets yet.
    readonly property bool hasSource: {
        var id = session ? String(session.status.source_id || "") : ""
        return id.length > 0
    }

    // Grid geometry. Cards are fixed-height like upstream (340px); the width
    // resolves against the grid content, not the page, so three columns fit
    // inside the 24px page margins without clipping the last card.
    readonly property real cardSpacing: 16
    readonly property real cardMinWidth: 300
    readonly property real cardHeight: 340
    readonly property real pageMargin: 24
    readonly property int cardColumns: Math.max(1, Math.min(3,
        Math.floor((width - 2 * pageMargin + cardSpacing)
                   / (cardMinWidth + cardSpacing))))
    readonly property real cardWidth: (width - 2 * pageMargin
        - (cardColumns - 1) * cardSpacing) / cardColumns

    // Visible cards plus the Add Chart cell at the end (upstream
    // CaptureOverviewCardGrid always appends the cell).
    readonly property var cardRows: {
        var cells = visibleCards.slice()
        cells.push("__add__")
        var rows = []
        var step = Math.max(1, cardColumns)
        for (var i = 0; i < cells.length; i += step)
            rows.push(cells.slice(i, i + step))
        return rows
    }

    readonly property real peakPacketsPerSecond: {
        var maximum = 0
        var list = timelinePoints ? timelinePoints : []
        for (var i = 0; i < list.length; i++) {
            var totals = list[i] && list[i].totals ? list[i].totals : {}
            maximum = Math.max(maximum, Number(totals.packets) || 0)
        }
        return maximum * 1000 / Math.max(1, timelineInterval)
    }

    readonly property real peakBytesPerSecond: {
        var maximum = 0
        var list = timelinePoints ? timelinePoints : []
        for (var i = 0; i < list.length; i++) {
            var totals = list[i] && list[i].totals ? list[i].totals : {}
            var sent = Number(totals.sent_bytes) || 0
            var received = Number(totals.received_bytes) || 0
            if (throughputSplit)
                maximum = Math.max(maximum, sent, received)
            else
                maximum = Math.max(maximum, Number(totals.bytes) || 0)
        }
        return maximum * 1000 / Math.max(1, timelineInterval)
    }

    readonly property string bucketLabel: {
        var seconds = timelineInterval / 1000
        return (seconds === Math.round(seconds) ? String(seconds)
                                                : seconds.toFixed(1)) + "s"
    }

    // Header subtitle: the file's basename in chrome; full paths and live
    // capture wording stay out of the page header.
    readonly property string sourceLabel: {
        var status = session ? session.status : {}
        var raw = status.path || status.display_name || status.interface || ""
        if (raw.length === 0)
            return ""
        var name = String(raw).split("/").pop()
        return status.kind === "offline" ? name : "Live on " + name
    }

    readonly property string hiddenHint: {
        var hidden = hiddenCards
        if (hidden.length === 0)
            return "Every chart is on the Overview"
        var names = []
        for (var i = 0; i < hidden.length && i < 3; i++)
            names.push(cardTitle(hidden[i]))
        return names.join(", ") + (hidden.length > 3 ? "…" : "")
    }

    // ---------------------------------------------------------------------
    // Card metadata and data
    // ---------------------------------------------------------------------

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

    function cardSubtitle(kind) {
        switch (String(kind)) {
        case "packets":
            return bucketLabel + " buckets · peak "
                   + Format.count(peakPacketsPerSecond) + " packets/s"
        case "throughput":
            return "Peak " + Format.rate(peakBytesPerSecond)
                   + (throughputSplit ? " · sent vs received" : " · total bytes")
        case "protocols":
            return "Share of captured bytes"
        case "topApps":
            return "By data transferred · top 6"
        case "topDestinations":
            return "By data transferred · top 6"
        case "tcpAnalysis":
            return tcpSubtitle()
        case "conversations":
            return "Busiest connections by data"
        case "services":
            return "By service port · top 6"
        case "packetLengths":
            return "Average " + Format.bytes(totalPackets > 0
                                             ? totalBytes / totalPackets : 0)
                   + " per packet"
        }
        return ""
    }

    function cardGlyph(kind) {
        switch (String(kind)) {
        case "packets": return "▥"
        case "throughput": return "◔"
        case "protocols": return "◕"
        case "topApps": return "▦"
        case "topDestinations": return "◍"
        case "tcpAnalysis": return "⚠"
        case "conversations": return "⇄"
        case "services": return "#"
        case "packetLengths": return "↔"
        }
        return "•"
    }

    function cardTint(kind) {
        switch (String(kind)) {
        case "packets": return Theme.systemBlue
        case "throughput": return Theme.systemIndigo
        case "protocols": return Theme.systemPurple
        case "topApps": return Theme.systemOrange
        case "topDestinations": return Theme.systemCyan
        case "tcpAnalysis": return Theme.systemRed
        case "conversations": return Theme.systemTeal
        case "services": return Theme.systemMint
        case "packetLengths": return Theme.systemPink
        }
        return Theme.accent
    }

    function issueColor(kind) {
        switch (String(kind)) {
        case "malformed": return Theme.systemBrown
        case "lost_segment": return Theme.systemRed
        case "retransmission": return Theme.systemOrange
        case "out_of_order": return Theme.systemPurple
        case "zero_window": return Theme.systemPink
        case "duplicate_ack": return Theme.systemYellow
        case "reset": return Theme.systemIndigo
        }
        return Theme.systemRed
    }

    function tcpSubtitle() {
        return totalIssues > 0
            ? Format.count(totalIssues) + " of " + Format.count(tcpPackets)
              + " TCP packets flagged"
            : Format.count(tcpPackets) + " TCP packets analyzed"
    }

    function tcpEmptyTitle() {
        return tcpPackets > 0 ? "No TCP problems detected" : "No TCP traffic"
    }

    function tcpEmptyDetail() {
        return tcpPackets > 0
            ? "No retransmissions, lost segments, zero windows or resets."
            : "TCP problems appear here as packets are analyzed."
    }

    // Per-card empty-state title shown while the dashboard has no packets
    // (upstream CaptureOverviewCardView placeholder copy).
    function cardEmptyTitle(kind) {
        switch (String(kind)) {
        case "packets": return "No packets yet"
        case "throughput": return "No traffic yet"
        case "protocols": return "No protocols yet"
        case "topApps": return "No apps yet"
        case "topDestinations": return "No destinations yet"
        case "tcpAnalysis": return tcpEmptyTitle()
        case "conversations": return "No conversations yet"
        case "services": return "No services yet"
        case "packetLengths": return "No lengths yet"
        }
        return ""
    }

    function cardEmptyDetail(kind) {
        if (String(kind) === "tcpAnalysis")
            return tcpEmptyDetail()
        if (!overviewPage.session)
            return ""
        if (overviewPage.session.loading)
            return "Loading…"
        if (!overviewPage.hasSource)
            return "Start a capture or open a capture file."
        if (overviewPage.session.capturing)
            return "Waiting for packets…"
        return "No packets in the current range."
    }

    function directionText(totals) {
        var sent = Number(totals.sent_bytes) || 0
        var received = Number(totals.received_bytes) || 0
        if (sent + received > 0)
            return "↑ " + Format.bytes(sent) + " · ↓ " + Format.bytes(received)
        return "Original packet bytes"
    }

    function conversationFilter(entry) {
        var key = String(entry.key || "")
        if (key.indexOf("tcp.stream:") === 0)
            return "tcp.stream == " + key.substring("tcp.stream:".length)
        if (key.indexOf("udp.stream:") === 0)
            return "udp.stream == " + key.substring("udp.stream:".length)
        var transport = key.indexOf("udp") === 0 ? "udp" : "tcp"
        var address = entry.server_address ? String(entry.server_address) : ""
        var port = Number(entry.server_port) || 0
        if (address.length > 0)
            return "ip.addr == " + address + " && " + transport + ".port == " + port
        return ""
    }

    function trafficRows(kind) {
        var data = overview ? overview : ({})
        var source = []
        switch (String(kind)) {
        case "topApps": source = data.top_apps ? data.top_apps : []; break
        case "topDestinations": source = data.top_destinations ? data.top_destinations : []; break
        case "services": source = data.top_services ? data.top_services : []; break
        case "conversations": source = data.top_conversations ? data.top_conversations : []; break
        }

        var rows = []
        for (var i = 0; i < source.length && rows.length < 6; i++) {
            var entry = source[i] ? source[i] : {}
            var totals = entry.totals ? entry.totals : {}
            var bytes = Number(totals.bytes) || 0
            var packets = Number(totals.packets) || 0
            var issues = Number(totals.issue_packets) || 0
            var sent = Number(totals.sent_bytes) || 0
            var received = Number(totals.received_bytes) || 0
            var unknown = Number(totals.unclassified_bytes) || 0
            var usesSplit = sent + received > 0
            var row = {
                bytes: bytes,
                packets: packets,
                issueCount: issues,
                sentFraction: 0,
                receivedFraction: 0,
                unknownFraction: 0,
                usesSplit: usesSplit,
                clickable: false,
                actionKind: "none",
                actionValue: "",
                badgeText: "",
                glyph: "•",
                tint: Theme.accent,
                valueText: Format.bytes(bytes),
                detailText: "",
                help: ""
            }

            if (kind === "topApps") {
                row.title = String(entry.title || "")
                row.glyph = "▦"
                row.tint = Theme.systemOrange
                row.clickable = row.title.length > 0 && entry.key !== undefined
                                && entry.key !== null && String(entry.key).length > 0
                row.actionKind = "tree"
                row.actionValue = "app:" + String(entry.key || "")
                row.detailText = (packets === 1 ? "1 packet" : Format.count(packets) + " packets")
                                 + " · " + Format.percent(bytes, totalBytes)
                row.help = "Show packets of " + row.title + "\n" + directionText(totals)
            } else if (kind === "topDestinations") {
                row.title = String(entry.title || "")
                row.glyph = entry.kind === "domain" ? "◍" : "◇"
                row.tint = entry.kind === "domain" ? Theme.systemCyan : Theme.systemBlue
                row.clickable = row.title.length > 0 && entry.kind !== undefined
                                && entry.kind !== null && String(entry.key || "").length > 0
                row.actionKind = "tree"
                row.actionValue = String(entry.kind || "ip") + ":" + String(entry.key || "")
                row.detailText = (packets === 1 ? "1 packet" : Format.count(packets) + " packets")
                                 + " · " + Format.percent(bytes, totalBytes)
                row.help = "Show packets of " + row.title + "\n" + directionText(totals)
            } else if (kind === "services") {
                var transport = String(entry.transport || "").toUpperCase()
                var port = Number(entry.port) || 0
                var serviceName = entry.service_name ? String(entry.service_name) : ""
                row.title = serviceName.length > 0 ? serviceName : transport + " " + port
                row.badgeText = String(port)
                row.glyph = ""
                row.tint = Theme.systemMint
                row.clickable = transport.length > 0 && port > 0
                row.actionKind = "filter"
                row.actionValue = transport.toLowerCase() + ".port == " + port
                row.detailText = transport + " · " + Format.percent(bytes, totalBytes)
                row.help = transport + " port " + port
                            + (serviceName.length > 0 ? " (" + serviceName + ")" : "")
                            + "\n" + directionText(totals)
                            + (row.actionValue.length > 0 ? "\nFilter: " + row.actionValue : "")
            } else if (kind === "conversations") {
                var server = (entry.domain_name ? String(entry.domain_name)
                                                : String(entry.server_address || ""))
                             + ":" + String(entry.server_port || "")
                var conversationTransport = String(entry.key || "").indexOf("udp") === 0
                    ? "UDP" : "TCP"
                var filter = conversationFilter(entry)
                row.title = server
                row.glyph = "⇄"
                row.tint = Theme.systemTeal
                row.clickable = filter.length > 0
                row.actionKind = filter.length > 0 ? "filter" : "none"
                row.actionValue = filter
                row.detailText = conversationTransport + " · " + Format.percent(bytes, totalBytes)
                row.help = String(entry.client_address || "") + ":" + String(entry.client_port || "")
                            + " ⇄ " + String(entry.server_address || "") + ":"
                            + String(entry.server_port || "")
                            + (entry.app_name ? "\n" + String(entry.app_name) : "")
                            + "\n" + directionText(totals)
                            + (filter.length > 0 ? "\nFilter: " + filter : "")
            }

            rows.push(row)
        }

        var maximum = 0
        for (var j = 0; j < rows.length; j++)
            maximum = Math.max(maximum, rows[j].bytes)
        maximum = Math.max(1, maximum)
        // Re-read the raw direction fields while applying the common scale.
        for (var r = 0; r < rows.length && r < source.length; r++) {
            var rawTotals = source[r] && source[r].totals ? source[r].totals : {}
            var rawSent = Number(rawTotals.sent_bytes) || 0
            var rawReceived = Number(rawTotals.received_bytes) || 0
            var rawUnknown = Number(rawTotals.unclassified_bytes) || 0
            var split = rawSent + rawReceived > 0
            rows[r].sentFraction = rawSent / maximum
            rows[r].receivedFraction = rawReceived / maximum
            rows[r].unknownFraction = (split ? rawUnknown : rows[r].bytes) / maximum
        }
        return rows
    }

    function protocolRows() {
        var data = overview ? overview : ({})
        var source = data.protocols ? data.protocols : []
        var rows = []
        for (var i = 0; i < source.length; i++) {
            var entry = source[i] ? source[i] : {}
            var totals = entry.totals ? entry.totals : {}
            var bytes = Number(totals.bytes) || 0
            rows.push({
                title: String(entry.title || "Other"),
                bytes: bytes,
                fraction: totalBytes > 0 ? bytes / totalBytes : 0,
                percentText: Format.percent(bytes, totalBytes),
                bytesText: Format.bytes(bytes),
                color: Theme.chartColor(i)
            })
        }
        return rows
    }

    function tcpRows() {
        var data = overview ? overview : ({})
        var source = data.tcp_issues ? data.tcp_issues : []
        var rows = []
        for (var i = 0; i < source.length; i++) {
            var entry = source[i] ? source[i] : {}
            var kind = String(entry.kind || "")
            var count = Number(entry.packets) || 0
            var base = kind === "malformed" ? totalPackets : tcpPackets
            rows.push({
                kind: kind,
                title: Format.issueLabel(kind),
                count: count,
                countText: Format.count(count),
                percentText: Format.percent(count, base),
                color: issueColor(kind),
                filter: String(entry.filter || ""),
                help: Format.issueLabel(kind) + "\nFilter: " + String(entry.filter || "")
            })
        }
        return rows
    }

    function contentFor(kind) {
        switch (String(kind)) {
        case "packets": return packetsContent
        case "throughput": return throughputContent
        case "protocols": return protocolsContent
        case "topApps": return topAppsContent
        case "topDestinations": return topDestinationsContent
        case "tcpAnalysis": return tcpAnalysisContent
        case "conversations": return conversationsContent
        case "services": return servicesContent
        case "packetLengths": return packetLengthsContent
        }
        return null
    }

    function addCard(kind) {
        if (!session || visibleCards.indexOf(kind) >= 0)
            return
        cards = visibleCards.concat([kind])
    }

    function removeCard(kind) {
        var next = []
        for (var i = 0; i < visibleCards.length; i++) {
            if (visibleCards[i] !== kind)
                next.push(visibleCards[i])
        }
        cards = next
    }

    function restoreDefaults() {
        cards = defaultCards.slice()
    }

    function activateRow(row) {
        if (!row || !session)
            return
        if (row.actionKind === "tree" && row.actionValue.length > 0)
            session.selectTreeFilter(row.actionValue)
        else if (row.actionKind === "filter" && row.actionValue.length > 0)
            session.applyFilter(row.actionValue)
        else
            return
        overviewPage.requestMode("packets")
    }

    function applyDisplayFilter(expression) {
        if (!session || !expression)
            return
        session.applyFilter(expression)
        overviewPage.requestMode("packets")
    }

    // Opens a Menu just below the anchor. The page is passed as the popup
    // parent so the x/y coordinates (and the mapToItem call above) are both
    // resolved against the same item. Qt 6.11 has no popup(x, y) overload.
    function popupBelow(anchor, menu) {
        var position = anchor.mapToItem(overviewPage, 0, 0)
        menu.popup(overviewPage, position.x, position.y + anchor.height + 4)
    }

    // Upstream Share actions: Copy as Markdown / Save as Markdown. Computed
    // at call time so the export always mirrors the dashboard's current data.
    property bool shareCopied: false
    property string pendingMarkdown: ""

    function markdownForOverview() {
        return Format.summaryMarkdown(overview, sourceLabel, visibleCards)
    }

    function copyOverviewMarkdown() {
        if (!hasData || !session)
            return
        session.copyToClipboard(markdownForOverview())
        shareCopied = true
        shareResetTimer.restart()
    }

    function saveOverviewMarkdown(path) {
        if (!hasData || !session || path.length === 0)
            return
        if (!session.writeTextFile(path, markdownForOverview()))
            session.reportError("Could not save " + path)
    }

    function fileDialogPath(file) {
        const value = String(file)
        if (value.startsWith("file://"))
            return decodeURIComponent(value.slice("file://".length))
        return value
    }

    // CI hook: when TCPVIEWER_DUMP_OVERVIEW_MD is set, write the Share
    // export's markdown to that path once data arrives (validates the
    // upstream Share/Copy-as-Markdown output without interactive testing).
    property bool mdDumped: false
    onHasDataChanged: {
        var path = session ? session.envValue("TCPVIEWER_DUMP_OVERVIEW_MD") : ""
        if (hasData && !mdDumped && path.length > 0) {
            mdDumped = true
            session.writeTextFile(path, markdownForOverview())
        }
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

    Timer {
        id: shareResetTimer
        interval: 2000
        repeat: false
        onTriggered: overviewPage.shareCopied = false
    }

    // Upstream Share menu on the dashboard header.
    Menu {
        id: shareMenu

        MenuItem {
            text: "Copy as Markdown"
            onTriggered: overviewPage.copyOverviewMarkdown()
        }
        MenuItem {
            text: "Save as Markdown…"
            onTriggered: {
                overviewPage.pendingMarkdown = overviewPage.markdownForOverview()
                exportOverviewDialog.open()
            }
        }
    }

    FileDialog {
        id: exportOverviewDialog
        title: "Export overview summary"
        fileMode: FileDialog.SaveFile
        defaultSuffix: "md"
        nameFilters: ["Markdown (*.md)"]
        onAccepted: overviewPage.saveOverviewMarkdown(
            overviewPage.fileDialogPath(exportOverviewDialog.selectedFile))
    }

    Flickable {
        id: scroller

        anchors.fill: parent
        contentWidth: width
        contentHeight: column.height + overviewPage.pageMargin * 2
        clip: true
        ScrollBar.vertical: ScrollBar {}

        Column {
            id: column

            x: overviewPage.pageMargin
            y: overviewPage.pageMargin
            width: overviewPage.width - overviewPage.pageMargin * 2
            spacing: 16

            // Header: page title, source, and the three upstream dashboard
            // actions (Endpoints, View Packets, Share).
            RowLayout {
                width: parent.width
                spacing: 8

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
                    text: overviewPage.sourceLabel
                }
                ToolButton {
                    text: "Endpoints…"
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSmall
                    implicitHeight: 28
                    onClicked: overviewPage.requestEndpoints()
                }
                ToolButton {
                    text: "View Packets"
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSmall
                    implicitHeight: 28
                    onClicked: overviewPage.requestMode("packets")
                }
                ToolButton {
                    id: shareButton

                    enabled: overviewPage.hasData
                    text: overviewPage.shareCopied ? "Copied ✓" : "Share ▾"
                    font.family: Theme.uiFont
                    font.pixelSize: Theme.uiSmall
                    implicitHeight: 28
                    onClicked: overviewPage.popupBelow(shareButton, shareMenu)
                }
            }

            OverviewMetrics {
                width: parent.width
                overview: overviewPage.overview
            }

            // Card grid: visible cards + the Add Chart cell, chunked into
            // explicit rows so cross-row gaps stay equal and the last card is
            // never clipped by a Grid's implicit sizing. Always present —
            // cards show their empty states while no packets have arrived.
            Column {
                id: cardGrid

                width: parent.width
                spacing: overviewPage.cardSpacing

                Repeater {
                    model: overviewPage.cardRows

                    delegate: Row {
                        required property var modelData

                        spacing: overviewPage.cardSpacing

                        Repeater {
                            model: parent.modelData

                            delegate: Item {
                                required property var modelData

                                width: overviewPage.cardWidth
                                height: overviewPage.cardHeight

                                OverviewCard {
                                    anchors.fill: parent
                                    visible: modelData !== "__add__"
                                    title: overviewPage.cardTitle(modelData)
                                    subtitle: overviewPage.cardSubtitle(modelData)
                                    glyph: overviewPage.cardGlyph(modelData)
                                    tint: overviewPage.cardTint(modelData)
                                    emptyMessage: overviewPage.hasData
                                        ? "" : overviewPage.cardEmptyTitle(modelData)
                                    emptyDetail: overviewPage.hasData
                                        ? "" : overviewPage.cardEmptyDetail(modelData)
                                    onRemoveRequested: overviewPage.removeCard(modelData)

                                    Loader {
                                        anchors.fill: parent
                                        sourceComponent: overviewPage.contentFor(modelData)
                                    }
                                }

                                AddCardCell {
                                    anchors.fill: parent
                                    visible: modelData === "__add__"
                                }
                            }
                        }
                    }
                }
            }

            Menu {
                id: addCardMenu

                Repeater {
                    model: overviewPage.allCards

                    delegate: MenuItem {
                        required property var modelData

                        text: (overviewPage.visibleCards.indexOf(modelData) >= 0
                               ? "✓  " : "     ") + overviewPage.cardTitle(modelData)
                        onTriggered: {
                            if (overviewPage.visibleCards.indexOf(modelData) >= 0)
                                overviewPage.removeCard(modelData)
                            else
                                overviewPage.addCard(modelData)
                        }
                    }
                }

                MenuSeparator { }

                MenuItem {
                    text: "Restore Defaults"
                    enabled: {
                        var current = overviewPage.visibleCards
                        var defaults = overviewPage.defaultCards
                        if (current.length !== defaults.length)
                            return true
                        for (var i = 0; i < defaults.length; i++) {
                            if (current[i] !== defaults[i])
                                return true
                        }
                        return false
                    }
                    onTriggered: overviewPage.restoreDefaults()
                }
            }
        }
    }

    // ---------------------------------------------------------------------
    // Summary tiles (the five upstream metricPresentations)
    // ---------------------------------------------------------------------
    component OverviewMetrics: Flow {
        id: metrics

        required property var overview

        spacing: 14

        Repeater {
            model: {
                var totals = metrics.overview && metrics.overview.totals
                    ? metrics.overview.totals : {}
                var packets = Number(totals.packets) || 0
                var firstMs = Number(metrics.overview && metrics.overview.first_packet_ms) || 0
                var lastMs = Number(metrics.overview && metrics.overview.last_packet_ms) || 0
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
                    ? "↑ " + Format.bytes(sent) + "   ↓ " + Format.bytes(received)
                    : "Original packet bytes"
                var tcp = Number(metrics.overview && metrics.overview.tcp_packet_count) || 0
                var issues = Number(totals.issue_packets) || 0
                var issueDetail = issues > 0
                    ? Format.percent(issues, tcp) + " of TCP packets"
                    : "No flagged packets"
                var apps = Number(metrics.overview && metrics.overview.app_count) || 0
                var domains = Number(metrics.overview && metrics.overview.domain_count) || 0
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

                width: Math.max(150, (metrics.width - 4 * metrics.spacing) / 5)
                height: 84
                radius: 12
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

    // ---------------------------------------------------------------------
    // Grid Add Chart cell
    // ---------------------------------------------------------------------
    component AddCardCell: Item {
        id: addCell

        activeFocusOnTab: true

        HoverHandler {
            id: addHover
        }

        Canvas {
            id: dashedBorder

            anchors.fill: parent

            function roundedRect(ctx, x, y, w, h, radius) {
                ctx.beginPath()
                ctx.moveTo(x + radius, y)
                ctx.lineTo(x + w - radius, y)
                ctx.quadraticCurveTo(x + w, y, x + w, y + radius)
                ctx.lineTo(x + w, y + h - radius)
                ctx.quadraticCurveTo(x + w, y + h, x + w - radius, y + h)
                ctx.lineTo(x + radius, y + h)
                ctx.quadraticCurveTo(x, y + h, x, y + h - radius)
                ctx.lineTo(x, y + radius)
                ctx.quadraticCurveTo(x, y, x + radius, y)
                ctx.closePath()
            }

            onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                ctx.lineWidth = 1.5
                ctx.setLineDash([6, 5])
                ctx.strokeStyle = addHover.hovered
                    ? Qt.rgba(Theme.systemOrange.r, Theme.systemOrange.g,
                              Theme.systemOrange.b, 0.65)
                    : Theme.separator
                roundedRect(ctx, 1, 1, width - 2, height - 2, 18)
                ctx.stroke()
                ctx.setLineDash([])
            }

            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
        }

        Column {
            anchors.centerIn: parent
            spacing: 10

            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 44
                height: 44
                radius: 22
                color: Qt.rgba(Theme.systemOrange.r, Theme.systemOrange.g,
                               Theme.systemOrange.b, addHover.hovered ? 0.20 : 0.12)

                Text {
                    anchors.centerIn: parent
                    text: "+"
                    font.family: Theme.uiFont
                    font.pixelSize: 22
                    font.weight: Font.DemiBold
                    color: Theme.systemOrange
                }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Add Chart"
                font.family: Theme.uiFont
                font.pixelSize: 13
                font.weight: Font.DemiBold
                color: Theme.label
            }

            Text {
                width: Math.min(overviewPage.cardWidth - 48, 260)
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: overviewPage.hiddenHint
                font.family: Theme.uiFont
                font.pixelSize: 11
                color: Theme.secondaryLabel
            }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: {
                addCell.forceActiveFocus()
                overviewPage.popupBelow(addCell, addCardMenu)
            }
        }

        Keys.onReturnPressed: overviewPage.popupBelow(addCell, addCardMenu)
        Keys.onSpacePressed: overviewPage.popupBelow(addCell, addCardMenu)

        Connections {
            target: addHover
            function onHoveredChanged() {
                dashedBorder.requestPaint()
            }
        }
    }

    // ---------------------------------------------------------------------
    // Card content components
    // ---------------------------------------------------------------------
    Component {
        id: packetsContent

        ColumnLayout {
            anchors.fill: parent
            spacing: 6

            RowLayout {
                Layout.fillWidth: true
                spacing: 14

                Row {
                    spacing: 5
                    Rectangle {
                        width: 8; height: 8; radius: 4
                        anchors.verticalCenter: parent.verticalCenter
                        color: Theme.systemBlue
                    }
                    Text {
                        text: "Packets"
                        font.family: Theme.uiFont
                        font.pixelSize: 10
                        color: Theme.secondaryLabel
                    }
                    Text {
                        text: Format.count(overviewPage.totalPackets)
                        font.family: Theme.monoFont
                        font.pixelSize: 10
                        font.weight: Font.DemiBold
                        color: Theme.label
                    }
                }
                Row {
                    spacing: 5
                    Rectangle {
                        width: 8; height: 8; radius: 4
                        anchors.verticalCenter: parent.verticalCenter
                        color: Theme.systemRed
                    }
                    Text {
                        text: "TCP issues"
                        font.family: Theme.uiFont
                        font.pixelSize: 10
                        color: Theme.secondaryLabel
                    }
                    Text {
                        text: Format.count(overviewPage.totalIssues)
                        font.family: Theme.monoFont
                        font.pixelSize: 10
                        font.weight: Font.DemiBold
                        color: Theme.label
                    }
                }
                Item { Layout.fillWidth: true }
            }

            OverviewTimeChart {
                Layout.fillWidth: true
                Layout.fillHeight: true
                points: overviewPage.timelinePoints
                intervalMs: overviewPage.timelineInterval
                mode: "packets"
            }
        }
    }

    Component {
        id: throughputContent

        ColumnLayout {
            anchors.fill: parent
            spacing: 6

            RowLayout {
                Layout.fillWidth: true
                spacing: 14

                Row {
                    spacing: 5
                    visible: overviewPage.throughputSplit
                    Rectangle {
                        width: 8; height: 8; radius: 4
                        anchors.verticalCenter: parent.verticalCenter
                        color: Theme.systemCyan
                    }
                    Text {
                        text: "Received"
                        font.family: Theme.uiFont
                        font.pixelSize: 10
                        color: Theme.secondaryLabel
                    }
                    Text {
                        text: Format.bytes(overviewPage.totalReceivedBytes)
                        font.family: Theme.monoFont
                        font.pixelSize: 10
                        font.weight: Font.DemiBold
                        color: Theme.label
                    }
                }
                Row {
                    spacing: 5
                    visible: overviewPage.throughputSplit
                    Rectangle {
                        width: 8; height: 8; radius: 4
                        anchors.verticalCenter: parent.verticalCenter
                        color: Theme.systemPurple
                    }
                    Text {
                        text: "Sent"
                        font.family: Theme.uiFont
                        font.pixelSize: 10
                        color: Theme.secondaryLabel
                    }
                    Text {
                        text: Format.bytes(overviewPage.totalSentBytes)
                        font.family: Theme.monoFont
                        font.pixelSize: 10
                        font.weight: Font.DemiBold
                        color: Theme.label
                    }
                }
                Row {
                    spacing: 5
                    visible: !overviewPage.throughputSplit
                    Rectangle {
                        width: 8; height: 8; radius: 4
                        anchors.verticalCenter: parent.verticalCenter
                        color: Theme.systemBlue
                    }
                    Text {
                        text: "Total"
                        font.family: Theme.uiFont
                        font.pixelSize: 10
                        color: Theme.secondaryLabel
                    }
                    Text {
                        text: Format.bytes(overviewPage.totalBytes)
                        font.family: Theme.monoFont
                        font.pixelSize: 10
                        font.weight: Font.DemiBold
                        color: Theme.label
                    }
                }
                Item { Layout.fillWidth: true }
            }

            OverviewTimeChart {
                Layout.fillWidth: true
                Layout.fillHeight: true
                points: overviewPage.timelinePoints
                intervalMs: overviewPage.timelineInterval
                mode: "throughput"
            }
        }
    }

    Component {
        id: protocolsContent

        RowLayout {
            anchors.fill: parent
            spacing: 12

            OverviewDonut {
                Layout.preferredWidth: 118
                Layout.preferredHeight: 118
                Layout.alignment: Qt.AlignVCenter
                rows: overviewPage.protocolRows()
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                Repeater {
                    model: overviewPage.protocolRows()

                    delegate: RowLayout {
                        required property var modelData

                        Layout.fillWidth: true
                        Layout.preferredHeight: 19
                        spacing: 6

                        Rectangle {
                            width: 7; height: 7; radius: 3.5
                            Layout.alignment: Qt.AlignVCenter
                            color: modelData.color
                        }
                        Text {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            text: modelData.title
                            font.family: Theme.uiFont
                            font.pixelSize: 11
                            color: Theme.label
                        }
                        Text {
                            text: modelData.bytesText
                            font.family: Theme.monoFont
                            font.pixelSize: 9
                            color: Theme.secondaryLabel
                        }
                        Text {
                            Layout.preferredWidth: 31
                            horizontalAlignment: Text.AlignRight
                            text: modelData.percentText
                            font.family: Theme.monoFont
                            font.pixelSize: 10
                            color: Theme.secondaryLabel
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    visible: overviewPage.protocolRows().length === 0
                    horizontalAlignment: Text.AlignHCenter
                    text: "No protocols in this packet range."
                    font.family: Theme.uiFont
                    font.pixelSize: 11
                    color: Theme.secondaryLabel
                }
            }
        }
    }

    Component {
        id: topAppsContent

        OverviewTrafficRows {
            anchors.fill: parent
            rows: overviewPage.trafficRows("topApps")
            emptyText: "Apps appear once live traffic is attributed to local processes."
            onRowActivated: (row) => overviewPage.activateRow(row)
        }
    }

    Component {
        id: topDestinationsContent

        OverviewTrafficRows {
            anchors.fill: parent
            rows: overviewPage.trafficRows("topDestinations")
            emptyText: "No destinations in this packet range."
            onRowActivated: (row) => overviewPage.activateRow(row)
        }
    }

    Component {
        id: servicesContent

        OverviewTrafficRows {
            anchors.fill: parent
            rows: overviewPage.trafficRows("services")
            emptyText: "No services in this packet range."
            onRowActivated: (row) => overviewPage.activateRow(row)
        }
    }

    Component {
        id: conversationsContent

        OverviewTrafficRows {
            anchors.fill: parent
            rows: overviewPage.trafficRows("conversations")
            emptyText: "No conversations in this packet range."
            onRowActivated: (row) => overviewPage.activateRow(row)
        }
    }

    Component {
        id: tcpAnalysisContent

        OverviewTCPAnalysis {
            anchors.fill: parent
            rows: overviewPage.tcpRows()
            tcpPackets: overviewPage.tcpPackets
            totalPackets: overviewPage.totalPackets
            emptyTitle: overviewPage.tcpEmptyTitle()
            emptyDetail: overviewPage.tcpEmptyDetail()
            onFilterActivated: (filter) => overviewPage.applyDisplayFilter(filter)
        }
    }

    Component {
        id: packetLengthsContent

        OverviewLengthsChart {
            anchors.fill: parent
            counts: overviewPage.overview && overviewPage.overview.packet_lengths
                ? overviewPage.overview.packet_lengths : []
            totalPackets: overviewPage.totalPackets
            totalBytes: overviewPage.totalBytes
        }
    }
}
