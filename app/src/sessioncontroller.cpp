#include "sessioncontroller.h"

#include <QClipboard>
#include <QDateTime>
#include <QFile>
#include <QGuiApplication>
#include <QSettings>
#include <QTimer>
#include <QUrl>

namespace {

QString formatDelta(qint64 milliseconds)
{
    if (milliseconds <= 0)
        return {};
    const double seconds = double(milliseconds) / 1000.0;
    if (seconds < 1.0)
        return QString::number(seconds, 'f', 6);
    if (seconds < 60.0)
        return QString::number(seconds, 'f', 3);
    return QString::number(seconds, 'f', 2);
}

QString endpointAddress(const QVariantMap &endpoint)
{
    return endpoint.value(QStringLiteral("address")).toString();
}

QString endpointPort(const QVariantMap &endpoint)
{
    const QVariant port = endpoint.value(QStringLiteral("port"));
    if (!port.isValid() || port.isNull())
        return {};
    return QString::number(port.toInt());
}

} // namespace

SessionController::SessionController(QObject *parent)
    : QObject(parent)
    , m_client(new DaemonClient(this))
    , m_packets(new PacketListModel(this))
    , m_sourceTree(new SourceTreeModel(this))
    , m_columnLayout(new PacketColumnLayout(this))
    , m_customColumns(new PacketCustomColumns(this))
{
    // CI/screenshot hooks (mirroring TCPVIEWER_OPEN_FILES): hide the live
    // interface controls so captured imagery only shows sanitized data.
    m_interfacesHidden = qEnvironmentVariableIsSet("TCPVIEWER_HIDE_INTERFACES");
    // 0 when unset; Main.qml keeps its defaults in that case.
    m_startupWindowWidth = qEnvironmentVariableIntValue("TCPVIEWER_WINDOW_WIDTH");
    m_startupWindowHeight = qEnvironmentVariableIntValue("TCPVIEWER_WINDOW_HEIGHT");
    // The Overview dashboard is the default landing view; TCPVIEWER_CAPTURE
    // _MODE is the CI/test override knob.
    m_startupCaptureMode = qEnvironmentVariable("TCPVIEWER_CAPTURE_MODE");
    if (m_startupCaptureMode.isEmpty())
        m_startupCaptureMode = QStringLiteral("overview");
    if (m_startupCaptureMode != QStringLiteral("overview")
        && m_startupCaptureMode != QStringLiteral("packets"))
        m_startupCaptureMode = QStringLiteral("overview");
    const QVariantList customColumns = m_columnLayout->customColumns();
    for (const QVariant &value : customColumns) {
        const QVariantMap column = value.toMap();
        m_customColumns->registerColumn(
            column.value(QStringLiteral("id")).toString(),
            column.value(QStringLiteral("fieldName")).toString());
    }

    connect(m_client, &DaemonClient::connectedChanged, this, &SessionController::handleConnectedChanged);
    connect(m_client, &DaemonClient::response, this, &SessionController::handleResponse);
    connect(m_client, &DaemonClient::failure, this, &SessionController::handleFailure);
    connect(m_client, &DaemonClient::event, this, &SessionController::handleEvent);
    connect(m_sourceTree, &SourceTreeModel::countChanged,
            this, &SessionController::applyTreeSelectHook);

    // CI hooks: start a live capture once interfaces are known, and select a
    // source-tree node after its first matching packet batch arrives.
    m_startupCaptureIface = qEnvironmentVariable("TCPVIEWER_CAPTURE_IFACE");
    m_treeSelectNode = qEnvironmentVariable("TCPVIEWER_TREE_SELECT");
    m_startupFilter = qEnvironmentVariable("TCPVIEWER_FILTER").trimmed();
    // CI/test hook: preselect quick-filter chips (e.g. "tcp", "errors")
    // so filtered-table flows can be captured without a mouse click.
    const QStringList quickHook =
        qEnvironmentVariable("TCPVIEWER_QUICK_FILTERS").split(u',', Qt::SkipEmptyParts);
    for (const QString &chip : quickHook) {
        const QString id = chip.trimmed();
        if (!id.isEmpty())
            m_quickFilters.append(id);
    }

    // Sidebar Favorites (upstream PacketCustomFilterService): pinned display
    // filters and named saved filters live in QSettings alongside the
    // overview card layout. Corrupt or partial entries are skipped.
    {
        QSettings settings;
        m_pinnedFilters =
            settings.value(QStringLiteral("filters/pinned")).toStringList();
        const int savedCount =
            settings.beginReadArray(QStringLiteral("filters/saved"));
        for (int i = 0; i < savedCount; ++i) {
            settings.setArrayIndex(i);
            const QString name =
                settings.value(QStringLiteral("name")).toString().trimmed();
            const QString query =
                settings.value(QStringLiteral("query")).toString().trimmed();
            if (!name.isEmpty() && !query.isEmpty()) {
                m_savedFilters.append(QVariantMap{
                    {QStringLiteral("name"), name},
                    {QStringLiteral("query"), query},
                });
            }
        }
        settings.endArray();
    }

    m_pollTimer = new QTimer(this);
    m_pollTimer->setInterval(100);
    connect(m_pollTimer, &QTimer::timeout, this, [this]() { requestPackets(false); });
    m_pollTimer->start();

    m_statusTimer = new QTimer(this);
    m_statusTimer->setInterval(1000);
    connect(m_statusTimer, &QTimer::timeout, this, &SessionController::refreshStatus);
    m_statusTimer->start();
}

void SessionController::start()
{
    // Launch-with-files hook (also used by CI screenshots). Semicolon-separated
    // absolute paths, matching the eventual CLI argument handling.
    const QString openFiles = qEnvironmentVariable("TCPVIEWER_OPEN_FILES");
    if (!openFiles.isEmpty())
        m_pendingOpenFiles = openFiles.split(QLatin1Char(';'), Qt::SkipEmptyParts);

    // A local socket can connect synchronously, so the pending list must exist
    // before this call.
    m_client->start();
}

bool SessionController::connected() const
{
    return m_client->connected();
}

bool SessionController::capturing() const
{
    const QString phase = capturePhase();
    return phase == QStringLiteral("running") || phase == QStringLiteral("paused")
        || phase == QStringLiteral("starting");
}

void SessionController::handleConnectedChanged()
{
    emit connectedChanged();
    if (!m_client->connected())
        return;

    if (!m_pendingOpenFiles.isEmpty()) {
        QVariantList paths;
        for (const QString &path : m_pendingOpenFiles)
            paths.append(path);
        m_pendingOpenFiles.clear();
        importFiles(paths);
    }

    refreshInterfaces();
    refreshSources();
    if (!m_currentSourceID.isEmpty())
        refreshStatus();
}

void SessionController::refreshInterfaces()
{
    // CI/screenshot hook: never surface the host's network interfaces in
    // captured imagery.
    if (m_interfacesHidden)
        return;
    if (!m_client->connected())
        return;
    m_client->send(QStringLiteral("interfaces.list"));
}

void SessionController::refreshSources()
{
    if (!m_client->connected())
        return;
    m_client->send(QStringLiteral("sources.list"));
}

void SessionController::refreshStatus()
{
    if (!m_client->connected() || m_currentSourceID.isEmpty())
        return;
    m_client->send(QStringLiteral("capture.status"),
                   {{QStringLiteral("source_id"), m_currentSourceID}});
}

void SessionController::requestOverview()
{
    if (!m_client->connected())
        return;
    // No selection: let the daemon pick its first source so the Overview page
    // still shows aggregates for a just-opened file.
    QVariantMap params;
    if (!m_currentSourceID.isEmpty())
        params.insert(QStringLiteral("source_id"), m_currentSourceID);
    if (!m_overviewLoading) {
        m_overviewLoading = true;
        emit overviewLoadingChanged();
    }
    m_client->send(QStringLiteral("capture.overview"), params);
}

void SessionController::startCapture(const QString &interfaceID)
{
    if (!m_client->connected()) {
        setError(QStringLiteral("tcpviewerd is not running."));
        return;
    }
    const QString interface = interfaceID.isEmpty() ? m_selectedInterface : interfaceID;
    if (interface.isEmpty()) {
        setError(QStringLiteral("Select a capture interface first."));
        return;
    }
    setError(QString());
    setLoading(true);
    m_client->send(QStringLiteral("capture.start"),
                   {{QStringLiteral("interface"), interface}});
}

void SessionController::stopCapture()
{
    if (!m_client->connected())
        return;
    QVariantMap params;
    if (!m_currentSourceID.isEmpty())
        params.insert(QStringLiteral("source_id"), m_currentSourceID);
    m_client->send(QStringLiteral("capture.stop"), params);
}

void SessionController::pauseCapture()
{
    if (!m_client->connected() || m_currentSourceID.isEmpty())
        return;
    m_client->send(QStringLiteral("capture.pause"),
                   {{QStringLiteral("source_id"), m_currentSourceID}});
}

void SessionController::resumeCapture()
{
    if (!m_client->connected() || m_currentSourceID.isEmpty())
        return;
    m_client->send(QStringLiteral("capture.resume"),
                   {{QStringLiteral("source_id"), m_currentSourceID}});
}

void SessionController::importFiles(const QVariantList &urls)
{
    QStringList paths;
    for (const QVariant &value : urls) {
        QString path;
        // Distinguish real QUrl values (drag & drop) from plain path strings.
        // Import is local-files-only: remote URLs are never fetched.
        if (value.metaType().id() == QMetaType::QUrl) {
            const QUrl url = value.toUrl();
            path = url.isLocalFile() ? url.toLocalFile() : QString();
        } else {
            path = value.toString();
        }
        if (!path.isEmpty())
            paths.append(path);
    }
    if (paths.isEmpty())
        return;

    setError(QString());
    setLoading(true);
    m_client->send(QStringLiteral("file.import"),
                   {{QStringLiteral("paths"), paths}}, 300);
}

void SessionController::closeSource(const QString &sourceID)
{
    if (!m_client->connected() || sourceID.isEmpty())
        return;
    m_client->send(QStringLiteral("source.close"),
                   {{QStringLiteral("source_id"), sourceID}});
    if (sourceID == m_currentSourceID)
        selectSourceInternal(QString());
}

void SessionController::selectSource(const QString &sourceID)
{
    if (sourceID == m_currentSourceID) {
        resetStream();
        return;
    }
    selectSourceInternal(sourceID);
}

void SessionController::selectSourceInternal(const QString &sourceID)
{
    clearSelection();
    m_currentSourceID = sourceID;
    m_customColumns->setSourceID(sourceID);
    m_status.clear();
    m_totalCount = 0;
    m_lastPacketID = 0;
    m_lastPacketTimestamp = 0;
    m_lastStreamTimestamp.clear();
    m_requestInFlight = false;
    // A different source has different aggregates; QML refetches on switch.
    m_overview.clear();
    m_overviewRevisionKey.clear();
    emit overviewChanged();
    emit currentSourceChanged();
    emit statusChanged();
    emit totalCountChanged();

    if (sourceID.isEmpty()) {
        m_packets->clearTreeFilter();
        m_sourceTree->reset();
        m_packets->clear();
        m_treeSelectApplied = false;
        setLoading(false);
        return;
    }

    // CI/screenshot hook: the first opened source starts with this display
    // filter, so filtered tables and Favorites selection states are capturable.
    if (!m_startupFilter.isEmpty() && !m_startupFilterApplied) {
        m_startupFilterApplied = true;
        m_filterText = m_startupFilter;
        emit filterTextChanged();
    }

    resetStream();
    refreshStatus();
    emit sourceOpened(sourceID);
}

void SessionController::clearPackets()
{
    if (!m_client->connected() || m_currentSourceID.isEmpty())
        return;
    m_client->send(QStringLiteral("packets.clear"),
                   {{QStringLiteral("source_id"), m_currentSourceID},
                    {QStringLiteral("yes"), true}});
}

void SessionController::applyFilter(const QString &filter)
{
    if (filter == m_filterText) {
        resetStream();
        return;
    }
    clearSelection();
    setFilterTextInternal(filter);
    resetStream();
}

void SessionController::setQuickFilters(const QVariantList &quickFilters)
{
    QStringList next;
    for (const QVariant &value : quickFilters) {
        const QString id = value.toString();
        if (!id.isEmpty())
            next.append(id);
    }
    if (next == m_quickFilters)
        return;
    clearSelection();
    m_quickFilters = next;
    emit quickFiltersChanged();
    resetStream();
}

// Sidebar Favorites. Pinned filters are bare expressions (one click applies
// them); saved filters carry a display name. Persistence intentionally lives
// in QSettings so it survives plugin updates and never overwrites user files
// (upstream keeps the same data in PacketCustomFilterService's JSON store).
void SessionController::pinFilter(const QString &expression)
{
    const QString trimmed = expression.trimmed();
    if (trimmed.isEmpty() || m_pinnedFilters.contains(trimmed))
        return;
    m_pinnedFilters.append(trimmed);
    QSettings().setValue(QStringLiteral("filters/pinned"), m_pinnedFilters);
    emit filtersChanged();
}

void SessionController::unpinFilter(const QString &expression)
{
    if (m_pinnedFilters.removeAll(expression.trimmed()) == 0)
        return;
    QSettings().setValue(QStringLiteral("filters/pinned"), m_pinnedFilters);
    emit filtersChanged();
}

QString SessionController::saveFilter(const QString &name, const QString &query)
{
    // Validation mirrors upstream PacketCustomFilterService.normalizedName:
    // trimmed, non-empty, at most 40 characters.
    const QString trimmedName = name.trimmed();
    const QString trimmedQuery = query.trimmed();
    if (trimmedName.isEmpty())
        return QStringLiteral("Enter a filter name.");
    if (trimmedName.size() > 40)
        return QStringLiteral("Filter names must be 40 characters or fewer.");
    if (trimmedQuery.isEmpty())
        return QStringLiteral("Enter a display filter first.");

    bool replaced = false;
    for (QVariant &entry : m_savedFilters) {
        QVariantMap map = entry.toMap();
        if (map.value(QStringLiteral("name")).toString() == trimmedName) {
            map.insert(QStringLiteral("query"), trimmedQuery);
            entry = map;
            replaced = true;
            break;
        }
    }
    if (!replaced) {
        m_savedFilters.append(QVariantMap{
            {QStringLiteral("name"), trimmedName},
            {QStringLiteral("query"), trimmedQuery},
        });
    }
    persistSavedFilters();
    emit filtersChanged();
    return QString();
}

void SessionController::removeSavedFilter(const QString &name)
{
    const QString trimmed = name.trimmed();
    bool removed = false;
    for (qsizetype i = 0; i < m_savedFilters.size(); ++i) {
        if (m_savedFilters.at(i).toMap().value(QStringLiteral("name")).toString()
            == trimmed) {
            m_savedFilters.removeAt(i);
            removed = true;
            break;
        }
    }
    if (!removed)
        return;
    persistSavedFilters();
    emit filtersChanged();
}

void SessionController::persistSavedFilters()
{
    QSettings settings;
    settings.remove(QStringLiteral("filters/saved"));
    settings.beginWriteArray(QStringLiteral("filters/saved"));
    for (qsizetype i = 0; i < m_savedFilters.size(); ++i) {
        settings.setArrayIndex(int(i));
        const QVariantMap map = m_savedFilters.at(i).toMap();
        settings.setValue(QStringLiteral("name"),
                          map.value(QStringLiteral("name")));
        settings.setValue(QStringLiteral("query"),
                          map.value(QStringLiteral("query")));
    }
    settings.endArray();
}

void SessionController::selectTreeFilter(const QString &nodeId)
{
    const PacketTreeFilter filter = m_sourceTree->filterForNode(nodeId);
    if (!filter.valid)
        return;

    clearSelection();
    m_sourceTree->selectNode(nodeId);
    if (filter.active) {
        m_packets->setTreeFilter(filter.appKey, filter.domainKey, filter.ip,
                                 filter.appsOnly, filter.missingDomain);
    } else {
        m_packets->clearTreeFilter();
    }
}

void SessionController::toggleTreeExpanded(const QString &nodeId)
{
    m_sourceTree->toggleExpanded(nodeId);
}

void SessionController::applyTreeSelectHook()
{
    if (m_treeSelectNode.isEmpty() || m_treeSelectApplied)
        return;
    if (m_sourceTree->filterForNode(m_treeSelectNode).valid) {
        selectTreeFilter(m_treeSelectNode);
        m_treeSelectApplied = true;
    }
}

void SessionController::selectPacket(const QString &packetID)
{
    if (packetID.isEmpty()) {
        clearSelection();
        return;
    }
    if (packetID == m_selectedPacketID)
        return;

    m_selectedPacketID = packetID;
    emit selectedPacketIDChanged();
}

void SessionController::revealPacket(const QString &packetID)
{
    if (packetID.isEmpty())
        return;
    if (packetID == m_selectedPacketID) {
        emit revealRequested(packetID);
        return;
    }
    m_selectedPacketID = packetID;
    emit selectedPacketIDChanged();
    emit revealRequested(packetID);
}

void SessionController::clearSelection()
{
    if (m_selectedPacketID.isEmpty())
        return;
    m_selectedPacketID.clear();
    emit selectedPacketIDChanged();
}

void SessionController::resetStream()
{
    // The table is rebuilt from the daemon, so the local tree scope starts over.
    m_packets->clearTreeFilter();
    m_sourceTree->reset();
    m_packets->clear();
    m_treeSelectApplied = false;
    m_lastPacketID = 0;
    m_lastPacketTimestamp = 0;
    m_lastStreamTimestamp.clear();
    m_requestInFlight = false;
    if (m_currentSourceID.isEmpty()) {
        setLoading(false);
        return;
    }
    setLoading(true);
    requestPackets(true);
}

void SessionController::requestPackets(bool firstPage)
{
    if (m_currentSourceID.isEmpty() || m_requestInFlight || !m_client->connected())
        return;

    QVariantMap params{
        {QStringLiteral("source_id"), m_currentSourceID},
        {QStringLiteral("limit"), m_pageSize},
    };
    // Both scopes ride on EVERY request. Quick chips are per-request on the
    // daemon (absent = show all), so catch-up and follow pages that omit them
    // silently refilled the table with unfiltered rows. The display filter is
    // source-sticky, but re-sending it is idempotent.
    params.insert(QStringLiteral("filter"), m_filterText);
    params.insert(QStringLiteral("quick_filters"), m_quickFilters);
    if (firstPage) {
        params.insert(QStringLiteral("offset"), 0);
    } else {
        params.insert(QStringLiteral("since_id"), QString::number(m_lastPacketID));
    }

    m_requestInFlight = true;
    m_client->send(QStringLiteral("packets.list"), params, 120);
}

void SessionController::handleResponse(const QString &command, const QVariantMap &data)
{
    if (command == QStringLiteral("file.export")
        || command == QStringLiteral("file.export_session")) {
        setLoading(false);
        setError(QString());
        emit exportFinished(data.value(QStringLiteral("path")).toString(),
                            data.value(QStringLiteral("packet_count")).toInt());
        return;
    }

    if (command == QStringLiteral("interfaces.list")) {
        m_interfaces = data.value(QStringLiteral("interfaces")).toList();
        if (m_selectedInterface.isEmpty()) {
            for (const QVariant &value : m_interfaces) {
                const QVariantMap interface = value.toMap();
                const QVariantMap capabilities = interface.value(QStringLiteral("capabilities")).toMap();
                if (!interface.value(QStringLiteral("is_loopback")).toBool()
                    && capabilities.value(QStringLiteral("can_capture")).toBool()) {
                    m_selectedInterface = interface.value(QStringLiteral("id")).toString();
                    emit selectedInterfaceChanged();
                    break;
                }
            }
        }
        emit interfacesChanged();
        if (!m_startupCaptureIface.isEmpty() && !m_startupCaptureStarted) {
            m_startupCaptureStarted = true;
            QTimer::singleShot(0, this, [this]() { startCapture(m_startupCaptureIface); });
        }
        return;
    }

    if (command == QStringLiteral("sources.list")) {
        m_sources = data.value(QStringLiteral("sources")).toList();
        bool currentFound = false;
        for (const QVariant &value : m_sources) {
            const QVariantMap source = value.toMap();
            if (source.value(QStringLiteral("source_id")).toString() == m_currentSourceID) {
                currentFound = true;
                if (m_status.isEmpty())
                    setStatus(source);
                break;
            }
        }

        if (!m_pendingSelectPath.isEmpty()) {
            for (const QVariant &value : m_sources) {
                const QVariantMap source = value.toMap();
                if (source.value(QStringLiteral("path")).toString() == m_pendingSelectPath) {
                    m_pendingSelectPath.clear();
                    selectSourceInternal(source.value(QStringLiteral("source_id")).toString());
                    break;
                }
            }
            m_pendingSelectPath.clear();
        } else if (!currentFound && !m_currentSourceID.isEmpty()) {
            selectSourceInternal(QString());
        }
        emit sourcesChanged();
        return;
    }

    if (command == QStringLiteral("capture.start")) {
        const QString sourceID = data.value(QStringLiteral("source_id")).toString();
        selectSourceInternal(sourceID);
        setStatus(data);
        refreshSources();
        return;
    }

    if (command == QStringLiteral("capture.status")) {
        const QString sourceID = data.value(QStringLiteral("source_id")).toString();
        if (m_currentSourceID.isEmpty() && !sourceID.isEmpty())
            selectSourceInternal(sourceID);
        if (sourceID == m_currentSourceID)
            setStatus(data);
        return;
    }

    if (command == QStringLiteral("capture.overview")) {
        // Skip only same-revision payloads so the charts don't flicker
        // needlessly; different sources always re-emit.
        const QString revisionKey = QStringLiteral("%1:%2:%3").arg(
            data.value(QStringLiteral("source_id")).toString(),
            data.value(QStringLiteral("revision")).toMap().value(QStringLiteral("count")).toString(),
            data.value(QStringLiteral("revision")).toMap().value(QStringLiteral("update_seq")).toString());
        if (m_overviewRevisionKey == revisionKey && !m_overview.isEmpty())
            return;
        // Never show another source's aggregates under the current one.
        const QString sourceID = data.value(QStringLiteral("source_id")).toString();
        if (!sourceID.isEmpty() && !m_currentSourceID.isEmpty() && sourceID != m_currentSourceID)
            return;
        m_overviewRevisionKey = revisionKey;
        m_overview = data;
        if (m_overviewLoading) {
            m_overviewLoading = false;
            emit overviewLoadingChanged();
        }
        emit overviewChanged();
        return;
    }

    if (command == QStringLiteral("capture.stop")
        || command == QStringLiteral("capture.pause")
        || command == QStringLiteral("capture.resume")) {
        setStatus(data);
        refreshSources();
        return;
    }

    if (command == QStringLiteral("packets.list")) {
        handlePackets(data);
        return;
    }

    if (command == QStringLiteral("file.import")) {
        const QVariantList imported = data.value(QStringLiteral("imported")).toList();
        setLoading(false);
        if (!imported.isEmpty())
            m_pendingSelectPath = imported.last().toString();
        refreshSources();
        return;
    }

    if (command == QStringLiteral("packets.clear")) {
        clearSelection();
        m_customColumns->clear();
        resetStream();
        return;
    }

    if (command == QStringLiteral("source.close")) {
        refreshSources();
        return;
    }
}

void SessionController::handlePackets(const QVariantMap &data)
{
    m_requestInFlight = false;

    const QString sourceID = data.value(QStringLiteral("source_id")).toString();
    if (!sourceID.isEmpty() && sourceID != m_currentSourceID)
        return;

    const QVariantList summaries = data.value(QStringLiteral("packets")).toList();
    QVector<PacketRow> rows;
    rows.reserve(summaries.size());
    for (const QVariant &value : summaries)
        rows.append(parseSummary(value.toMap()));

    // Upstream's Delta Time and Stream Delta columns are presentation values
    // derived from the capture order, not fields in the daemon summary.
    for (PacketRow &row : rows) {
        if (row.timestampMs > 0 && m_lastPacketTimestamp > 0)
            row.deltaTime = formatDelta(row.timestampMs - m_lastPacketTimestamp);
        if (!row.streamId.isEmpty() && row.timestampMs > 0) {
            const auto previous = m_lastStreamTimestamp.constFind(row.streamId);
            if (previous != m_lastStreamTimestamp.cend())
                row.streamDeltaTime = formatDelta(row.timestampMs - previous.value());
            m_lastStreamTimestamp.insert(row.streamId, row.timestampMs);
        }
        if (row.timestampMs > 0)
            m_lastPacketTimestamp = row.timestampMs;
    }

    // The sidebar is an app-layer aggregate of the loaded packet summaries
    // (upstream PacketSourceListService), so it follows every loaded page.
    m_sourceTree->appendRows(rows);
    m_packets->appendRows(rows);
    if (m_packets->lastPacketID() > m_lastPacketID)
        m_lastPacketID = m_packets->lastPacketID();

    applyTreeSelectHook();

    // CI/screenshot hook: always inspect this packet number once rows exist.
    const QString autoSelect = qEnvironmentVariable("TCPVIEWER_SELECT_PACKET");
    if (!autoSelect.isEmpty() && m_selectedPacketID.isEmpty() && !rows.isEmpty())
        selectPacket(autoSelect);

    const int pageReceived = rows.size();
    if (pageReceived > 0)
        setLoading(false);

    // Catch up quickly while the daemon still has rows beyond this page.
    if (pageReceived >= m_pageSize)
        QTimer::singleShot(0, this, [this]() { requestPackets(false); });
    else
        setLoading(false);
}

void SessionController::handleFailure(const QString &command, const QString &code, const QString &message)
{
    m_requestInFlight = false;

    // Overview fetches fail silently: the page keeps the last snapshot and
    // the poller retries, so a momentary daemon hiccup doesn't nag.
    if (command == QStringLiteral("capture.overview")) {
        if (m_overviewLoading) {
            m_overviewLoading = false;
            emit overviewLoadingChanged();
        }
        return;
    }

    // A daemon restart drops every source. Recover by clearing the stale
    // selection instead of leaving a permanent "unknown source" banner.
    if (code == QStringLiteral("not_found")
        && message.startsWith(QStringLiteral("unknown source"))) {
        setLoading(false);
        setError(QString());
        if (!m_currentSourceID.isEmpty())
            selectSourceInternal(QString());
        refreshSources();
        return;
    }

    // Inspector failures stay scoped to the inspector; the table keeps working.
    setLoading(false);
    setError(message);
}

void SessionController::handleEvent(const QString &name, const QVariantMap &data)
{
    if (name == QStringLiteral("sources.changed")) {
        refreshSources();
        return;
    }
    if (name == QStringLiteral("capture.state") || name == QStringLiteral("capture.health")) {
        const QString sourceID = data.value(QStringLiteral("source_id")).toString();
        if (sourceID == m_currentSourceID)
            setStatus(data);
        else if (m_currentSourceID.isEmpty() && !sourceID.isEmpty())
            selectSourceInternal(sourceID);
        return;
    }
}

void SessionController::setStatus(const QVariantMap &status)
{
    m_status = status;
    emit statusChanged();

    if (status.contains(QStringLiteral("packet_count")))
        setTotalCount(status.value(QStringLiteral("packet_count")).toInt());
    else if (status.contains(QStringLiteral("last_packet_id")))
        setTotalCount(qMax(m_totalCount, int(m_packets->count())));

    const QString phase = status.value(QStringLiteral("phase")).toString();
    if (phase == QStringLiteral("failed")) {
        const QString message = status.value(QStringLiteral("status_message")).toString();
        if (!message.isEmpty())
            setError(message);
    }
}

void SessionController::setError(const QString &message)
{
    if (m_errorText == message)
        return;
    m_errorText = message;
    emit errorTextChanged();
}

void SessionController::clearError()
{
    setError(QString());
}

void SessionController::reportError(const QString &message)
{
    setError(message);
}

void SessionController::copyToClipboard(const QString &text)
{
    QGuiApplication::clipboard()->setText(text, QClipboard::Clipboard);
    // Best-effort synchronous mirror for plain-text-aware Wayland clients
    // before the daemon clipboard relay takes over.
    QGuiApplication::clipboard()->setText(text, QClipboard::Selection);
}

bool SessionController::writeTextFile(const QString &path, const QString &text)
{
    if (path.isEmpty())
        return false;
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
        qWarning() << "writeTextFile: cannot open" << path << file.errorString();
        return false;
    }
    const QByteArray body = text.toUtf8();
    if (file.write(body) != body.size()) {
        qWarning() << "writeTextFile: short write to" << path << file.errorString();
        return false;
    }
    return true;
}

QString SessionController::envValue(const QString &name) const
{
    if (name.isEmpty() || !qEnvironmentVariableIsSet(name.toUtf8().constData()))
        return {};
    return qEnvironmentVariable(name.toUtf8().constData());
}

void SessionController::setLoading(bool loading)
{
    if (m_loading == loading)
        return;
    m_loading = loading;
    emit loadingChanged();
}

void SessionController::setTotalCount(int total)
{
    const bool totalChanged = m_totalCount != total;
    m_totalCount = total;

    // Keep the selected source row's badge live without re-querying the full
    // source list on every packet page.
    bool sourceCountChanged = false;
    for (int i = 0; i < m_sources.size(); ++i) {
        QVariantMap source = m_sources.at(i).toMap();
        if (source.value(QStringLiteral("source_id")).toString() != m_currentSourceID)
            continue;
        if (source.value(QStringLiteral("packet_count")).toInt() != total) {
            source.insert(QStringLiteral("packet_count"), total);
            m_sources[i] = source;
            sourceCountChanged = true;
        }
        break;
    }

    if (totalChanged)
        emit totalCountChanged();
    if (sourceCountChanged)
        emit sourcesChanged();
}

void SessionController::setFilterTextInternal(const QString &filter)
{
    if (m_filterText == filter)
        return;
    m_filterText = filter;
    emit filterTextChanged();
}

void SessionController::setSelectedInterface(const QString &interfaceID)
{
    if (m_selectedInterface == interfaceID)
        return;
    m_selectedInterface = interfaceID;
    emit selectedInterfaceChanged();
}

QString SessionController::createCustomColumn(const QString &fieldName, const QString &title,
                                              const QString &sampleValue, const QString &packetID)
{
    const QString identifier = m_columnLayout->createCustomColumn(fieldName, title);
    if (identifier.isEmpty())
        return {};
    m_customColumns->registerColumn(identifier, m_columnLayout->fieldForColumn(identifier));
    if (!packetID.isEmpty())
        m_customColumns->setSampleValue(identifier, packetID, sampleValue);
    return identifier;
}

void SessionController::exportAll(const QString &path, const QString &format)
{
    if (!m_client->connected() || m_currentSourceID.isEmpty() || path.isEmpty())
        return;
    if (format != QStringLiteral("pcap") && format != QStringLiteral("pcapng")) {
        setError(QStringLiteral("Export format must be pcap or pcapng."));
        return;
    }
    setError(QString());
    setLoading(true);
    m_client->send(QStringLiteral("file.export"), {
        {QStringLiteral("source_id"), m_currentSourceID},
        {QStringLiteral("path"), path},
        {QStringLiteral("format"), format},
        {QStringLiteral("all"), true},
        {QStringLiteral("overwrite"), true},
    }, 300);
}

void SessionController::exportSelected(const QString &path, const QString &format)
{
    if (!m_client->connected() || m_currentSourceID.isEmpty() || path.isEmpty()
        || m_selectedPacketID.isEmpty()) {
        return;
    }
    if (format != QStringLiteral("pcap") && format != QStringLiteral("pcapng")) {
        setError(QStringLiteral("Export format must be pcap or pcapng."));
        return;
    }
    setError(QString());
    setLoading(true);
    m_client->send(QStringLiteral("file.export"), {
        {QStringLiteral("source_id"), m_currentSourceID},
        {QStringLiteral("path"), path},
        {QStringLiteral("format"), format},
        {QStringLiteral("packet_ids"), QVariantList{m_selectedPacketID}},
        {QStringLiteral("overwrite"), true},
    }, 300);
}

void SessionController::exportSession(const QString &path)
{
    if (!m_client->connected() || m_currentSourceID.isEmpty() || path.isEmpty())
        return;
    setError(QString());
    setLoading(true);
    m_client->send(QStringLiteral("file.export_session"), {
        {QStringLiteral("source_id"), m_currentSourceID},
        {QStringLiteral("path"), path},
        {QStringLiteral("overwrite"), true},
    }, 300);
}

PacketRow SessionController::parseSummary(const QVariantMap &summary)
{
    PacketRow row;
    row.packetId = summary.value(QStringLiteral("packet_id")).toString();
    row.number = row.packetId.toULongLong();

    const QString timestamp = summary.value(QStringLiteral("timestamp")).toString();
    QDateTime dateTime = QDateTime::fromString(timestamp, Qt::ISODateWithMs);
    if (!dateTime.isValid())
        dateTime = QDateTime::fromString(timestamp, Qt::ISODate);
    row.timeText = dateTime.isValid()
        ? dateTime.toLocalTime().toString(QStringLiteral("HH:mm:ss.zzz"))
        : timestamp;
    row.timestampMs = dateTime.isValid() ? dateTime.toMSecsSinceEpoch() : 0;

    const QVariantMap source = summary.value(QStringLiteral("source")).toMap();
    const QVariantMap destination = summary.value(QStringLiteral("destination")).toMap();
    row.source = endpointAddress(source);
    row.sourcePort = endpointPort(source);
    row.destination = endpointAddress(destination);
    row.destinationPort = endpointPort(destination);

    row.protocol = summary.value(QStringLiteral("protocol")).toString();
    if (row.protocol.isEmpty()) {
        row.protocol = summary.value(QStringLiteral("transport")).toString().toUpper();
    }

    const QVariant client = summary.value(QStringLiteral("client"));
    if (client.canConvert<QVariantMap>()) {
        const QVariantMap clientMap = client.toMap();
        row.client = clientMap.value(QStringLiteral("display_name")).toString();
        if (row.client.isEmpty())
            row.client = clientMap.value(QStringLiteral("name")).toString();
        // Prefer the executable path as the stable app identity; display names
        // can collide (multiple Python tools, helper processes, etc.).
        row.clientKey = clientMap.value(QStringLiteral("executable_path")).toString().trimmed();
        if (row.clientKey.isEmpty())
            row.clientKey = row.client.trimmed();
        row.clientPid = clientMap.value(QStringLiteral("pid")).toInt();
    }

    row.domain = summary.value(QStringLiteral("sni")).toString();
    if (row.domain.isEmpty())
        row.domain = summary.value(QStringLiteral("dns_name")).toString();

    row.streamId = summary.value(QStringLiteral("stream_id")).toString();
    row.summary = summary.value(QStringLiteral("info")).toString();
    row.tcpFlags = summary.value(QStringLiteral("tcp_flags")).toString();
    row.direction = summary.value(QStringLiteral("direction")).toString();
    row.interfaceName = summary.value(QStringLiteral("interface")).toString();
    row.decodeStatus = summary.value(QStringLiteral("decode_status")).toString();
    // The daemon flags TCP-issue packets (retransmission, RST, zero-window,
    // …) the same way the Overview classifies them; 1 renders the summary in
    // the warning color so problem rows stand out like the Errors chip.
    row.severity = summary.value(QStringLiteral("severity")).toString() == QStringLiteral("warning")
        ? 1
        : 0;
    row.sourceKind = summary.value(QStringLiteral("source_kind")).toString();
    row.comment = summary.value(QStringLiteral("comment")).toString();
    row.length = summary.value(QStringLiteral("length")).toInt();
    row.originalLength = summary.value(QStringLiteral("original_length")).toInt();
    row.tcpPayloadLength = summary.value(QStringLiteral("tcp_payload_length")).toInt();
    return row;
}

// Overview card picker persistence. Unknown or duplicate names (a newer
// version, hand-edited INI) are skipped, mirroring upstream's
// CaptureOverviewCardLayoutStore.
QVariantList SessionController::overviewCards() const
{
    QSettings settings;
    QStringList names = settings.value(QStringLiteral("overview/cards"))
                            .toStringList();
    static const QStringList known = {
        QStringLiteral("packets"), QStringLiteral("throughput"),
        QStringLiteral("protocols"), QStringLiteral("topApps"),
        QStringLiteral("topDestinations"), QStringLiteral("tcpAnalysis"),
        QStringLiteral("conversations"), QStringLiteral("services"),
        QStringLiteral("packetLengths"),
    };
    // v2 adds Top Conversations and Services & Ports to the original six-card
    // default layout, making Services the last chart before the Add Chart
    // cell. Migrate only untouched legacy defaults; custom layouts are kept.
    static const QStringList legacyDefaults = {
        QStringLiteral("packets"), QStringLiteral("throughput"),
        QStringLiteral("protocols"), QStringLiteral("topApps"),
        QStringLiteral("topDestinations"), QStringLiteral("tcpAnalysis"),
    };
    static const QStringList currentDefaults = {
        QStringLiteral("packets"), QStringLiteral("throughput"),
        QStringLiteral("protocols"), QStringLiteral("topApps"),
        QStringLiteral("topDestinations"), QStringLiteral("tcpAnalysis"),
        QStringLiteral("conversations"), QStringLiteral("services"),
    };
    const int layoutVersion = settings.value(QStringLiteral("overview/cardsVersion"), 1).toInt();
    if (layoutVersion < 2) {
        if (names.isEmpty() || names == legacyDefaults) {
            names = currentDefaults;
            settings.setValue(QStringLiteral("overview/cards"), names);
        }
        settings.setValue(QStringLiteral("overview/cardsVersion"), 2);
    }
    QVariantList result;
    for (const QString &name : names) {
        if (known.contains(name) && !result.contains(name))
            result.append(name);
    }
    return result;
}

void SessionController::setOverviewCards(const QVariantList &cards)
{
    QStringList names;
    for (const QVariant &card : cards) {
        const QString name = card.toString();
        if (!name.isEmpty() && !names.contains(name))
            names.append(name);
    }
    QSettings settings;
    settings.setValue(QStringLiteral("overview/cards"), names);
    settings.setValue(QStringLiteral("overview/cardsVersion"), 2);
}
