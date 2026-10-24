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
