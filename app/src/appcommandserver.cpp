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
        tabs->newTab();
        const QString label = params.value(QStringLiteral("label")).toString();
        if (!label.isEmpty())
            tabs->setTabLabel(tabs->count() - 1, label);
        sendResult(socket, requestID, command, tabsRow(tabs, tabs->count() - 1));
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
        const int index = tabIndexByID(tabs, params.value(QStringLiteral("tab_id")).toString());
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
        EndpointStatisticsModel *stats = session->endpointStats();
        const QString group = params.value(QStringLiteral("group"), QStringLiteral("apps")).toString();
        const QHash<QString, int> groups{
            {QStringLiteral("apps"), 0}, {QStringLiteral("domains"), 1},
            {QStringLiteral("ips"), 2}, {QStringLiteral("clients"), 3}};
        if (!groups.contains(group)) {
            sendError(socket, requestID, command, QStringLiteral("invalid_params"),
                      QStringLiteral("unknown group"));
            return;
        }
        stats->setGroup(groups.value(group));
        stats->setSearchText(params.value(QStringLiteral("search")).toString());
        stats->rebuild(session->packets());
        QVariantList rows;
        int limit = params.value(QStringLiteral("limit"), 50).toInt();
        limit = qBound(1, limit, 1000);
        for (int row = 0; row < stats->count() && rows.size() < limit; ++row) {
            QVariantMap entry;
            entry.insert(QStringLiteral("key"), stats->keyAt(row));
            for (int column = 0; column < stats->columnCount(); ++column) {
                entry.insert(stats->columnJsonKey(column),
                             stats->data(stats->index(row, column), Qt::DisplayRole));
            }
            rows.append(entry);
        }
        QVariantMap result;
        result.insert(QStringLiteral("group"), group);
        result.insert(QStringLiteral("count"), stats->count());
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
    sendError(socket, requestID, command, QStringLiteral("unknown_command"),
              QStringLiteral("unknown command %1").arg(command));
}

void AppCommandServer::sendResult(QLocalSocket *socket, const QString &requestID,
                                  const QString &command, const QVariant &result)
{
    QJsonObject response{
        {QStringLiteral("schema_version"), 1},
        {QStringLiteral("request_id"), requestID},
        {QStringLiteral("ok"), true},
        {QStringLiteral("command"), command},
        {QStringLiteral("data"), QJsonValue::fromVariant(result)},
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
