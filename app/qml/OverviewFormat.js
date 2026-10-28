// Overview value formatting, ported from upstream CaptureOverviewFormat.
// pragma Library so every card shares one implementation.
.pragma library

// Byte counts in IEC units, e.g. "1.2 KiB", "953 B".
function bytes(value) {
    var n = Number(value) || 0
    if (n < 1024)
        return Math.round(n) + " B"
    var units = ["KiB", "MiB", "GiB", "TiB"]
    var scaled = n
    for (var i = 0; i < units.length; i++) {
        scaled /= 1024
        if (scaled < 1024 || i === units.length - 1)
            return scaled.toFixed(scaled < 10 ? 1 : 0) + " " + units[i]
    }
    return n + " B"
}

// Counts with light grouping: 12,345. Written manually so this library
// stays independent of the per-import JS environment.
function count(value) {
    return groupNumber(Number(value) || 0)
}

// Group digits manually.
function groupNumber(value) {
    var n = String(Math.max(0, Math.floor(Number(value) || 0)))
    var out = ""
    while (n.length > 3) {
        out = "," + n.slice(-3) + out
        n = n.slice(0, -3)
    }
    return n + out
}

// Average rate as bytes per second, e.g. "3.4 KiB/s".
function rate(bps) {
    if (!(bps > 0))
        return "0 B/s"
    return bytes(Math.round(bps)) + "/s"
}

function percent(part, whole) {
    if (!(whole > 0))
        return "0%"
    var value = (Number(part) || 0) / whole * 100
    if (value > 0 && value < 1)
        return "\u2248" + Math.max(1, Math.round(value)) + "%"  // ≈
    return Math.round(value) + "%"
}

// Wall-clock duration span across packets: "3m 42s" style.
function span(milliseconds) {
    var total = Math.max(0, Math.round(Number(milliseconds) || 0))
    var seconds = Math.round(total / 1000)
    if (seconds < 60)
        return seconds + "s"
    var minutes = Math.floor(seconds / 60)
    seconds %= 60
    if (minutes < 60)
        return minutes + ":" + (seconds < 10 ? "0" : "") + seconds
    var hours = Math.floor(minutes / 60)
    minutes %= 60
    return hours + ":" + (minutes < 10 ? "0" : "") + minutes
}

function clockTime(epochMilliseconds) {
    var date = new Date(Number(epochMilliseconds) || 0)
    if (isNaN(date.getTime()))
        return ""
    var pad = function (n) {
        return (n < 10 ? "0" : "") + n
    }
    return pad(date.getHours()) + ":" + pad(date.getMinutes()) + ":" + pad(date.getSeconds())
}

// Wireshark's Statistics › Packet Lengths axis labels (short lower bounds).
function lengthBucketLabel(index) {
    var bounds = [80, 160, 320, 640, 1280, 2560]
    return index === 0 ? "<" + bounds[0] : bounds[index - 1] + "+"
}

function lengthBucketTitle(index) {
    var bounds = [80, 160, 320, 640, 1280, 2560]
    var lower = index === 0 ? 0 : bounds[index - 1]
    if (index >= bounds.length)
        return lower + " bytes or more"
    return lower + "\u2013" + (bounds[index] - 1) + " bytes"
}

// TCP Analysis row labels (upstream's issue list order and wording).
function issueLabel(kind) {
    switch (String(kind)) {
    case "malformed": return "Malformed Packets"
    case "lost_segment": return "Lost Segments"
    case "retransmission": return "Retransmissions"
    case "out_of_order": return "Out-of-Order"
    case "zero_window": return "Zero Window"
    case "duplicate_ack": return "Duplicate ACKs"
    case "reset": return "Resets"
    }
    return String(kind)
}

// ----- Overview "Share" export (upstream Share: Copy/Save as Markdown) -----

// Keep capture-provided names inside one table cell. Do not allow HTML,
// Markdown links or image syntax to escape from an untrusted packet field.
function markdownEscape(value) {
    return String(value)
        .replace(/\\/g, "\\\\")
        .replace(/\|/g, "\\|")
        .replace(/\[/g, "\\[")
        .replace(/\]/g, "\\]")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/\r\n/g, " ")
        .replace(/\r/g, " ")
        .replace(/\n/g, " ")
}

function markdownTable(title, columns, rows) {
    if (!rows || rows.length === 0)
        return ""
    var out = "## " + title + "\n\n"
    var headers = []
    var rules = []
    for (var i = 0; i < columns.length; i++) {
        headers.push(markdownEscape(columns[i].title))
        rules.push(columns[i].numeric ? "---:" : "---")
    }
    out += "| " + headers.join(" | ") + " |\n"
    out += "| " + rules.join(" | ") + " |\n"
    for (var j = 0; j < rows.length; j++) {
        var cells = []
        for (var k = 0; k < rows[j].length; k++)
            cells.push(markdownEscape(rows[j][k]))
        out += "| " + cells.join(" | ") + " |\n"
    }
    return out + "\n"
}

function trafficColumns() {
    return [
        { title: "Packets", numeric: true },
        { title: "Sent", numeric: true },
        { title: "Received", numeric: true },
        { title: "Total", numeric: true },
        { title: "Share", numeric: true },
        { title: "TCP Issues", numeric: true },
    ]
}

function trafficCells(totals, all) {
    var row = totals ? totals : {}
    var overall = all ? all : {}
    return [
        count(row.packets),
        bytes(row.sent_bytes),
        bytes(row.received_bytes),
        bytes(row.bytes),
        percent(row.bytes, overall.bytes),
        count(row.issue_packets),
    ]
}

function protocolMarkdown(data) {
    var rows = []
    var protocols = data.protocols ? data.protocols : []
    for (var i = 0; i < protocols.length; i++) {
        var row = protocols[i]
        var totals = row.totals ? row.totals : {}
        rows.push([
            row.title,
            count(totals.packets),
            bytes(totals.bytes),
            percent(totals.bytes, (data.totals ? data.totals.bytes : 0)),
        ])
    }
    return markdownTable("Protocols", [
        { title: "Protocol", numeric: false },
        { title: "Packets", numeric: true },
        { title: "Data", numeric: true },
        { title: "Share", numeric: true },
    ], rows)
}

function sourceMarkdown(title, nameTitle, rows, totals) {
    var tableRows = []
    var list = rows ? rows : []
    for (var i = 0; i < list.length; i++) {
        var row = list[i]
        tableRows.push([String(i + 1), row.title]
            .concat(trafficCells(row.totals, totals)))
    }
    return markdownTable(title, [
        { title: "#", numeric: true },
        { title: nameTitle, numeric: false },
    ].concat(trafficColumns()), tableRows)
}

function tcpAnalysisMarkdown(data) {
    var issues = data.tcp_issues ? data.tcp_issues : []
    var tcp = Number(data.tcp_packet_count) || 0
    if (issues.length === 0) {
        return "## TCP Analysis\n\n"
            + (tcp > 0
                ? "No TCP problems detected in " + count(tcp) + " TCP packets."
                : "No TCP traffic.") + "\n\n"
    }
    var rows = []
    for (var i = 0; i < issues.length; i++) {
        var issue = issues[i]
        var base = String(issue.kind) === "malformed"
            ? Number(data.totals ? data.totals.packets : 0) : tcp
        rows.push([
            issueLabel(issue.kind),
            count(issue.packets),
            percent(issue.packets, base),
            "`" + String(issue.filter || "") + "`",
        ])
    }
    return markdownTable("TCP Analysis", [
        { title: "Problem", numeric: false },
        { title: "Packets", numeric: true },
        { title: "Share", numeric: true },
        { title: "Wireshark filter", numeric: false },
    ], rows)
}

function conversationTransport(row) {
    if (row && row.transport)
        return String(row.transport)
    var key = String(row && row.key ? row.key : "")
    if (key.indexOf("udp") >= 0)
        return "udp"
    if (key.indexOf("icmp") >= 0)
        return "icmp"
    return "tcp"
}

function conversationsMarkdown(data) {
    var rows = []
    var list = data.top_conversations ? data.top_conversations : []
    for (var i = 0; i < list.length; i++) {
        var row = list[i]
        var client = String(row.client_address || "") + ":" + String(row.client_port || "")
        var server = String(row.server_address || "") + ":" + String(row.server_port || "")
        rows.push([String(i + 1), client, server,
                   conversationTransport(row),
                   row.domain_name || "\u2013",
                   row.app_name || "\u2013"]
            .concat(trafficCells(row.totals, data.totals)))
    }
    return markdownTable("Top Conversations", [
        { title: "#", numeric: true },
        { title: "Client", numeric: false },
        { title: "Server", numeric: false },
        { title: "Transport", numeric: false },
        { title: "Domain", numeric: false },
        { title: "App", numeric: false },
    ].concat(trafficColumns()), rows)
}

function servicesMarkdown(data) {
    var rows = []
    var list = data.top_services ? data.top_services : []
    for (var i = 0; i < list.length; i++) {
        var row = list[i]
        rows.push([String(i + 1),
                   String(row.port || "") + "/" + String(row.transport || ""),
                   row.service_name || "\u2013"]
            .concat(trafficCells(row.totals, data.totals)))
    }
    return markdownTable("Services & Ports", [
        { title: "#", numeric: true },
        { title: "Port", numeric: false },
        { title: "Service", numeric: false },
    ].concat(trafficColumns()), rows)
}

function packetLengthsMarkdown(data) {
    var rows = []
    var list = data.packet_lengths ? data.packet_lengths : []
    for (var i = 0; i < list.length; i++) {
        var value = Number(list[i]) || 0
        if (value > 0) {
            rows.push([lengthBucketTitle(i), count(value),
                       percent(value, data.totals ? data.totals.packets : 0)])
        }
    }
    return markdownTable("Packet Lengths", [
        { title: "Length", numeric: false },
        { title: "Packets", numeric: true },
        { title: "Share", numeric: true },
    ], rows)
}

function busiestMomentsMarkdown(data) {
    var points = data.timeline ? data.timeline.slice() : []
    var interval = Math.max(1, Number(data.timeline_interval_ms) || 1000)
    points.sort(function (lhs, rhs) {
        var lp = Number(lhs.totals ? lhs.totals.packets : 0) || 0
        var rp = Number(rhs.totals ? rhs.totals.packets : 0) || 0
        if (lp !== rp)
            return rp - lp
        return (Number(lhs.date_ms) || 0) - (Number(rhs.date_ms) || 0)
    })
    var rows = []
    for (var i = 0; i < points.length && rows.length < 5; i++) {
        var totals = points[i].totals ? points[i].totals : {}
        if ((Number(totals.packets) || 0) === 0)
            continue
        rows.push([
            clockTime(points[i].date_ms) + " (+" + span(interval) + ")",
            count(totals.packets),
            count(totals.issue_packets),
            bytes(totals.bytes),
            rate((Number(totals.bytes) || 0) / (interval / 1000)),
        ])
    }
    return markdownTable("Busiest Moments", [
        { title: "Time slot", numeric: false },
        { title: "Packets", numeric: true },
        { title: "TCP Issues", numeric: true },
        { title: "Data", numeric: true },
        { title: "Rate", numeric: true },
    ], rows)
}

// Full overview summary in the shape of the dashboard's cards. `cards` is the
// visible picker order, so the report matches what the user sees. `sourceLabel`
// is the header subtitle (basename or "Live on <iface>").
function summaryMarkdown(overview, sourceLabel, cards) {
    var data = overview ? overview : {}
    var totals = data.totals ? data.totals : {}
    var packets = Number(totals.packets) || 0
    var bytesCount = Number(totals.bytes) || 0
    var sent = Number(totals.sent_bytes) || 0
    var received = Number(totals.received_bytes) || 0
    var firstMs = Number(data.first_packet_ms) || 0
    var lastMs = Number(data.last_packet_ms) || 0
    var duration = Math.max(0, lastMs - firstMs)
    var spanSeconds = Math.max(0, duration / 1000)
    var pps = spanSeconds >= 1 ? packets / spanSeconds : 0
    var tcp = Number(data.tcp_packet_count) || 0
    var issuePackets = Number(totals.issue_packets) || 0

    var out = "# TCP Viewer Overview\n\n"
    if (sourceLabel && sourceLabel.length > 0)
        out += "_" + markdownEscape(sourceLabel) + "_\n\n"
    if (packets === 0) {
        out += "No packets were captured.\n"
        return out
    }

    out += "- Packets: " + count(packets)
        + (spanSeconds >= 1
            ? " (" + (pps >= 1 ? count(pps) : "<1") + " packets/s avg)"
            : "")
        + "\n"
    out += "- Data transferred: " + bytes(bytesCount)
    if (sent > 0 || received > 0)
        out += " (\u2191 " + bytes(sent) + " \u00b7 \u2193 " + bytes(received) + ")"
    out += "\n"
    out += "- Average throughput: " + rate(spanSeconds > 0 ? bytesCount / spanSeconds : 0)
        + " (" + span(duration) + " captured)\n"
    out += "- TCP packets: " + count(tcp)
        + (issuePackets > 0 ? " \u2014 " + count(issuePackets) + " flagged ("
                              + percent(issuePackets, tcp) + ")" : "")
        + "\n"
    out += "- Apps: " + count(Number(data.app_count) || 0)
        + " \u00b7 Domains: " + count(Number(data.domain_count) || 0) + "\n\n"

    var order = cards && cards.length > 0 ? cards : [
        "packets", "throughput", "protocols", "topApps", "topDestinations",
        "tcpAnalysis", "conversations", "services", "packetLengths",
    ]
    var activityDone = false
    for (var i = 0; i < order.length; i++) {
        var card = String(order[i])
        if (card === "packets" || card === "throughput") {
            if (!activityDone) {
                activityDone = true
                out += busiestMomentsMarkdown(data)
            }
        } else if (card === "protocols") {
            out += protocolMarkdown(data)
        } else if (card === "topApps") {
            out += sourceMarkdown("Top Apps", "App", data.top_apps, totals)
        } else if (card === "topDestinations") {
            out += sourceMarkdown("Top Domains & IPs", "Destination",
                                 data.top_destinations, totals)
        } else if (card === "tcpAnalysis") {
            out += tcpAnalysisMarkdown(data)
        } else if (card === "conversations") {
            out += conversationsMarkdown(data)
        } else if (card === "services") {
            out += servicesMarkdown(data)
        } else if (card === "packetLengths") {
            out += packetLengthsMarkdown(data)
        }
    }
    return out
}

