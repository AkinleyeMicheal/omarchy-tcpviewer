#include "appcommandserver.h"

#include "endpointstatsmodel.h"
#include "packetmodel.h"
#include "sessioncontroller.h"
#include "sourcetreemodel.h"
#include "workspacetabscontroller.h"

#include <QDir>
#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QSettings>
#ifdef Q_OS_UNIX
#include <sys/socket.h>
#include <unistd.h>
#endif

namespace {

QString defaultSocketPath()
{
    const QString override = qEnvironmentVariable("TCPVIEWER_APP_SOCKET");
    if (!override.isEmpty())
        return override;
    const QString runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
    if (runtime.isEmpty())
        return QString();
    return runtime + QStringLiteral("/omarchy-tcpviewer/app.sock");
}

QJsonObject toJsonObject(const QVariantMap &map)
{
    return QJsonObject::fromVariantMap(map);
}

QVariantMap tabsRow(WorkspaceTabsController *tabs, int index)
{
    const QModelIndex modelIndex = tabs->index(index);
    QVariantMap row;
    row.insert(QStringLiteral("id"), tabs->data(modelIndex, WorkspaceTabsController::IdRole));
    row.insert(QStringLiteral("label"), tabs->data(modelIndex, WorkspaceTabsController::LabelRole));
    row.insert(QStringLiteral("split_visible"), tabs->data(modelIndex, WorkspaceTabsController::SplitVisibleRole));
    row.insert(QStringLiteral("source_id"), tabs->data(modelIndex, WorkspaceTabsController::SourceIdRole));
    row.insert(QStringLiteral("tree_filter"), tabs->data(modelIndex, WorkspaceTabsController::TreeFilterRole));
    row.insert(QStringLiteral("filter_text"), tabs->data(modelIndex, WorkspaceTabsController::FilterTextRole));
    row.insert(QStringLiteral("selected_packet_id"), tabs->data(modelIndex, WorkspaceTabsController::SelectedPacketIdRole));
    row.insert(QStringLiteral("capture_mode"), tabs->data(modelIndex, WorkspaceTabsController::CaptureModeRole));
    return row;
}

int tabIndexByID(WorkspaceTabsController *tabs, const QString &tabID)
{
    for (int i = 0; i < tabs->count(); ++i) {
        if (tabs->tabID(i) == tabID)
            return i;
    }
    return -1;
}

// --- MCP settings (upstream Settings → MCP; the settings UI lands with F4) ---

bool parseBoolText(const QString &text, bool *ok)
{
    const QString normalized = text.trimmed().toLower();
    *ok = normalized == QLatin1String("1") || normalized == QLatin1String("true")
        || normalized == QLatin1String("yes") || normalized == QLatin1String("on")
        || normalized == QLatin1String("0") || normalized == QLatin1String("false")
        || normalized == QLatin1String("no") || normalized == QLatin1String("off");
    if (!*ok)
        return false;
    return normalized == QLatin1String("1") || normalized == QLatin1String("true")
        || normalized == QLatin1String("yes") || normalized == QLatin1String("on");
}

// Env overrides (CI/smoke) win over the stored settings.
bool mcpEnabled()
{
    bool ok = false;
    const QString env = qEnvironmentVariable("TCPVIEWER_MCP_ENABLED");
    if (!env.isEmpty() && parseBoolText(env, &ok))
        return ok;
    return QSettings().value(QStringLiteral("mcp/enabled"), false).toBool();
}

bool mcpRedaction()
{
    bool ok = false;
    const QString env = qEnvironmentVariable("TCPVIEWER_MCP_REDACTION");
    if (!env.isEmpty() && parseBoolText(env, &ok))
        return ok;
    // Upstream default: keep redaction enabled unless there is a clear reason.
    return QSettings().value(QStringLiteral("mcp/redaction"), true).toBool();
}

QString normalizedSettingKey(const QString &key)
{
    QString normalized;
    normalized.reserve(key.size());
    for (const QChar &character : key) {
        const char16_t code = character.toLower().unicode();
        if (code == '-' || code == '_' || code == ' ')
            continue;
        normalized.append(QChar(code));
    }
    return normalized;
}

bool isSensitiveKey(const QString &key)
{
    static const QSet<QString> sensitive = {
        QStringLiteral("authorization"), QStringLiteral("proxyauthorization"),
        QStringLiteral("wwwauthenticate"), QStringLiteral("cookie"),
        QStringLiteral("setcookie"), QStringLiteral("password"), QStringLiteral("passwd"),
        QStringLiteral("pwd"), QStringLiteral("secret"), QStringLiteral("token"),
        QStringLiteral("accesstoken"), QStringLiteral("refreshtoken"),
        QStringLiteral("idtoken"), QStringLiteral("apikey"), QStringLiteral("privatekey"),
        QStringLiteral("credential"), QStringLiteral("credentials"),
        QStringLiteral("sessionkey"), QStringLiteral("authkey"),
    };
    return sensitive.contains(normalizedSettingKey(key));
}

} // namespace

AppCommandServer::AppCommandServer(QObject *parent)
    : QObject(parent)
{
    m_socketPath = defaultSocketPath();
    connect(&m_server, &QLocalServer::newConnection, this,
            &AppCommandServer::handleConnection);
}

AppCommandServer::~AppCommandServer()
{
    close();
}

QString AppCommandServer::socketPath() const
{
    return m_socketPath;
}

void AppCommandServer::setSocketPath(const QString &path)
{
    if (m_socketPath == path)
        return;
    m_socketPath = path;
    emit socketPathChanged();
}

bool AppCommandServer::listen()
{
    close();
    if (m_socketPath.isEmpty())
        return false;
    // A crashed instance leaves a socket file behind; the newest instance
    // takes it over.
    QLocalServer::removeServer(m_socketPath);
    const QString dir = m_socketPath.left(m_socketPath.lastIndexOf(QLatin1Char('/')));
    if (!dir.isEmpty() && !QDir().mkpath(dir))
        return false;
    if (!m_server.listen(m_socketPath)) {
        qWarning() << "app command bridge failed to listen on" << m_socketPath
                   << m_server.errorString();
        return false;
    }
    return true;
}

void AppCommandServer::close()
{
    if (m_server.isListening())
        m_server.close();
}

void AppCommandServer::handleConnection()
{
    while (QLocalSocket *socket = m_server.nextPendingConnection()) {
#ifdef Q_OS_UNIX
        // Upstream's MCP bridge is localhost-only with a per-launch key; the
        // runtime-dir socket is already user-scoped, and this check makes the
        // same guarantee kernel-enforced: only the owning user connects.
        const qintptr descriptor = socket->socketDescriptor();
        if (descriptor != -1) {
            struct ucred credentials {};
            socklen_t length = sizeof(credentials);
            if (getsockopt(descriptor, SOL_SOCKET, SO_PEERCRED, &credentials, &length) == 0
                && credentials.uid != getuid()) {
                socket->abort();
                continue;
            }
        }
#endif
        connect(socket, &QLocalSocket::disconnected, socket, &QLocalSocket::deleteLater);
        handleReadyRead(socket);
        connect(socket, &QLocalSocket::readyRead, this, [this, socket]() {
            handleReadyRead(socket);
        });
    }
}

void AppCommandServer::handleReadyRead(QLocalSocket *socket)
{
    while (socket->canReadLine()) {
        const QByteArray line = socket->readLine();
        if (line.trimmed().isEmpty())
            continue;
        const QJsonObject request = QJsonDocument::fromJson(line).object();
        const QString requestID = request.value(QStringLiteral("request_id")).toString();
        const QString command = request.value(QStringLiteral("command")).toString();
        const int schemaVersion = request.value(QStringLiteral("schema_version")).toInt(-1);
        if (schemaVersion != 1) {
            sendError(socket, requestID, command, QStringLiteral("unsupported_schema"),
                      QStringLiteral("schema_version %1 not supported (want 1)").arg(schemaVersion));
            continue;
        }
        if (requestID.isEmpty()) {
            sendError(socket, requestID, command, QStringLiteral("invalid_request"),
                      QStringLiteral("request_id missing"));
            continue;
        }
        if (command.isEmpty()) {
            sendError(socket, requestID, command, QStringLiteral("invalid_request"),
                      QStringLiteral("missing command"));
            continue;
        }
        dispatch(socket, requestID, command,
                 request.value(QStringLiteral("params")).toObject().toVariantMap());
    }
}

void AppCommandServer::dispatch(QLocalSocket *socket, const QString &requestID,
                                const QString &command, const QVariantMap &params)
{
    SessionController *session = qobject_cast<SessionController *>(parent());
    if (!session) {
        sendError(socket, requestID, command, QStringLiteral("app_command_failed"),
                  QStringLiteral("no session"));
        return;
    }
    WorkspaceTabsController *tabs = session->tabs();

    // MCP helper connections announce themselves once; the announce both
    // marks the connection (redaction, confirm policies) and enforces the
    // Enable MCP Server setting (upstream Settings → MCP).
    if (command == QLatin1String("mcp.hello")) {
        if (!mcpEnabled()) {
            sendError(socket, requestID, command, QStringLiteral("not_enabled"),
                      QStringLiteral("MCP server is disabled in omarchy-tcpviewer settings"));
            return;
        }
        socket->setProperty("mcp", true);
        QVariantMap result{
            {QStringLiteral("app"), QStringLiteral("omarchy-tcpviewer")},
            {QStringLiteral("protocol"), 1},
            {QStringLiteral("redaction"), mcpRedaction()},
        };
        sendResult(socket, requestID, command, result);
        return;
    }
    if (socket->property("mcp").toBool() && !mcpEnabled()) {
        sendError(socket, requestID, command, QStringLiteral("not_enabled"),
                  QStringLiteral("MCP server is disabled in omarchy-tcpviewer settings"));
        return;
    }

    if (command == QLatin1String("app.status")) {
        QVariantMap result;
        result.insert(QStringLiteral("app"), QStringLiteral("omarchy-tcpviewer"));
        result.insert(QStringLiteral("tabs"), tabs->count());
        result.insert(QStringLiteral("active_tab"),
                      tabs->activeTab() >= 0 ? tabs->tabID(tabs->activeTab()) : QString());
        result.insert(QStringLiteral("mode"), tabs->activeCaptureMode());
        result.insert(QStringLiteral("source_id"), session->currentSourceID());
        result.insert(QStringLiteral("daemon_connected"), session->connected());
        sendResult(socket, requestID, command, result);
        return;
    }
    if (command == QLatin1String("tabs.list")) {
        QVariantList rows;
        for (int i = 0; i < tabs->count(); ++i)
            rows.append(tabsRow(tabs, i));
        QVariantMap result;
        result.insert(QStringLiteral("active_tab"),
                      tabs->activeTab() >= 0 ? tabs->tabID(tabs->activeTab()) : QString());
        result.insert(QStringLiteral("tabs"), rows);
        sendResult(socket, requestID, command, result);
        return;
    }
    if (command == QLatin1String("tabs.create")) {
        // select=false leaves the current tab selected (MCP create_tab).
        const bool select = params.value(QStringLiteral("select"), true).toBool();
        tabs->newTab(select);
        const QString label = params.value(QStringLiteral("label")).toString();
        if (!label.isEmpty())
            tabs->setTabLabel(tabs->count() - 1, label);
        sendResult(socket, requestID, command, tabsRow(tabs, tabs->count() - 1));
        return;
    }
    if (command == QLatin1String("tabs.set_split")) {
        if (tabs->activeTab() < 0) {
            sendError(socket, requestID, command, QStringLiteral("app_command_failed"),
                      QStringLiteral("no active tab"));
            return;
        }
        tabs->setSplit(params.value(QStringLiteral("enabled")).toBool());
        sendResult(socket, requestID, command, tabsRow(tabs, tabs->activeTab()));
        return;
    }
    if (command == QLatin1String("tabs.select")) {
        const int index = tabIndexByID(tabs, params.value(QStringLiteral("tab_id")).toString());
        if (index < 0) {
            sendError(socket, requestID, command, QStringLiteral("not_found"),
                      QStringLiteral("unknown tab"));
            return;
        }
        // Selecting the already-active tab is a no-op success.
        if (index != tabs->activeTab())
            tabs->selectTab(index);
        sendResult(socket, requestID, command, tabsRow(tabs, index));
        return;
    }
    if (command == QLatin1String("tabs.move")) {
        const int index = tabIndexByID(tabs, params.value(QStringLiteral("tab_id")).toString());
        const int to = params.value(QStringLiteral("to")).toInt();
        if (index < 0 || to < 0 || to >= tabs->count()) {
            sendError(socket, requestID, command, QStringLiteral("invalid_params"),
                      QStringLiteral("unknown tab or position"));
            return;
        }
        tabs->moveTab(index, to);
        sendResult(socket, requestID, command, tabsRow(tabs, to));
        return;
    }
    if (command == QLatin1String("tabs.close")) {
        const QString target = params.value(QStringLiteral("tab_id")).toString();
        const int index = target.isEmpty() ? tabs->activeTab() : tabIndexByID(tabs, target);
        if (index < 0) {
            sendError(socket, requestID, command, QStringLiteral("not_found"),
                      QStringLiteral("unknown tab"));
            return;
        }
        const QString closedID = tabs->tabID(index);
        if (!tabs->closeTab(index)) {
            // Upstream: closing the last tab closes the window.
            sendResult(socket, requestID, command, QVariantMap{
                {QStringLiteral("window_closed"), true},
                {QStringLiteral("closed_tab"), closedID}});
            return;
        }
        sendResult(socket, requestID, command, QVariantMap{
            {QStringLiteral("window_closed"), false},
            {QStringLiteral("closed_tab"), closedID}});
        return;
    }
    if (command == QLatin1String("tabs.close_others") || command == QLatin1String("tabs.close_right")) {
        // Upstream's menu items target the current tab; an absent tab_id
        // means "keep the active tab".
        const QString target = params.value(QStringLiteral("tab_id")).toString();
        const int index = target.isEmpty() ? tabs->activeTab() : tabIndexByID(tabs, target);
        if (index < 0) {
            sendError(socket, requestID, command, QStringLiteral("not_found"),
                      QStringLiteral("unknown tab"));
            return;
        }
        if (command == QLatin1String("tabs.close_others"))
            tabs->closeOtherTabs(index);
        else
            tabs->closeTabsToRight(index);
        sendResult(socket, requestID, command, QVariantMap{
            {QStringLiteral("remaining"), tabs->count()}});
        return;
    }
    if (command == QLatin1String("pane.get")) {
        const QString pane = params.value(QStringLiteral("pane")).toString();
        const bool second = pane == QLatin1String("1") || pane == QLatin1String("second");
        QVariantMap result = tabsRow(tabs, tabs->activeTab());
        result.insert(QStringLiteral("pane"), second ? 1 : 0);
        sendResult(socket, requestID, command, result);
        return;
    }
    if (command == QLatin1String("pane.focus")) {
        const QString pane = params.value(QStringLiteral("pane")).toString();
        const bool second = pane == QLatin1String("1") || pane == QLatin1String("second");
        // The focused pane routes inspector fetches; the tab's shared
        // workspace state is one source per tab in this port.
        emit revealRequested(QString());
        sendResult(socket, requestID, command, QVariantMap{
            {QStringLiteral("pane"), second ? 1 : 0}});
        return;
    }
    if (command == QLatin1String("tab.set_filter")) {
        if (tabs->activeTab() < 0) {
            sendError(socket, requestID, command, QStringLiteral("app_command_failed"),
                      QStringLiteral("no active tab"));
            return;
        }
        const QString filter = params.value(QStringLiteral("filter")).toString();
        tabs->applyActiveTabFilter(filter);
        sendResult(socket, requestID, command, QVariantMap{
            {QStringLiteral("filter_text"), session->filterText()}});
        return;
    }
    if (command == QLatin1String("overview.get")) {
        sendResult(socket, requestID, command, session->overview());
        return;
    }
    if (command == QLatin1String("statistics.endpoints")) {
        // Documented CLI/MCP groups (command-line.txt §12, docs/mcp §7):
        // apps, domains, ipv4, ipv6, tcp, udp — the model's group order.
        static const QHash<QString, EndpointStatisticsModel::Group> groups{
            {QStringLiteral("apps"), EndpointStatisticsModel::Apps},
            {QStringLiteral("domains"), EndpointStatisticsModel::Domains},
            {QStringLiteral("ipv4"), EndpointStatisticsModel::Ipv4},
            {QStringLiteral("ipv6"), EndpointStatisticsModel::Ipv6},
            {QStringLiteral("tcp"), EndpointStatisticsModel::Tcp},
            {QStringLiteral("udp"), EndpointStatisticsModel::Udp}};
        static const QHash<QString, EndpointStatisticsModel::Column> columns{
            {QStringLiteral("address"), EndpointStatisticsModel::Address},
            {QStringLiteral("port"), EndpointStatisticsModel::Port},
            {QStringLiteral("protocol"), EndpointStatisticsModel::ProtocolName},
            {QStringLiteral("client"), EndpointStatisticsModel::Client},
            {QStringLiteral("domain"), EndpointStatisticsModel::Domain},
            {QStringLiteral("packets"), EndpointStatisticsModel::Packets},
            {QStringLiteral("bytes"), EndpointStatisticsModel::Bytes},
            {QStringLiteral("tx_packets"), EndpointStatisticsModel::TxPackets},
            {QStringLiteral("tx_bytes"), EndpointStatisticsModel::TxBytes},
            {QStringLiteral("rx_packets"), EndpointStatisticsModel::RxPackets},
            {QStringLiteral("rx_bytes"), EndpointStatisticsModel::RxBytes},
            {QStringLiteral("summary"), EndpointStatisticsModel::Summary}};
        EndpointStatisticsModel *stats = session->endpointStats();
        const QString group = params.value(QStringLiteral("group"), QStringLiteral("apps")).toString();
        if (!groups.contains(group)) {
            sendError(socket, requestID, command, QStringLiteral("invalid_params"),
                      QStringLiteral("unknown group"));
            return;
        }
        const QString sort = params.value(QStringLiteral("sort"), QStringLiteral("bytes")).toString();
        if (!columns.contains(sort)) {
            sendError(socket, requestID, command, QStringLiteral("invalid_params"),
                      QStringLiteral("unknown sort column"));
            return;
        }
        const QString order = params.value(QStringLiteral("order"), QStringLiteral("desc")).toString();
        if (order != QLatin1String("desc") && order != QLatin1String("asc")) {
            sendError(socket, requestID, command, QStringLiteral("invalid_params"),
                      QStringLiteral("order must be desc or asc"));
            return;
        }
        stats->setGroup(groups.value(group));
        stats->setSortOrder(columns.value(sort), order == QLatin1String("asc"));
        stats->setSearchText(params.value(QStringLiteral("search")).toString());
        stats->rebuild(session->packets());
        int limit = params.value(QStringLiteral("limit"), 50).toInt();
        limit = qBound(1, limit, 500); // upstream: a page holds at most 500 rows
        int offset = qMax(0, params.value(QStringLiteral("offset"), 0).toInt());
        QVariantList rows;
        int row = offset;
        for (; row < stats->count() && rows.size() < limit; ++row) {
            QVariantMap entry;
            entry.insert(QStringLiteral("key"), stats->keyAt(row));
            // Value columns answer their custom roles (DisplayRole is for the
            // QML table's painted cells); the Role enum parallels Column.
            for (int column = 0; column < stats->columnCount(); ++column) {
                entry.insert(stats->columnJsonKey(column),
                             stats->data(stats->index(row, column),
                                         EndpointStatisticsModel::AddressRole + column));
            }
            // The endpoint object passes to pane targeting (upstream §7).
            entry.insert(QStringLiteral("endpoint"), QVariantMap{
                {QStringLiteral("group"), group},
                {QStringLiteral("key"), stats->keyAt(row)}});
            rows.append(entry);
        }
        QVariantMap result;
        result.insert(QStringLiteral("group"), group);
        result.insert(QStringLiteral("count"), stats->count());
        result.insert(QStringLiteral("offset"), offset);
        result.insert(QStringLiteral("next_offset"),
                      row < stats->count() ? row : -1);
        result.insert(QStringLiteral("rows"), rows);
        sendResult(socket, requestID, command, result);
        return;
    }
    if (command == QLatin1String("packets.reveal")) {
        const QString packetID = params.value(QStringLiteral("packet_id")).toString();
        if (packetID.isEmpty()) {
            sendError(socket, requestID, command, QStringLiteral("invalid_params"),
                      QStringLiteral("packet_id required"));
            return;
        }
        emit revealRequested(packetID);
        sendResult(socket, requestID, command, QVariantMap{
            {QStringLiteral("packet_id"), packetID}});
        return;
    }
    if (command == QLatin1String("packets.query")) {
        // Bounded window over the pane's loaded packet rows (the same rows
        // the packet table shows). Rows beyond the loaded page arrive with
        // the next table page; the daemon fetches on demand.
        PacketListModel *packets = session->packets();
        int limit = params.value(QStringLiteral("limit"), 50).toInt();
        limit = qBound(1, limit, 500);
        const int offset = qMax(0, params.value(QStringLiteral("offset"), 0).toInt());
        QVariantList rows;
        int row = offset;
        for (; row < packets->count() && rows.size() < limit; ++row) {
            const QVariantMap snapshot = packets->rowSnapshotAt(row);
            rows.append(QVariantMap{
                {QStringLiteral("packet_id"), snapshot.value(QStringLiteral("packetId"))},
                {QStringLiteral("number"), snapshot.value(QStringLiteral("number"))},
                {QStringLiteral("time"), snapshot.value(QStringLiteral("timeText"))},
                {QStringLiteral("source"), snapshot.value(QStringLiteral("source"))},
                {QStringLiteral("source_port"), snapshot.value(QStringLiteral("sourcePort"))},
                {QStringLiteral("destination"), snapshot.value(QStringLiteral("destination"))},
                {QStringLiteral("destination_port"), snapshot.value(QStringLiteral("destinationPort"))},
                {QStringLiteral("protocol"), snapshot.value(QStringLiteral("protocol"))},
                {QStringLiteral("client"), snapshot.value(QStringLiteral("client"))},
                {QStringLiteral("domain"), snapshot.value(QStringLiteral("domain"))},
                {QStringLiteral("stream_id"), snapshot.value(QStringLiteral("streamId"))},
                {QStringLiteral("summary"), snapshot.value(QStringLiteral("summary"))},
                {QStringLiteral("length"), snapshot.value(QStringLiteral("length"))},
                {QStringLiteral("severity"), snapshot.value(QStringLiteral("severity"))},
                {QStringLiteral("decode_status"), snapshot.value(QStringLiteral("decodeStatus"))},
                {QStringLiteral("comment"), snapshot.value(QStringLiteral("comment"))},
            });
        }
        QVariantMap result;
        result.insert(QStringLiteral("count"), packets->count());
        result.insert(QStringLiteral("total_count"), packets->totalCount());
        result.insert(QStringLiteral("offset"), offset);
        result.insert(QStringLiteral("next_offset"),
                      row < packets->count() ? row : -1);
        result.insert(QStringLiteral("packets"), rows);
        sendResult(socket, requestID, command, result);
        return;
    }
    sendError(socket, requestID, command, QStringLiteral("unknown_command"),
              QStringLiteral("unknown command %1").arg(command));
}

void AppCommandServer::sendResult(QLocalSocket *socket, const QString &requestID,
                                  const QString &command, const QVariant &result)
{
    QVariant data = result;
    // MCP connections get the redaction pass (upstream "Redact Sensitive Data
    // Before Sending to AI"); CLI connections are unaffected.
    if (socket->property("mcp").toBool() && mcpRedaction())
        redactValue(data);
    QJsonObject response{
        {QStringLiteral("schema_version"), 1},
        {QStringLiteral("request_id"), requestID},
        {QStringLiteral("ok"), true},
        {QStringLiteral("command"), command},
        {QStringLiteral("data"), QJsonValue::fromVariant(data)},
    };
    socket->write(QJsonDocument(response).toJson(QJsonDocument::Compact) + '\n');
    socket->flush();
}

void AppCommandServer::sendError(QLocalSocket *socket, const QString &requestID,
                                 const QString &command, const QString &code,
                                 const QString &message)
{
    QJsonObject response{
        {QStringLiteral("schema_version"), 1},
        {QStringLiteral("request_id"), requestID},
        {QStringLiteral("ok"), false},
        {QStringLiteral("command"), command},
        {QStringLiteral("error"), QJsonObject{
            {QStringLiteral("code"), code},
            {QStringLiteral("message"), message}}},
    };
    socket->write(QJsonDocument(response).toJson(QJsonDocument::Compact) + '\n');
    socket->flush();
}

void AppCommandServer::redactValue(QVariant &value)
{
    switch (value.metaType().id()) {
    case QMetaType::QVariantMap: {
        QVariantMap map = value.toMap();
        for (auto it = map.begin(); it != map.end(); ++it) {
            if (isSensitiveKey(it.key()))
                it.value() = QStringLiteral("[redacted]");
            else
                redactValue(it.value());
        }
        value = map;
        return;
    }
    case QMetaType::QVariantList: {
        QVariantList list = value.toList();
        for (QVariant &entry : list)
            redactValue(entry);
        value = list;
        return;
    }
    default:
        return;
    }
}
