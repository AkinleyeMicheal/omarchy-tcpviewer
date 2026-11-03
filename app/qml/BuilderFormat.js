// BuilderFormat.js — shared structured-builder vocabulary for the builder
// popup (QuickFilterBar.qml) and the sidebar's saved preset rows
// (Sidebar.qml). Field ids / condition ids are the daemon's structured IPC
// contract (upstream PacketStructuredFilterQuery / Condition enums); upstream
// supports numeric comparison only on fields that expose numbers.

var FIELDS = [
    { id: "urlDomain", label: "URL/Domain", kind: "text", hint: "example.com" },
    { id: "protocol", label: "Protocol", kind: "text", hint: "tcp, udp, tls…" },
    { id: "source", label: "Source", kind: "text", hint: "10.0.0.5 or 10.0.0.5:53000" },
    { id: "destination", label: "Destination", kind: "text", hint: "203.0.113.10 or host:443" },
    { id: "sourcePort", label: "Source Port", kind: "numeric", hint: "443" },
    { id: "destinationPort", label: "Dest. Port", kind: "numeric", hint: "443" },
    { id: "client", label: "Client", kind: "text", hint: "process name" },
    { id: "pid", label: "PID", kind: "numeric", hint: "4242" },
    { id: "bundleIdentifier", label: "Bundle ID", kind: "text", hint: "com.example.app" },
    { id: "streamID", label: "Stream ID", kind: "numeric", hint: "7" },
    { id: "direction", label: "Direction", kind: "text", hint: "inbound, outbound, local" },
    { id: "tcpFlags", label: "TCP Flags", kind: "text", hint: "SYN, ACK" },
    { id: "tcpPayload", label: "TCP Payload", kind: "numeric", hint: "payload bytes" },
    { id: "decodeStatus", label: "Decode Status", kind: "text", hint: "complete, partial, malformed" },
    { id: "interface", label: "Interface", kind: "text", hint: "eth0" },
    { id: "length", label: "Length", kind: "numeric", hint: "1400" },
    { id: "summary", label: "Summary", kind: "text", hint: "info summary text" },
    { id: "tags", label: "Tags", kind: "text", hint: "Truncated, Partial, Malformed" }
]

// Upstream PacketStructuredFilterCondition order; < and >= ride along only
// on numeric fields (upstream supportsNumericComparison).
var CONDITIONS = [
    { id: "contains", label: "Contains" },
    { id: "notContains", label: "Not Contains" },
    { id: "hasPrefix", label: "Has Prefix" },
    { id: "notHasPrefix", label: "Not Has Prefix" },
    { id: "hasSuffix", label: "Has Suffix" },
    { id: "notHasSuffix", label: "Not Has Suffix" },
    { id: "lessThan", label: "<" },
    { id: "greaterThanOrEqual", label: ">=" },
    { id: "matchesRegex", label: "Match Regex" },
    { id: "notMatchesRegex", label: "Not Match Regex" }
]

function fieldById(id) {
    for (var i = 0; i < FIELDS.length; ++i) {
        if (FIELDS[i].id === id)
            return FIELDS[i]
    }
    return FIELDS.length > 0 ? FIELDS[0] : null
}

function conditionsFor(fieldId) {
    var field = fieldById(fieldId)
    if (!field)
        return []
    return CONDITIONS.filter(function (condition) {
        if (condition.id === "lessThan" || condition.id === "greaterThanOrEqual")
            return field.kind === "numeric"
        return true
    })
}

function conditionById(fieldId, conditionId) {
    var conditions = conditionsFor(fieldId)
    for (var i = 0; i < conditions.length; ++i) {
        if (conditions[i].id === conditionId)
            return conditions[i]
    }
    return conditions.length > 0 ? conditions[0] : null
}

// Records use the IPC shape: {field, condition, text, enabled}.
function rowSummary(record) {
    var field = fieldById(record.field)
    var condition = conditionById(record.field, record.condition)
    var value = String(record.text || "").trim()
    if (!record || !field || !condition || value.length === 0)
        return ""
    var text = field.label + " " + condition.label + ' "' + value + '"'
    return record.enabled === false ? text + " (disabled)" : text
}

// The controller receives rows regardless; disabled or blank rows contribute
// nothing (upstream isActive = enabled && non-empty).
function summaryFor(records, join) {
    var parts = []
    for (var i = 0; i < records.length; ++i) {
        var summary = rowSummary(records[i])
        if (summary.length > 0)
            parts.push(summary)
    }
    if (parts.length === 0)
        return ""
    return parts.join(join === "or" ? " OR " : " AND ")
}

// Short sidebar label: first row summary, elided by Text, with a row count.
function presetLabel(records) {
    for (var i = 0; i < records.length; ++i) {
        var summary = rowSummary(records[i])
        if (summary.length > 0)
            return summary
    }
    return records.length > 0 ? records.length + " conditions" : "Empty preset"
}
