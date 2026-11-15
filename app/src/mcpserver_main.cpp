// omarchy-tcpviewer-mcp: MCP stdio server for the running app (upstream's
// tcpviewer-mcp helper). Speaks newline-delimited JSON-RPC 2.0 on stdin/stdout
// and forwards tool calls to the app's local command bridge (app.sock), the
// same schema_version 1 surface the CLI uses. The helper is launched by MCP
// clients (claude mcp add --transport stdio --scope user tcpviewer -- …).
// PRO gating upstream; this port is free (audit: known N/A).
#include <QCoreApplication>
#include <QDateTime>
#include <QDeadlineTimer>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QLocalSocket>
#include <QRandomGenerator>
#include <QVector>

#include <cstdio>
#include <iostream>
#include <optional>
#include <string>

namespace {

constexpr int kBridgeTimeoutMs = 30 * 1000;

QString defaultSocketPath()
{
    const QString override = qEnvironmentVariable("TCPVIEWER_APP_SOCKET");
    if (!override.isEmpty())
        return override;
    const QString runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
    if (runtime.isEmpty())
        return {};
    return runtime + QStringLiteral("/omarchy-tcpviewer/app.sock");
}

// One request over an open bridge connection.
std::optional<QJsonObject> bridgeRequestOn(QLocalSocket &socket, const QString &command,
                                           const QJsonObject &params,
                                           QString *errorCode, QString *errorMessage)
{
    const QJsonObject envelope{
        {QStringLiteral("schema_version"), 1},
        {QStringLiteral("request_id"),
            QString::number(QDateTime::currentMSecsSinceEpoch(), 16)
                + QStringLiteral("-%1").arg(QRandomGenerator::system()->generate() & 0xffff)},
        {QStringLiteral("command"), command},
        {QStringLiteral("params"), params},
    };
    socket.write(QJsonDocument(envelope).toJson(QJsonDocument::Compact) + '\n');
    socket.flush();
    QDeadlineTimer deadline(kBridgeTimeoutMs);
    while (!socket.canReadLine()) {
        if (deadline.hasExpired()
            || !socket.waitForReadyRead(deadline.remainingTime())) {
            *errorCode = QStringLiteral("app_timeout");
            *errorMessage = QStringLiteral("app bridge did not answer in time");
            return std::nullopt;
        }
    }
    return QJsonDocument::fromJson(socket.readLine()).object();
}

// Connects to the app bridge and answers one tool's bridge exchange. Each
// connection announces itself as an MCP client first (mcp.hello): the app
// enforces the Enable MCP Server setting and marks the connection so its
// redaction policy applies.
std::optional<QJsonObject> callBridge(const QString &socketPath, const QString &command,
                                      const QJsonObject &params, QJsonObject *result,
                                      QString *errorMessage)
{
    QLocalSocket socket;
    socket.connectToServer(socketPath);
    if (!socket.waitForConnected(3000)) {
        *errorMessage = QStringLiteral("omarchy-tcpviewer is not running");
        return std::nullopt;
    }
    QString errorCode;
    const std::optional<QJsonObject> hello = bridgeRequestOn(socket,
        QStringLiteral("mcp.hello"), {}, &errorCode, errorMessage);
    if (!hello)
        return std::nullopt;
    if (!hello->value(QStringLiteral("ok")).toBool()) {
        const QJsonObject error = hello->value(QStringLiteral("error")).toObject();
        *errorMessage = error.value(QStringLiteral("message")).toString();
        if (errorMessage->isEmpty())
            *errorMessage = QStringLiteral("bridge error");
        return std::nullopt;
    }
    const std::optional<QJsonObject> reply = bridgeRequestOn(socket, command, params,
                                                             &errorCode, errorMessage);
    if (!reply)
        return std::nullopt;
    if (!reply->value(QStringLiteral("ok")).toBool()) {
        const QJsonObject error = reply->value(QStringLiteral("error")).toObject();
        *errorMessage = error.value(QStringLiteral("message")).toString();
        if (errorMessage->isEmpty())
            *errorMessage = QStringLiteral("bridge error");
        return std::nullopt;
    }
    *result = reply->value(QStringLiteral("data")).toObject();
    return reply;
}

// --- tool table (upstream docs/mcp §4; the bridge-covered subset) ---

struct Tool {
    const char *name;
    const char *description;
    QJsonObject schema;
};

QJsonObject objectSchema(QJsonObject properties, QJsonArray required)
{
    return QJsonObject{
        {QStringLiteral("type"), QStringLiteral("object")},
        {QStringLiteral("properties"), properties},
        {QStringLiteral("required"), required},
    };
}

QJsonObject stringProperty(const char *description)
{
    return QJsonObject{{QStringLiteral("type"), QStringLiteral("string")},
        {QStringLiteral("description"), QString::fromUtf8(description)}};
}

QJsonObject boolProperty(const char *description)
{
    return QJsonObject{{QStringLiteral("type"), QStringLiteral("boolean")},
        {QStringLiteral("description"), QString::fromUtf8(description)}};
}

QJsonObject integerProperty(const char *description, int minimum)
{
    return QJsonObject{{QStringLiteral("type"), QStringLiteral("integer")},
        {QStringLiteral("description"), QString::fromUtf8(description)},
        {QStringLiteral("minimum"), minimum}};
}

const QVector<Tool> &tools()
{
    static const QVector<Tool> table = {
        {"get_app_status",
            "App and capture state, tab count, and daemon connection.",
            objectSchema({}, {})},
        {"list_workspaces",
            "Lists open app windows (this port serves one workspace per app instance).",
            objectSchema({}, {})},
        {"list_tabs",
            "Lists workspace tabs in order with the selected tab, per-tab source, filter, and split state.",
            objectSchema({}, {})},
        {"create_tab",
            "Creates a tab seeded from the shared workspace view. Leaves it unselected unless select=true.",
            objectSchema(QJsonObject{
                {QStringLiteral("label"), stringProperty("Optional tab label (file-import naming)")},
                {QStringLiteral("select"), boolProperty("Select the new tab (default false)")}},
                {})},
        {"select_tab",
            "Selects the target tab.",
            objectSchema(QJsonObject{
                {QStringLiteral("tab_id"), stringProperty("Tab id from list_tabs")}},
                {QStringLiteral("tab_id")})},
        {"move_tab",
            "Moves a tab to a zero-based index.",
            objectSchema(QJsonObject{
                {QStringLiteral("tab_id"), stringProperty("Tab id from list_tabs")},
                {QStringLiteral("to"), integerProperty("Zero-based destination index", 0)}},
                {QStringLiteral("tab_id"), QStringLiteral("to")})},
        {"close_tab",
            "Closes a tab (or the active tab without tab_id). Requires confirm=true; closing the last tab reports window_closed.",
            objectSchema(QJsonObject{
                {QStringLiteral("tab_id"), stringProperty("Tab id from list_tabs (default: active tab)")},
                {QStringLiteral("confirm"), boolProperty("Must be true to close a tab")}},
                {QStringLiteral("confirm")})},
        {"get_pane",
            "Reads a pane's tab state (source, filters, selected packet, mode, split). Panes are 0 (primary) and 1 (secondary).",
            objectSchema(QJsonObject{
                {QStringLiteral("pane"), integerProperty("0 or 1 (default 0)", 0)}},
                {})},
        {"set_split_view",
            "Enables or disables the second pane of the active tab.",
            objectSchema(QJsonObject{
                {QStringLiteral("enabled"), boolProperty("Enable the split pane")}},
                {QStringLiteral("enabled")})},
        {"focus_pane",
            "Focuses a pane of the active tab (routes inspector fetches).",
            objectSchema(QJsonObject{
                {QStringLiteral("pane"), integerProperty("0 or 1 (default 0)", 0)}},
                {})},
        {"get_overview_statistics",
            "Full-source Overview totals, protocol breakdown, and timeline for the active tab's source.",
            objectSchema({}, {})},
        {"get_endpoint_statistics",
            "Endpoint statistics (apps, domains, ipv4, ipv6, tcp, udp) with search, sorting, and pagination. The tcp and udp groups need endpoint attribution that imports do not carry in this port.",
            objectSchema(QJsonObject{
                {QStringLiteral("group"),
                    QJsonObject{{QStringLiteral("type"), QStringLiteral("string")},
                        {QStringLiteral("enum"), QJsonArray{QStringLiteral("apps"),
                            QStringLiteral("domains"), QStringLiteral("ipv4"),
                            QStringLiteral("ipv6"), QStringLiteral("tcp"), QStringLiteral("udp")}},
                        {QStringLiteral("description"), QString::fromUtf8("Default apps")}}},
                {QStringLiteral("search"), stringProperty("Filter rows (all terms contained)")},
                {QStringLiteral("sort"), stringProperty("Column: address, port, protocol, client, domain, packets, bytes, tx_packets, tx_bytes, rx_packets, rx_bytes, summary (default bytes)")},
                {QStringLiteral("order"), stringProperty("desc (default) or asc")},
                {QStringLiteral("offset"), integerProperty("Row offset for pagination", 0)},
                {QStringLiteral("limit"), integerProperty("Rows per page, at most 500 (default 50)", 1)}},
                {})},
        {"query_packets",
            "Bounded window of the pane's loaded packet rows (the packet table's page). Use reveal_packet to select one.",
            objectSchema(QJsonObject{
                {QStringLiteral("offset"), integerProperty("Row offset", 0)},
                {QStringLiteral("limit"), integerProperty("Rows, at most 500 (default 50)", 1)}},
                {})},
        {"reveal_packet",
            "Selects a packet in the app and brings the window forward.",
            objectSchema(QJsonObject{
                {QStringLiteral("packet_id"), stringProperty("Packet id from query_packets")},
                {QStringLiteral("packet_number"), stringProperty("Alternative: packet number")},
                {QStringLiteral("id"), stringProperty("Deprecated alias for packet_id")}},
                {})},
    };
    return table;
}

// --- bridge mapping ---

// MCP tool results: text content carrying the JSON payload (ok) or the
// error text (isError).
QJsonObject toolOk(const QJsonValue &data)
{
    QJsonArray content;
    content.append(QJsonObject{{QStringLiteral("type"), QStringLiteral("text")},
        {QStringLiteral("text"),
            QString::fromUtf8(QJsonDocument(data.toObject()).toJson(QJsonDocument::Compact))}});
    return QJsonObject{
        {QStringLiteral("content"), content},
        {QStringLiteral("isError"), false},
    };
}

QJsonObject toolError(const QString &text)
{
    QJsonArray content;
    content.append(QJsonObject{{QStringLiteral("type"), QStringLiteral("text")},
        {QStringLiteral("text"), text}});
    return QJsonObject{
        {QStringLiteral("content"), content},
        {QStringLiteral("isError"), true},
    };
}

QJsonObject callTool(const QString &socketPath, const QString &name,
                     const QJsonObject &arguments)
{
    QString errorMessage;
    QJsonObject data;

    if (name == QLatin1String("get_app_status")) {
        if (!callBridge(socketPath, QStringLiteral("app.status"), {}, &data, &errorMessage))
            return toolError(errorMessage);
        return toolOk(data);
    }
    if (name == QLatin1String("list_workspaces")) {
        if (!callBridge(socketPath, QStringLiteral("app.status"), {}, &data, &errorMessage))
            return toolError(errorMessage);
        QJsonObject workspace{
            {QStringLiteral("workspace_id"), QStringLiteral("app")},
            {QStringLiteral("title"), QStringLiteral("Omarchy TCP Viewer")},
            {QStringLiteral("tab_count"), data.value(QStringLiteral("tabs"))},
            {QStringLiteral("selected_tab"), data.value(QStringLiteral("active_tab"))},
        };
        QJsonArray workspaces;
        workspaces.append(workspace);
        return toolOk(QJsonObject{{QStringLiteral("workspaces"), workspaces}});
    }
    if (name == QLatin1String("list_tabs")) {
        if (!callBridge(socketPath, QStringLiteral("tabs.list"), {}, &data, &errorMessage))
            return toolError(errorMessage);
        return toolOk(data);
    }
    if (name == QLatin1String("create_tab")) {
        QJsonObject params;
        if (arguments.contains(QStringLiteral("label")))
            params.insert(QStringLiteral("label"), arguments.value(QStringLiteral("label")));
        params.insert(QStringLiteral("select"),
                      arguments.value(QStringLiteral("select")).toBool(false));
        if (!callBridge(socketPath, QStringLiteral("tabs.create"), params, &data, &errorMessage))
            return toolError(errorMessage);
        return toolOk(data);
    }
    if (name == QLatin1String("select_tab")) {
        QJsonObject params{{QStringLiteral("tab_id"),
            arguments.value(QStringLiteral("tab_id")).toString()}};
        if (!callBridge(socketPath, QStringLiteral("tabs.select"), params, &data, &errorMessage))
            return toolError(errorMessage);
        return toolOk(data);
    }
    if (name == QLatin1String("move_tab")) {
        QJsonObject params{
            {QStringLiteral("tab_id"), arguments.value(QStringLiteral("tab_id")).toString()},
            {QStringLiteral("to"), arguments.value(QStringLiteral("to")).toInt(-1)}};
        if (!callBridge(socketPath, QStringLiteral("tabs.move"), params, &data, &errorMessage))
            return toolError(errorMessage);
        return toolOk(data);
    }
    if (name == QLatin1String("close_tab")) {
        // Upstream requires confirm=true for close_tab (and clearing packets).
        if (!arguments.value(QStringLiteral("confirm")).toBool(false))
            return toolError(
                QStringLiteral("confirm=true required to close a tab"));
        QJsonObject params{{QStringLiteral("tab_id"),
            arguments.value(QStringLiteral("tab_id")).toString()}};
        if (!callBridge(socketPath, QStringLiteral("tabs.close"), params, &data, &errorMessage))
            return toolError(errorMessage);
        return toolOk(data);
    }
    if (name == QLatin1String("get_pane")) {
        QJsonObject params{{QStringLiteral("pane"),
            arguments.contains(QStringLiteral("pane"))
                ? arguments.value(QStringLiteral("pane"))
                : QJsonValue(0)}};
        if (!callBridge(socketPath, QStringLiteral("pane.get"), params, &data, &errorMessage))
            return toolError(errorMessage);
        return toolOk(data);
    }
    if (name == QLatin1String("set_split_view")) {
        QJsonObject params{{QStringLiteral("enabled"),
            arguments.value(QStringLiteral("enabled")).toBool(false)}};
        if (!callBridge(socketPath, QStringLiteral("tabs.set_split"), params, &data, &errorMessage))
            return toolError(errorMessage);
        return toolOk(data);
    }
    if (name == QLatin1String("focus_pane")) {
        QJsonObject params{{QStringLiteral("pane"),
            arguments.contains(QStringLiteral("pane"))
                ? arguments.value(QStringLiteral("pane"))
                : QJsonValue(0)}};
        if (!callBridge(socketPath, QStringLiteral("pane.focus"), params, &data, &errorMessage))
            return toolError(errorMessage);
        return toolOk(data);
    }
    if (name == QLatin1String("get_overview_statistics")) {
        if (!callBridge(socketPath, QStringLiteral("overview.get"), {}, &data, &errorMessage))
            return toolError(errorMessage);
        return toolOk(data);
    }
    if (name == QLatin1String("get_endpoint_statistics")) {
        // The tcp/udp groups need endpoint attribution the fixture imports do
        // not carry; the app's statistics model still answers what it has.
        QJsonObject params;
        for (const char *key : {"group", "search", "sort", "order", "offset", "limit"})
            if (arguments.contains(QLatin1String(key)))
                params.insert(QLatin1String(key), arguments.value(QLatin1String(key)));
        if (!callBridge(socketPath, QStringLiteral("statistics.endpoints"), params, &data, &errorMessage))
            return toolError(errorMessage);
        return toolOk(data);
    }
    if (name == QLatin1String("query_packets")) {
        QJsonObject params;
        for (const char *key : {"offset", "limit"})
            if (arguments.contains(QLatin1String(key)))
                params.insert(QLatin1String(key), arguments.value(QLatin1String(key)));
        if (!callBridge(socketPath, QStringLiteral("packets.query"), params, &data, &errorMessage))
            return toolError(errorMessage);
        return toolOk(data);
    }
    if (name == QLatin1String("reveal_packet")) {
        QString packetID = arguments.value(QStringLiteral("packet_id")).toString();
        if (packetID.isEmpty())
            packetID = arguments.value(QStringLiteral("packet_number")).toString();
        if (packetID.isEmpty())
            packetID = arguments.value(QStringLiteral("id")).toString();
        if (packetID.isEmpty())
            return toolError(QStringLiteral("packet_id required"));
        QJsonObject params{{QStringLiteral("packet_id"), packetID}};
        if (!callBridge(socketPath, QStringLiteral("packets.reveal"), params, &data, &errorMessage))
            return toolError(errorMessage);
        return toolOk(data);
    }

    // Unreachable through tools/list, but keep the boundary explicit.
    return toolError(QStringLiteral("unknown tool: %1").arg(name));
}

QJsonArray toolList()
{
    QJsonArray list;
    for (const Tool &tool : tools()) {
        list.append(QJsonObject{
            {QStringLiteral("name"), QString::fromUtf8(tool.name)},
            {QStringLiteral("description"), QString::fromUtf8(tool.description)},
            {QStringLiteral("inputSchema"), tool.schema},
        });
    }
    return list;
}

// One JSON-RPC request/notification; writes a reply for requests.
void handleRpcLine(const QByteArray &line, const QString &socketPath)
{
    const QJsonObject message = QJsonDocument::fromJson(line).object();
    if (message.isEmpty()) {
        const QJsonObject error{{QStringLiteral("jsonrpc"), QStringLiteral("2.0")},
            {QStringLiteral("id"), QJsonValue::Null},
            {QStringLiteral("error"), QJsonObject{
                {QStringLiteral("code"), -32700},
                {QStringLiteral("message"), QStringLiteral("Parse error")}}}};
        std::cout << QJsonDocument(error).toJson(QJsonDocument::Compact).toStdString() << '\n';
        return;
    }

    const QString method = message.value(QStringLiteral("method")).toString();
    const QJsonValue id = message.value(QStringLiteral("id"));
    const bool isRequest = !id.isUndefined() && !id.isNull();
    const QJsonObject params = message.value(QStringLiteral("params")).toObject();

    if (method == QLatin1String("notifications/initialized")
        || method == QLatin1String("notifications/cancelled")) {
        return;
    }

    QJsonObject replyBody;
    bool isError = false;
    if (method == QLatin1String("initialize")) {
        // Accept the client's protocol version when we know it.
        const QString requested = params.value(QStringLiteral("protocolVersion")).toString();
        const QString version = (requested == QLatin1String("2024-11-05")
            || requested == QLatin1String("2025-06-18"))
            ? requested
            : QStringLiteral("2025-06-18");
        replyBody = QJsonObject{
            {QStringLiteral("protocolVersion"), version},
            {QStringLiteral("capabilities"), QJsonObject{
                {QStringLiteral("tools"), QJsonObject{}}}},
            {QStringLiteral("serverInfo"), QJsonObject{
                {QStringLiteral("name"), QStringLiteral("tcpviewer")},
                {QStringLiteral("title"), QStringLiteral("Omarchy TCP Viewer")},
                {QStringLiteral("version"), QStringLiteral("0.1.0")}}},
        };
    } else if (method == QLatin1String("ping")) {
        replyBody = QJsonObject{};
    } else if (method == QLatin1String("tools/list")) {
        replyBody = QJsonObject{{QStringLiteral("tools"), toolList()}};
    } else if (method == QLatin1String("tools/call")) {
        const QString name = params.value(QStringLiteral("name")).toString();
        bool known = false;
        for (const Tool &tool : tools())
            known |= name == QLatin1String(tool.name);
        if (!known) {
            isError = true;
            replyBody = QJsonObject{{QStringLiteral("code"), -32602},
                {QStringLiteral("message"), QStringLiteral("Unknown tool: %1").arg(name)}};
        } else {
            replyBody = callTool(socketPath, name,
                                 params.value(QStringLiteral("arguments")).toObject());
        }
    } else if (isRequest) {
        isError = true;
        replyBody = QJsonObject{{QStringLiteral("code"), -32601},
            {QStringLiteral("message"), QStringLiteral("Method not found: %1").arg(method)}};
    } else {
        return; // unknown notification
    }

    if (!isRequest)
        return; // reply bodies for notifications make no sense
    QJsonObject reply{{QStringLiteral("jsonrpc"), QStringLiteral("2.0")}, {QStringLiteral("id"), id}};
    if (isError) {
        reply.insert(QStringLiteral("error"), replyBody);
    } else {
        reply.insert(QStringLiteral("result"), replyBody);
    }
    std::cout << QJsonDocument(reply).toJson(QJsonDocument::Compact).toStdString() << '\n'
              << std::flush;
}

} // namespace

int main(int argc, char *argv[])
{
    QCoreApplication app(argc, argv);
    QCoreApplication::setApplicationName(QStringLiteral("omarchy-tcpviewer-mcp"));
    QString socketPath = defaultSocketPath();
    const QStringList arguments = app.arguments();
    for (int i = 1; i < arguments.size(); ++i) {
        if (arguments.at(i) == QLatin1String("--socket") && i + 1 < arguments.size())
            socketPath = arguments.at(i + 1);
    }

    std::string line;
    while (std::getline(std::cin, line)) {
        if (line.empty())
            continue;
        handleRpcLine(QByteArray::fromStdString(line), socketPath);
    }
    return 0;
}
