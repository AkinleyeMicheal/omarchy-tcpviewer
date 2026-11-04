#include "sessioncontroller.h"

#include <QClipboard>
#include <QDateTime>
#include <QFile>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSet>
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
    connect(m_client, &DaemonClient::responseObject,
            this, &SessionController::handlePacketListResponse);
    connect(m_client, &DaemonClient::requestFailure,
            this, &SessionController::handleResponseRequestFailure);
    connect(m_client, &DaemonClient::failure, this, &SessionController::handleFailure);
    connect(m_client, &DaemonClient::event, this, &SessionController::handleEvent);
    connect(m_sourceTree, &SourceTreeModel::countChanged,
            this, &SessionController::applyTreeSelectHook);

    // CI hooks: start a live capture once interfaces are known, and select a
    // source-tree node after its first matching packet batch arrives.
    m_startupCaptureIface = qEnvironmentVariable("TCPVIEWER_CAPTURE_IFACE");
    m_treeSelectNode = qEnvironmentVariable("TCPVIEWER_TREE_SELECT");
    m_startupFilter = qEnvironmentVariable("TCPVIEWER_FILTER").trimmed();
    m_deleteRowsHook = qEnvironmentVariable("TCPVIEWER_DELETE_ROWS");
    // CI/test hook: preselect quick-filter chips (e.g. "tcp", "errors")
    // so filtered-table flows can be captured without a mouse click.
    const QStringList quickHook =
        qEnvironmentVariable("TCPVIEWER_QUICK_FILTERS").split(u',', Qt::SkipEmptyParts);
    for (const QString &chip : quickHook) {
        const QString id = chip.trimmed();
        if (!id.isEmpty())
            m_quickFilters.append(id);
    }
    // CI/test hook: seed the structured builder stage (TCPVIEWER_STRUCTURED),
    // rows separated by ';' with 'field|condition|text|enabled' each; the
    // join comes from TCPVIEWER_STRUCTURED_JOIN ("and"/"or", default and).
    const QString structuredHook = qEnvironmentVariable("TCPVIEWER_STRUCTURED");
    if (!structuredHook.trimmed().isEmpty()) {
        const QStringList parts = structuredHook.split(u';', Qt::SkipEmptyParts);
        for (const QString &part : parts) {
            const QStringList fields = part.split(u'|');
            if (fields.size() < 3)
                continue;
            QVariantMap row{
                {QStringLiteral("field"), fields.at(0).trimmed()},
                {QStringLiteral("condition"), fields.at(1).trimmed()},
                {QStringLiteral("text"), fields.at(2).trimmed()},
                {QStringLiteral("enabled"),
                 fields.size() < 4 || fields.at(3).trimmed() != QStringLiteral("0")},
            };
            m_structuredRows.append(row);
        }
        m_structuredJoin = qEnvironmentVariable("TCPVIEWER_STRUCTURED_JOIN")
            == QStringLiteral("or") ? QStringLiteral("or") : QStringLiteral("and");
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
            const QString mode =
                settings.value(QStringLiteral("mode")).toString();
            if (mode == QStringLiteral("builder")) {
                const QVariantList rows =
                    settings.value(QStringLiteral("rows")).toList();
                const QString join =
                    settings.value(QStringLiteral("join")).toString();
                if (!name.isEmpty() && !rows.isEmpty()) {
                    m_savedFilters.append(QVariantMap{
                        {QStringLiteral("name"), name},
                        {QStringLiteral("mode"), QStringLiteral("builder")},
                        {QStringLiteral("rows"), rows},
                        {QStringLiteral("join"),
                         join == QStringLiteral("or") ? QStringLiteral("or")
                                                      : QStringLiteral("and")},
                    });
                }
                continue;
            }
            const QString query =
                settings.value(QStringLiteral("query")).toString().trimmed();
            if (!name.isEmpty() && !query.isEmpty()) {
                m_savedFilters.append(QVariantMap{
                    {QStringLiteral("name"), name},
                    // Legacy entries predate the mode field (all expressions).
                    {QStringLiteral("mode"), QStringLiteral("expression")},
                    {QStringLiteral("query"), query},
                });
            }
        }
        settings.endArray();
    }

    // Pinned sources + saved packets (C2): app-side persistence in QSettings,
    // beside the display-filter favorites. Pins use explicit fields (the
    // filters pattern); saved rows serialize one JSON record each — a full
    // PacketRow has too many fields for named keys.
    {
        QSettings settings;
        const int pinCount = settings.beginReadArray(QStringLiteral("pins"));
        for (int i = 0; i < pinCount; ++i) {
            settings.setArrayIndex(i);
            PinRecord pin;
            pin.id = settings.value(QStringLiteral("id")).toString();
            pin.kind = settings.value(QStringLiteral("kind")).toString();
            pin.title = settings.value(QStringLiteral("title")).toString();
            pin.domain = settings.value(QStringLiteral("domain")).toString();
            pin.ip = settings.value(QStringLiteral("ip")).toString();
            pin.clientKey = settings.value(QStringLiteral("clientKey")).toString();
            pin.clientDisplay =
                settings.value(QStringLiteral("clientDisplay")).toString();
            pin.iconPath = settings.value(QStringLiteral("iconPath")).toString();
            pin.createdAtMs = settings.value(QStringLiteral("createdAt")).toLongLong();
            m_pinStore.upsert(pin);
        }
        settings.endArray();

        QVariantList savedValues;
        const int savedRows = settings.beginReadArray(QStringLiteral("packets/saved"));
        for (int i = 0; i < savedRows; ++i) {
            settings.setArrayIndex(i);
            const QJsonObject object = QJsonDocument::fromJson(
                settings.value(QStringLiteral("record")).toString().toUtf8()).object();
            if (!object.isEmpty())
                savedValues.append(object.toVariantMap());
        }
        settings.endArray();
        m_savedStore.loadFromVariantList(savedValues);
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

    // CI/test hook: cancel the startup import after a delay so the cancel
    // path can be captured offscreen (import starts, button path fires, no
    // error banner, loading clears).
    bool cancelHookOk = false;
    const int cancelHookMs = qEnvironmentVariableIntValue("TCPVIEWER_CANCEL_IMPORT_MS", &cancelHookOk);
    if (cancelHookOk && cancelHookMs > 0) {
        QTimer::singleShot(cancelHookMs, this, [this]() {
            if (importing())
                cancelImport();
        });
    }

    // CI/test hook: start in the Saved workspace so fixture screenshots can
    // capture starred rows and the sidebar count without a click path. The
    // fixed 1500 ms wait lets an OPEN_FILES import and its file.session_state
    // reply (document-scoped saved records) land before the selector runs.
    if (qEnvironmentVariableIsSet("TCPVIEWER_SAVED_VIEW")) {
        bool ok = false;
        const int delayMs = qEnvironmentVariableIntValue("TCPVIEWER_SAVED_VIEW_DELAY_MS", &ok);
        QTimer::singleShot(ok && delayMs > 0 ? delayMs : 1500, this, [this]() { selectSavedPackets(); });
    }

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
    if (!m_client->connected()) {
        setStopInFlight(false);
        return;
    }

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

void SessionController::startCapture(const QString &interfaceID, const QString &bpfExpression)
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
    QVariantMap params;
    params.insert(QStringLiteral("interface"), interface);
    // Fixture hook: start a live capture carrying a BPF filter so the
    // toolbar indicator and speeds can be shot deterministically. The app UI
    // itself never edits the filter (upstream rule: read-only, set by the
    // CLI/agents).
    const QString mappableBPF = !bpfExpression.isEmpty()
        ? bpfExpression
        : qEnvironmentVariable("TCPVIEWER_CAPTURE_FILTER").trimmed();
    if (!mappableBPF.isEmpty())
        params.insert(QStringLiteral("bpf"), mappableBPF);
    m_client->send(QStringLiteral("capture.start"), params);
}

void SessionController::stopCapture()
{
    if (!m_client->connected())
        return;
    // Immediate button feedback: the daemon may take a while (queued reads,
    // in-flight follow ops) before the stop reply reports "stopped".
    setStopInFlight(true);
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
    // Multi-file progress (upstream importer): remember the requested order;
    // refreshSources() re-counts finished files as their sources land.
    m_importPaths = paths;
    emit sourcesChanged();
    m_client->send(QStringLiteral("file.import"),
                   {{QStringLiteral("paths"), paths}}, 300);
}

// Upstream importer cancellation: the daemon cancels the in-flight document
// load, closes the loading sources and skips the remaining files. The
// follow-up file.import failure arrives as operation_cancelled and is
// handled silently in handleFailure().
void SessionController::cancelImport()
{
    m_pendingSelectPath.clear();
    m_importPaths.clear();
    emit sourcesChanged();
    emit loadingChanged();
    m_client->send(QStringLiteral("import.cancel"));
}

QVariantMap SessionController::importProgress() const
{
    QVariantMap progress;
    progress.insert(QStringLiteral("files"), m_importPaths.size());
    int loaded = 0;
    for (const QString &path : m_importPaths) {
        for (const QVariant &value : m_sources) {
            const QVariantMap source = value.toMap();
            if (source.value(QStringLiteral("path")).toString() != path)
                continue;
            const QString phase = source.value(QStringLiteral("phase")).toString();
            if (phase == QStringLiteral("loaded") || phase == QStringLiteral("failed"))
                ++loaded;
            break;
        }
    }
    progress.insert(QStringLiteral("loaded"), loaded);
    return progress;
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
    // Sidebar switches leave the Saved workspace for the real source flow.
    if (m_savedMode) {
        m_savedMode = false;
        emit savedModeChanged();
        m_lastNonSavedSourceID.clear();
        selectSourceInternal(sourceID);
        return;
    }
    if (sourceID == m_currentSourceID) {
        resetStream();
        return;
    }
    selectSourceInternal(sourceID);
}

void SessionController::selectSourceInternal(const QString &sourceID)
{
    clearSelection();
    if (m_savedMode) {
        // Defensive: every path into a real source leaves the saved view.
        m_savedMode = false;
        emit savedModeChanged();
        m_lastNonSavedSourceID.clear();
    }
    // Pinned-source selection resets with the scope like the tree's own
    // selection does; the applied filter stays source-sticky as before.
    if (!m_selectedPinID.isEmpty()) {
        m_selectedPinID.clear();
        emit pinsChanged();
    }
    m_currentSourceID = sourceID;
    m_customColumns->setSourceID(sourceID);
    m_status.clear();
    setStopInFlight(false);
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

    // Document-scoped pins for session bundles (upstream
    // PacketPinService.documentRecords): ask for the carried pins; the reply
    // installs (or clears) the overlay keyed by this source.
    if (m_client->connected()) {
        m_client->send(QStringLiteral("file.session_state"),
                       {{QStringLiteral("source_id"), sourceID}});
    }
}

void SessionController::clearPackets()
{
    if (m_savedMode) {
        // The Saved workspace version of "Clear All Packets" empties the
        // starred list itself (nothing is held daemon-side). Document-scoped
        // overlays clear in memory like the rest of their mutations.
        const bool persisted = activeSavedStore() == &m_savedStore;
        activeSavedStore()->clear();
        if (persisted)
            persistSavedPackets();
        emit savedPacketsChanged();
        m_packets->clear();
        return;
    }
    if (!m_client->connected() || m_currentSourceID.isEmpty())
        return;
    m_client->send(QStringLiteral("packets.clear"),
                   {{QStringLiteral("source_id"), m_currentSourceID},
                    {QStringLiteral("yes"), true}});
}

void SessionController::copyPlainText(const QString &text)
{
    if (text.isEmpty())
        return;
    QGuiApplication::clipboard()->setText(text);
}

// MARK: - Packet annotations

void SessionController::setPacketHighlightColor(const QString &packetID, const QString &colorName)
{
    if (colorName.isEmpty())
        return;
    PacketListModel::AnnotationChange change;
    change.hasHighlightChange = true;
    change.highlightColorChange = colorName;
    dispatchPacketAnnotation(packetID, change,
                             QStringLiteral("packets.set_style"),
                             {{"op", QStringLiteral("set_highlight")},
                              {"color", colorName}});
}

void SessionController::togglePacketStrikethrough(const QString &packetID)
{
    PacketListModel::AnnotationChange change;
    change.strikeToggle = true;
    dispatchPacketAnnotation(packetID, change,
                             QStringLiteral("packets.set_style"),
                             {{"op", QStringLiteral("toggle_strikethrough")}});
}

void SessionController::resetPacketTextStyle(const QString &packetID)
{
    PacketListModel::AnnotationChange change;
    change.styleReset = true;
    dispatchPacketAnnotation(packetID, change,
                             QStringLiteral("packets.set_style"),
                             {{"op", QStringLiteral("reset")}});
}

// Upstream deletePackets for the packet workspace (context menu / Delete
// key): rows leave the ingest state with "Deleted N packet(s)." status.
// Like the annotation mutators, the local model mirrors first; the daemon
// owns the buffers via packets.delete. A daemon-side failure (source gone,
// unknown ids) re-syncs the table through resetStream.
void SessionController::deletePacketRows(const QVariantList &rows)
{
    if (m_savedMode || m_currentSourceID.isEmpty() || m_loading)
        return;

    // Row indexes become invalid after the removal, so resolve ids — and
    // selection-hop candidates (upstream nextVisiblePacketIDAfterDeleting:
    // the first surviving row after the block, else the one before it) —
    // while the rows are still in place.
    QVariantList doomed;
    QSet<QString> doomedIDs;
    QSet<int> doomedRows;
    int lowestRow = -1;
    int highestRow = -1;
    for (const QVariant &value : rows) {
        bool ok = false;
        const int row = value.toInt(&ok);
        if (!ok || row < 0)
            continue;
        const QString packetID = m_packets->packetIDAt(row);
        if (packetID.isEmpty() || doomedIDs.contains(packetID))
            continue;
        doomedIDs.insert(packetID);
        doomedRows.insert(row);
        doomed.append(packetID);
        lowestRow = lowestRow < 0 ? row : qMin(lowestRow, row);
        highestRow = highestRow < 0 ? row : qMax(highestRow, row);
    }
    if (doomed.isEmpty() || doomed.size() > 5'000)
        return;

    const bool selectionHit = doomedIDs.contains(m_selectedPacketID);
    QString hopID;
    if (selectionHit) {
        for (int row = highestRow + 1; row < m_packets->count(); ++row) {
            if (!doomedRows.contains(row)) {
                hopID = m_packets->packetIDAt(row);
                break;
            }
        }
        if (hopID.isEmpty()) {
            for (int row = lowestRow - 1; row >= 0; --row) {
                if (!doomedRows.contains(row)) {
                    hopID = m_packets->packetIDAt(row);
                    break;
                }
            }
        }
    }

    // Sidebar aggregates shrink with the same rows (upstream's snapshot
    // rebuild drops the deleted packets from the source tree too).
    QVector<PacketRow> treeRows;
    treeRows.reserve(doomedRows.size());
    for (const QVariant &value : rows) {
        bool ok = false;
        const int row = value.toInt(&ok);
        if (!ok || row < 0)
            continue;
        treeRows.append(packetRowFromMap(m_packets->rowSnapshotAt(row)));
    }

    const int removed = m_packets->removeByIds(QStringList(doomedIDs.values()));
    if (removed == 0)
        return;
    if (!treeRows.isEmpty())
        m_sourceTree->removeRows(treeRows);
    if (selectionHit)
        selectPacket(hopID);  // empty id clears the selection

    m_pendingDeleteCount = removed;
    m_client->send(QStringLiteral("packets.delete"),
                   {{QStringLiteral("source_id"), m_currentSourceID},
                    {QStringLiteral("packet_ids"), doomed}});
}

void SessionController::triggerDeleteRowsHook()
{
    if (m_deleteHookFired || m_deleteRowsHook.isEmpty())
        return;
    QVariantList rows;
    int highest = -1;
    const QStringList parts = m_deleteRowsHook.split(u',', Qt::SkipEmptyParts);
    for (const QString &part : parts) {
        bool ok = false;
        const int row = part.trimmed().toInt(&ok);
        if (!ok || row < 0)
            return;
        if (row > highest)
            highest = row;
        rows.append(row);
    }
    // Rows not onscreen yet; the next page arrival retries.
    if (highest < 0 || highest >= m_packets->count())
        return;
    m_deleteHookFired = true;
    // Deferred one event turn so the seeded selection mirrors the mouse flow
    // before the delete (the keyboard path acts on a live selection too).
    QTimer::singleShot(0, this, [this, rows]() { deletePacketRows(rows); });
}

// Bulk targets (upstream keyboard + menu mutations apply to the whole
// selection): id order follows the given rows, duplicates skipped.
void SessionController::setPacketHighlightColors(const QVariantList &packetIDs,
                                                 const QString &colorName)
{
    if (colorName.isEmpty())
        return;
    for (const QVariant &packetID : packetIDs)
        setPacketHighlightColor(packetID.toString(), colorName);
}

void SessionController::togglePacketStrikethroughs(const QVariantList &packetIDs)
{
    for (const QVariant &packetID : packetIDs)
        togglePacketStrikethrough(packetID.toString());
}

void SessionController::resetPacketTextStyles(const QVariantList &packetIDs)
{
    for (const QVariant &packetID : packetIDs)
        resetPacketTextStyle(packetID.toString());
}

void SessionController::setPacketComment(const QString &packetID, const QString &comment)
{
    // Client mirror of upstream PacketComment.sanitized: CRLF → LF, trim,
    // cap at 1000 characters. Empty stays a no-op (upstream v1 offers no
    // comment removal — the sheet only submits non-empty text).
    QString normalized = comment;
    normalized.replace(QStringLiteral("\r\n"), QStringLiteral("\n"));
    normalized.replace(QLatin1Char('\r'), QLatin1Char('\n'));
    normalized = normalized.trimmed();
    if (normalized.size() > 1000)
        normalized = normalized.left(1000).trimmed();
    if (normalized.isEmpty())
        return;

    PacketListModel::AnnotationChange change;
    change.hasCommentChange = true;
    change.commentChange = normalized;
    dispatchPacketAnnotation(packetID, change,
                             QStringLiteral("packets.set_comment"),
                             {{"comment", normalized}});
}

void SessionController::dispatchPacketAnnotation(
    const QString &packetID, PacketListModel::AnnotationChange change,
    const QString &command, QVariantMap params)
{
    bool ok = false;
    const quint64 id = packetID.toULongLong(&ok);
    if (!ok || id == 0)
        return;

    // Upstream mutates its ingest state synchronously; the model mirror
    // gives the same zero-latency row feedback (the reply path only
    // handles failures).
    PacketListModel::AnnotationChange applied = change;
    m_packets->applyAnnotation({id}, applied);

    // Saved workspace: no daemon backing — records ARE the copies, write
    // through and stop.
    if (m_savedMode) {
        if (activeSavedStore()->applyAnnotation({id}, change) > 0) {
            if (activeSavedStore() == &m_savedStore)
                persistSavedPackets();
            emit savedPacketsChanged();
        }
        return;
    }

    // Starred copies backed by the active capture stay in sync with it
    // (upstream backingIdentity == active ingest identity rule); document
    // overlays mirror without persisting.
    if (!m_currentSourceID.isEmpty()
        && activeSavedStore()->applyAnnotation({id}, change, m_currentSourceID) > 0) {
        if (activeSavedStore() == &m_savedStore)
            persistSavedPackets();
        emit savedPacketsChanged();
    }

    if (!m_client->connected() || m_currentSourceID.isEmpty())
        return;
    params.insert(QStringLiteral("source_id"), m_currentSourceID);
    params.insert(QStringLiteral("packet_ids"), QVariantList{packetID});
    m_client->send(command, params);
}


void SessionController::applyFilter(const QString &filter)
{
    if (filter == m_filterText) {
        resetStream();
        return;
    }
    // Applying starts a new validation cycle: drop any stale error state.
    setFilterError(QString(), QVariantMap());
    // Snapshot for display-filter reverts: an invalid expression is refused
    // by the daemon (which also drops its own index), so the request state
    // goes back to the last valid expression while the field keeps the draft.
    m_previousFilter = m_filterText;
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

// Builder rows flow to the daemon as-is (field/condition/text/enabled);
// validation lives in the daemon (unknown field/condition → query error).
// Rows absent or stateless → the request omits the structured stage.
void SessionController::setStructuredFilter(const QVariantList &rows, const QString &join)
{
    QVariantList next;
    for (const QVariant &value : rows) {
        const QVariantMap map = value.toMap();
        if (map.value(QStringLiteral("field")).toString().isEmpty()
            || map.value(QStringLiteral("condition")).toString().isEmpty())
            continue;
        next.append(map);
    }
    const QString nextJoin = join == QStringLiteral("or") ? QStringLiteral("or") : QStringLiteral("and");
    if (next == m_structuredRows && nextJoin == m_structuredJoin)
        return;
    clearSelection();
    m_structuredRows = next;
    m_structuredJoin = nextJoin;
    emit structuredFilterChanged();
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
        settings.setValue(QStringLiteral("mode"),
                          map.value(QStringLiteral("mode"),
                                    QStringLiteral("expression")));
        if (map.value(QStringLiteral("mode")).toString() == QStringLiteral("builder")) {
            settings.setValue(QStringLiteral("rows"), map.value(QStringLiteral("rows")));
            settings.setValue(QStringLiteral("join"), map.value(QStringLiteral("join")));
        } else {
            settings.setValue(QStringLiteral("query"),
                              map.value(QStringLiteral("query")));
        }
    }
    settings.endArray();
}

// Structured presets (upstream PacketCustomFilterService.save(mode: .builder)):
// same name validation as expressions; a re-save under the same name replaces
// the payload. Rows carry {field, condition, text, enabled} keyed by the
// daemon's structured IPC contract.
QString SessionController::saveStructuredFilter(const QString &name,
                                                const QVariantList &rows,
                                                const QString &join)
{
    const QString trimmedName = name.trimmed();
    if (trimmedName.isEmpty())
        return QStringLiteral("Enter a filter name.");
    if (trimmedName.size() > 40)
        return QStringLiteral("Filter names must be 40 characters or fewer.");

    QVariantList payloadRows;
    for (const QVariant &value : rows) {
        const QVariantMap map = value.toMap();
        if (map.value(QStringLiteral("field")).toString().isEmpty()
            || map.value(QStringLiteral("condition")).toString().isEmpty())
            continue;
        payloadRows.append(map);
    }
    if (payloadRows.isEmpty())
        return QStringLiteral("Build at least one condition first.");

    bool replaced = false;
    for (QVariant &entry : m_savedFilters) {
        QVariantMap map = entry.toMap();
        if (map.value(QStringLiteral("mode")).toString() == QStringLiteral("builder")
            && map.value(QStringLiteral("name")).toString() == trimmedName) {
            map.insert(QStringLiteral("rows"), payloadRows);
            map.insert(QStringLiteral("join"),
                       join == QStringLiteral("or") ? QStringLiteral("or")
                                                    : QStringLiteral("and"));
            entry = map;
            replaced = true;
            break;
        }
    }
    if (!replaced) {
        m_savedFilters.append(QVariantMap{
            {QStringLiteral("name"), trimmedName},
            {QStringLiteral("mode"), QStringLiteral("builder")},
            {QStringLiteral("rows"), payloadRows},
            {QStringLiteral("join"),
             join == QStringLiteral("or") ? QStringLiteral("or") : QStringLiteral("and")},
        });
    }
    persistSavedFilters();
    emit filtersChanged();
    return QString();
}

// MARK: - Pinned sources + saved packets (C2)

QVariantList SessionController::pinnedItems() const
{
    QVariantList values;
    const PinStore *store = activePinStore();
    values.reserve(store->count());
    for (const PinRecord &pin : store->records()) {
        values.append(QVariantMap{
            {QStringLiteral("id"), pin.id},
            {QStringLiteral("kind"), pin.kind},
            {QStringLiteral("title"), pin.title},
            {QStringLiteral("domain"), pin.domain},
            {QStringLiteral("ip"), pin.ip},
            {QStringLiteral("clientKey"), pin.clientKey},
            {QStringLiteral("clientDisplay"), pin.clientDisplay},
        });
    }
    return values;
}

void SessionController::persistPins()
{
    QSettings settings;
    settings.remove(QStringLiteral("pins"));
    settings.beginWriteArray(QStringLiteral("pins"));
    for (int i = 0; i < m_pinStore.count(); ++i) {
        settings.setArrayIndex(i);
        const QVariantMap map = m_pinStore.records().at(i).toMap();
        settings.setValue(QStringLiteral("id"), map.value(QStringLiteral("id")));
        settings.setValue(QStringLiteral("kind"), map.value(QStringLiteral("kind")));
        settings.setValue(QStringLiteral("title"), map.value(QStringLiteral("title")));
        settings.setValue(QStringLiteral("domain"), map.value(QStringLiteral("domain")));
        settings.setValue(QStringLiteral("ip"), map.value(QStringLiteral("ip")));
        settings.setValue(QStringLiteral("clientKey"), map.value(QStringLiteral("clientKey")));
        settings.setValue(QStringLiteral("clientDisplay"),
                          map.value(QStringLiteral("clientDisplay")));
        settings.setValue(QStringLiteral("iconPath"), map.value(QStringLiteral("iconPath")));
        settings.setValue(QStringLiteral("createdAt"), map.value(QStringLiteral("createdAt")));
    }
    settings.endArray();
}

void SessionController::persistSavedPackets()
{
    QSettings settings;
    settings.remove(QStringLiteral("packets/saved"));
    settings.beginWriteArray(QStringLiteral("packets/saved"));
    const QVariantList values = m_savedStore.toVariantList();
    for (int i = 0; i < values.size(); ++i) {
        settings.setArrayIndex(i);
        settings.setValue(QStringLiteral("record"),
                          QString::fromUtf8(QJsonDocument(
                              QJsonObject::fromVariantMap(values.at(i).toMap()))
                                                .toJson(QJsonDocument::Compact)));
    }
    settings.endArray();
}

void SessionController::pinDomain(const QString &domain)
{
    const QString normalized = normalizedPacketDomain(domain);
    if (normalized.isEmpty())
        return;
    PinRecord pin;
    pin.kind = QStringLiteral("domain");
    pin.title = normalized;
    pin.domain = normalized;
    pin.id = PinStore::idFor(pin.kind, normalized);
    const PinRecord stored = m_pinStore.upsert(pin);
    if (stored.isValid()) {
        persistPins();
        emit pinsChanged();
    }
}

void SessionController::pinIPAddress(const QString &address)
{
    const QString normalized = normalizedPacketIP(address);
    if (normalized.isEmpty())
        return;
    PinRecord pin;
    pin.kind = QStringLiteral("ip");
    pin.title = normalized;
    pin.ip = normalized;
    pin.id = PinStore::idFor(pin.kind, normalized);
    const PinRecord stored = m_pinStore.upsert(pin);
    if (stored.isValid()) {
        persistPins();
        emit pinsChanged();
    }
}

void SessionController::pinPacketAt(int row)
{
    // Upstream packet-table "Pin" pins the selected app identity (client);
    // rows without a client keep the item disabled.
    const QString clientKey = m_packets->clientKeyAt(row);
    if (clientKey.isEmpty())
        return;
    PinRecord pin;
    pin.kind = QStringLiteral("client");
    pin.clientKey = clientKey;
    pin.clientDisplay = m_packets->clientNameAt(row);
    pin.title = pin.clientDisplay.isEmpty() ? clientKey.section(QLatin1Char('/'), -1)
                                            : pin.clientDisplay;
    pin.id = PinStore::idFor(pin.kind, clientKey);
    const PinRecord stored = m_pinStore.upsert(pin);
    if (!stored.isValid())
        return;

    // Upstream selectAfterPinning: the table re-scopes to the new pin.
    persistPins();
    emit pinsChanged();
    selectPin(stored.id);
}

void SessionController::removePin(const QString &pinID)
{
    const bool removed = activePinStore() == &m_pinStore
        ? m_pinStore.remove(pinID)
        : m_documentPins[m_currentSourceID].remove(pinID);
    if (!removed)
        return;

    // Persistent pins write through; document overlays are memory-only
    // (upstream persists them with the document on Save; ours re-decode).
    if (activePinStore() == &m_pinStore)
        persistPins();
    if (m_selectedPinID == pinID) {
        m_selectedPinID.clear();
        m_packets->clearTreeFilter();
        m_sourceTree->clearNodeSelection();
    }
    emit pinsChanged();
}

void SessionController::selectPin(const QString &pinID)
{
    const PinRecord pin = activePinStore()->find(pinID);
    if (!pin.isValid())
        return;
    if (m_savedMode)
        leaveSavedMode();

    // Upstream selection is a single enum: picking a pin leaves the tree
    // node selection behind; picking a tree node/filters leaves the pin.
    clearSelection();
    m_sourceTree->clearNodeSelection();
    if (pin.kind == QStringLiteral("domain"))
        m_packets->setTreeFilter(QString(), pin.domain, QString(), false, false);
    else if (pin.kind == QStringLiteral("ip"))
        m_packets->setTreeFilter(QString(), QString(), pin.ip, false, false);
    else if (pin.kind == QStringLiteral("client"))
        m_packets->setTreeFilter(pin.clientKey, QString(), QString(), false, false);
    else
        return;

    m_selectedPinID = pinID;
    emit pinsChanged();
}

void SessionController::savePacketAt(int row)
{
    const QString packetID = m_packets->packetIDAt(row);
    if (packetID.isEmpty() || m_savedMode)
        return;
    const PacketRow saved = packetRowFromMap(m_packets->rowSnapshotAt(row));
    // The snapshot's own id is authoritative; guard against a model/daemon
    // mismatch by re-checking the readback.
    if (saved.packetId.isEmpty() || saved.packetId != packetID)
        return;
    SavedPacketStore *store = activeSavedStore();
    const int added = store->add({saved}, m_currentSourceID);
    if (added == 0)
        return;
    // Document-scoped saves stay in the overlay (never persisted here);
    // they ride the source's next export like the carried state.
    if (store == &m_savedStore)
        persistSavedPackets();
    emit savedPacketsChanged();
}

void SessionController::removeSavedPacket(const QString &packetID)
{
    // Starred rows with matching ids from different sources can coexist
    // (pcap numbering restarts); removal targets the first ordered record,
    // the visible one, so a second removal clears the next copy.
    const bool persisted = activeSavedStore() == &m_savedStore;
    if (!activeSavedStore()->remove(packetID))
        return;
    if (persisted)
        persistSavedPackets();
    emit savedPacketsChanged();
    if (!m_savedMode)
        return;
    const SavedPacketStore *store = activeSavedStore();
    QVector<PacketRow> rows;
    rows.reserve(store->count());
    for (const SavedPacketRecord &record : store->records())
        rows.append(record.row);
    m_packets->clear();
    m_packets->appendRows(rows);
}

void SessionController::selectSavedPackets()
{
    if (m_savedMode)
        return;
    m_lastNonSavedSourceID = m_currentSourceID;

    // Invalidates any in-flight packets.list page for the previous source.
    m_streamEpoch++;
    m_pageEpoch.clear();
    m_savedMode = true;
    emit savedModeChanged();

    clearSelection();
    m_selectedPinID.clear();
    emit pinsChanged();
    m_sourceTree->clearNodeSelection();
    m_packets->clearTreeFilter();
    m_currentSourceID.clear();
    emit currentSourceChanged();

    // The active store was resolved while the bundle source was still the
    // table scope; tooltips and the Saved rows now render it.
    const SavedPacketStore *store = activeSavedStore();
    QVector<PacketRow> rows;
    rows.reserve(store->count());
    for (const SavedPacketRecord &record : store->records())
        rows.append(record.row);
    m_packets->clearTreeFilter();
    m_packets->clear();
    m_packets->appendRows(rows);
    setLoading(false);
}

void SessionController::leaveSavedMode()
{
    if (!m_savedMode)
        return;
    m_savedMode = false;
    emit savedModeChanged();
    const QString previousSource = m_lastNonSavedSourceID;
    m_lastNonSavedSourceID.clear();
    m_sourceTree->clearNodeSelection();
    if (!previousSource.isEmpty()) {
        selectSourceInternal(previousSource);
    } else {
        m_packets->clearTreeFilter();
        m_packets->clear();
        setLoading(false);
    }
}

void SessionController::handleSessionState(const QVariantMap &data)
{
    // Document-scoped pins: a session document's pins replace the persistent
    // list while its source is open; a state without pins clears the overlay.
    // The reply echoes the source, so rapid switches stay attributable
    // without request-id bookkeeping on the client.
    const QString sourceID = data.value(QStringLiteral("source_id")).toString();
    if (sourceID.isEmpty())
        return;

    bool changed = false;
    PinStore document;
    for (const QVariant &value : data.value(QStringLiteral("pins")).toList()) {
        const PinRecord pin = PinStore::fromSessionPin(value.toMap());
        if (pin.isValid())
            document.upsert(pin);
    }
    if (document.count() > 0)
        m_documentPins.insert(sourceID, document);
    else
        m_documentPins.remove(sourceID);
    if (sourceID == m_currentSourceID)
        changed = true;

    // Document-scoped saved packets ride the same state reply (upstream
    // SavedPacketService useDocumentRecords): each record carries a full
    // summary row in the packets.list shape, so mirrors and the Saved
    // workspace work without extra round-trips.
    QVariantList recordMaps;
    for (const QVariant &value : data.value(QStringLiteral("saved_records")).toList()) {
        const QVariantMap record = value.toMap();
        const QString packetId = record.value(QStringLiteral("id")).toString();
        if (packetId.isEmpty())
            continue;
        const PacketRow row = parseSummary(record.value(QStringLiteral("packet")).toMap());
        if (row.packetId.isEmpty() && packetId.isEmpty())
            continue;
        PacketRow identified = row;
        identified.packetId = packetId;
        QVariantMap map = packetRowToMap(identified);
        map.insert(QStringLiteral("packetId"), packetId);
        map.insert(QStringLiteral("savedAt"),
                   qint64(record.value(QStringLiteral("saved_at")).toDouble() * 1000.0));
        map.insert(QStringLiteral("backing"),
                   record.value(QStringLiteral("backing")).toString());
        recordMaps.append(map);
    }
    SavedPacketStore saved;
    saved.loadFromVariantList(recordMaps);
    if (saved.count() > 0)
        m_documentSaved.insert(sourceID, saved);
    else
        m_documentSaved.remove(sourceID);
    if (sourceID == m_currentSourceID || m_lastNonSavedSourceID == sourceID)
        changed = true;

    if (changed) {
        emit pinsChanged();
        emit savedPacketsChanged();
    }
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
    m_streamEpoch++;
    m_pageEpoch.clear();
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
    // Structured builder rows are per-request state too; every follow-up
    // page must carry them or catch-up pages refill with unfiltered rows.
    if (!m_structuredRows.isEmpty()) {
        params.insert(QStringLiteral("structured"), m_structuredRows);
        if (m_structuredJoin == QStringLiteral("or"))
            params.insert(QStringLiteral("structured_join"), QStringLiteral("or"));
    }
    if (firstPage) {
        params.insert(QStringLiteral("offset"), 0);
    } else {
        params.insert(QStringLiteral("since_id"), QString::number(m_lastPacketID));
    }

    m_requestInFlight = true;
    const QString requestID = m_client->send(QStringLiteral("packets.list"), params, 120);
    if (!requestID.isEmpty())
        m_pageEpoch.insert(requestID, m_streamEpoch);
}

void SessionController::handlePacketListResponse(const QString &command,
                                                 const QString &requestID,
                                                 const QVariantMap &data)
{
    if (command != QStringLiteral("packets.list"))
        return;
    const qint64 sentEpoch = m_pageEpoch.take(requestID);
    if (sentEpoch != m_streamEpoch)
        return;
    handlePackets(data);
}

void SessionController::handleResponseRequestFailure(const QString &requestID,
                                                     const QString &command,
                                                     const QString &code,
                                                     const QString &message)
{
    if (command == QStringLiteral("packets.list"))
        m_pageEpoch.remove(requestID);
    Q_UNUSED(code)
    Q_UNUSED(message)
}

void SessionController::handleResponse(const QString &command, const QVariantMap &data)
{
    // Packets-view delete: the local rows are already gone; the reply only
    // reconciles the totals (a failure re-syncs the whole table, see
    // handleFailure).
    if (command == QStringLiteral("packets.delete")) {
        const int removed = m_pendingDeleteCount;
        m_pendingDeleteCount = 0;
        if (data.value(QStringLiteral("deleted_count")).toInt() > 0 && removed > 0)
            setTotalCount(m_totalCount - removed);
        return;
    }

    // The filter error state clears when a new expression is applied (see
    // applyFilter), not on page replies: reverting after an invalid filter
    // also produces a successful packets.list and must not undo it.
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
        setStopInFlight(false);
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
        setStopInFlight(false);
        refreshSources();
        return;
    }

    // packets.list pages arrive via handlePacketListResponse(requestID, ...).

    if (command == QStringLiteral("file.import")) {
        const QVariantList imported = data.value(QStringLiteral("imported")).toList();
        setLoading(false);
        m_importPaths.clear();
        emit sourcesChanged();
        emit loadingChanged();
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

    if (command == QStringLiteral("file.session_state")) {
        // Document-scoped pins ride the source echo in the reply, so out-of-
        // order replies after rapid source switches stay attributable.
        handleSessionState(data);
        return;
    }

    if (command == QStringLiteral("source.close")) {
        // Closed sources lose their document overlays (upstream: closing the
        // session document restores the persistent lists).
        const QString closedSource = data.value(QStringLiteral("source_id")).toString();
        bool changed = false;
        if (!closedSource.isEmpty()) {
            if (m_documentPins.remove(closedSource) > 0)
                changed = true;
            if (m_documentSaved.remove(closedSource) > 0)
                changed = true;
        }
        if ((closedSource == m_currentSourceID
             || (m_savedMode && closedSource == m_lastNonSavedSourceID))
            && changed) {
            emit pinsChanged();
            emit savedPacketsChanged();
        }
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

    // CI/screenshot hook: TCPVIEWER_DELETE_ROWS=row,row fires the table
    // delete flow (upstream ⌫/Del and the row menu's Delete) once the rows
    // exist onscreen.
    triggerDeleteRowsHook();

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

void SessionController::setFilterError(const QString &text, const QVariantMap &span)
{
    if (m_filterErrorText == text && m_filterErrorSpan == span)
        return;
    m_filterErrorText = text;
    m_filterErrorSpan = span;
    emit filterErrorChanged();
}

// Byte spans arrive in UTF-8 offsets from Wireshark; the field edits QString,
// so convert to UTF-16 code-unit positions (clamped).
static qsizetype utf8ToUtf16Position(const QString &text, qsizetype utf8Start)
{
    if (utf8Start <= 0)
        return 0;
    const QByteArray utf8 = text.toUtf8();
    const qsizetype clamped = qMin(utf8Start, utf8.size());
    return QString::fromUtf8(utf8.left(clamped)).size();
}

static qsizetype utf8ToUtf16Length(const QString &text, qsizetype utf8Start,
                                   qsizetype utf8Length)
{
    if (utf8Length <= 0)
        return 0;
    const QByteArray utf8 = text.toUtf8();
    const qsizetype start = qMin(utf8Start, utf8.size());
    const QByteArray slice = utf8.mid(start, utf8Length);
    return qMax<qsizetype>(1, QString::fromUtf8(slice).size());
}

void SessionController::handleFailure(const QString &command, const QString &code,
                                      const QString &message, const QVariantMap &data)
{
    m_requestInFlight = false;

    // A lost/failed stop reply must not leave the button wedged on
    // "Stopping…"; the status poll still reflects the true phase.
    if (command == QStringLiteral("capture.stop")) {
        setStopInFlight(false);
    }

    // A failed delete (source gone, connection lost) dusts the optimistic
    // removal: rebuild the table straight from the daemon's buffers.
    if (command == QStringLiteral("packets.delete")) {
        m_pendingDeleteCount = 0;
        resetStream();
        return;
    }

    // Display-filter validation failures carry the diagnostic byte span
    // (upstream DisplayFilterDiagnostic.range). Revert the request filter to
    // the last valid expression, keep the draft in the field (the text mirror
    // skips focused fields), and hand the span to the editor for selection.
    if (command == QStringLiteral("packets.list")
        && message.startsWith(QStringLiteral("invalid display filter"))) {
        const QVariantMap span = data.value(QStringLiteral("error_span")).toMap();
        const QString draft = m_filterText;
        const qsizetype start =
            utf8ToUtf16Position(draft, span.value(QStringLiteral("start")).toLongLong());
        const qsizetype length =
            utf8ToUtf16Length(draft,
                              span.value(QStringLiteral("start")).toLongLong(),
                              span.value(QStringLiteral("length")).toLongLong());
        setFilterTextInternal(m_previousFilter);
        clearSelection();
        resetStream();
        setFilterError(message, QVariantMap{
            {QStringLiteral("start"), start},
            {QStringLiteral("length"), length},
        });
        setLoading(false);
        return;
    }

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

    // Import failures end the chain: reset the multi-file state first, then
    // either stay quiet (user-intended cancel) or surface the error.
    if (command == QStringLiteral("file.import")) {
        m_importPaths.clear();
        emit sourcesChanged();
        emit loadingChanged();
        setLoading(false);
        if (code != QStringLiteral("operation_cancelled")) {
            setError(message);
        } else {
            setError(QString());
            refreshSources();
        }
        return;
    }

    // Annotation mutations are optimistic; a failure (unknown id, bad op)
    // re-lists the stream so client rows re-align with the daemon buffers.
    if (command == QStringLiteral("packets.set_style")
        || command == QStringLiteral("packets.set_comment")) {
        resetStream();
        setError(message);
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
        if (sourceID == m_currentSourceID) {
            setStatus(data);
        } else if (m_currentSourceID.isEmpty() && !sourceID.isEmpty()) {
            selectSourceInternal(sourceID);
        }
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
    // A phase that leaves running/paused/starting means the stop landed —
    // clear the in-flight marker even if the capture.stop reply was lost.
    if (phase == QStringLiteral("stopped") || phase == QStringLiteral("failed")
        || phase == QStringLiteral("ready") || phase.isEmpty())
        setStopInFlight(false);
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

void SessionController::setStopInFlight(bool stopInFlight)
{
    if (m_stopInFlight == stopInFlight)
        return;
    m_stopInFlight = stopInFlight;
    emit stopInFlightChanged();
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

void SessionController::exportPackets(const QString &path, const QString &format,
                                      const QVariantList &packetIDs)
{
    if (!m_client->connected() || m_currentSourceID.isEmpty() || path.isEmpty()
        || packetIDs.isEmpty()) {
        return;
    }
    if (format != QStringLiteral("pcap") && format != QStringLiteral("pcapng")) {
        setError(QStringLiteral("Export format must be pcap or pcapng."));
        return;
    }
    if (packetIDs.size() > 5'000) {
        // The daemon selector rejects > 5000 ids; report before sending.
        setError(QStringLiteral(
            "A packet export is limited to 5000 packets — narrow the selection."));
        return;
    }
    setError(QString());
    setLoading(true);
    m_client->send(QStringLiteral("file.export"), {
        {QStringLiteral("source_id"), m_currentSourceID},
        {QStringLiteral("path"), path},
        {QStringLiteral("format"), format},
        {QStringLiteral("packet_ids"), packetIDs},
        {QStringLiteral("overwrite"), true},
    }, 300);
}

void SessionController::exportGroup(const QString &path, const QString &format,
                                    const QString &nodeID)
{
    if (!m_client->connected() || m_currentSourceID.isEmpty() || path.isEmpty()
        || nodeID.isEmpty()) {
        return;
    }
    if (format != QStringLiteral("pcap") && format != QStringLiteral("pcapng")) {
        setError(QStringLiteral("Export format must be pcap or pcapng."));
        return;
    }

    // Sidebar scopes resolve to packet ids on the loaded set (upstream maps
    // source-list selections the same way, minus the All Packets row).
    const int split = nodeID.indexOf(QLatin1Char(':'));
    const QString kind = split > 0 ? nodeID.left(split) : nodeID;
    QString scopeKind = kind;
    if (kind == QStringLiteral("app"))
        scopeKind = QStringLiteral("client");
    if (scopeKind == QStringLiteral("file")) {
        // The loaded row set belongs to whichever source is selected, so a
        // file row exports through the whole-source path.
        exportAll(path, format);
        return;
    }
    if (scopeKind != QStringLiteral("domain") && scopeKind != QStringLiteral("ip")
        && scopeKind != QStringLiteral("client")) {
        setError(QStringLiteral("This sidebar row cannot be exported."));
        return;
    }

    const QVariantList ids = m_packets->packetIDsForScope(scopeKind,
        nodeID.mid(split + 1), 5'000);
    if (ids.isEmpty()) {
        setError(QStringLiteral("No packets match this scope."));
        return;
    }
    exportPackets(path, format, ids);
}

void SessionController::exportSession(const QString &path)
{
    if (!m_client->connected() || m_currentSourceID.isEmpty() || path.isEmpty())
        return;

    // App-state round trip (C5, upstream TCPViewSessionExportSnapshot's
    // pins/savedPackets): the active stores travel with the bundle; saved
    // references stay slim because the daemon resolves them to its own
    // summary records (comment/style state rides the source anyway).
    QVariantList pinValues;
    pinValues.reserve(activePinStore()->count());
    for (const PinRecord &pin : activePinStore()->records())
        pinValues.append(pin.toSessionMap());

    QVariantList savedValues;
    savedValues.reserve(activeSavedStore()->count());
    for (const SavedPacketRecord &record : activeSavedStore()->records()) {
        if (record.packetId.isEmpty() || record.savedAtMs <= 0)
            continue;
        QVariantMap value;
        value.insert(QStringLiteral("id"), record.packetId);
        value.insert(QStringLiteral("savedAt"),
                     QDateTime::fromMSecsSinceEpoch(record.savedAtMs)
                         .toUTC()
                         .toString(QStringLiteral("yyyy-MM-dd'T'HH:mm:ss'Z'")));
        if (!record.backing.isEmpty())
            value.insert(QStringLiteral("backingIdentity"), record.backing);
        savedValues.append(value);
    }

    setError(QString());
    setLoading(true);
    m_client->send(QStringLiteral("file.export_session"), {
        {QStringLiteral("source_id"), m_currentSourceID},
        {QStringLiteral("path"), path},
        {QStringLiteral("overwrite"), true},
        {QStringLiteral("pins"), pinValues},
        {QStringLiteral("saved_records"), savedValues},
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
    row.highlightColor = summary.value(QStringLiteral("highlight_color")).toString();
    row.strikethrough = summary.value(QStringLiteral("strikethrough")).toBool();
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
