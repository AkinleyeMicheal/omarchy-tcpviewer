#include "sessioncontroller.h"

#include <QDateTime>
#include <QTimer>
#include <QUrl>

namespace {

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
    , m_detailModel(new PacketDetailModel(this))
{
    connect(m_client, &DaemonClient::connectedChanged, this, &SessionController::handleConnectedChanged);
    connect(m_client, &DaemonClient::response, this, &SessionController::handleResponse);
    connect(m_client, &DaemonClient::failure, this, &SessionController::handleFailure);
    connect(m_client, &DaemonClient::event, this, &SessionController::handleEvent);

    bool parsed = false;
    const int envRow = qEnvironmentVariableIntValue("TCPVIEWER_SELECT_DETAIL_ROW", &parsed);
    m_autoSelectDetailRow = parsed && envRow >= 0 ? envRow : -1;
    m_autoDetailFilter = qEnvironmentVariable("TCPVIEWER_DETAIL_FILTER");

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
        if (value.canConvert<QUrl>()) {
            const QUrl url = value.toUrl();
            path = url.isLocalFile() ? url.toLocalFile() : url.toString();
        }
        if (path.isEmpty())
            path = value.toString();
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
    m_status.clear();
    m_totalCount = 0;
    m_lastPacketID = 0;
    m_requestInFlight = false;
    emit currentSourceChanged();
    emit statusChanged();
    emit totalCountChanged();

    if (sourceID.isEmpty()) {
        m_packets->clear();
        setLoading(false);
        return;
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
    resetStream();
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

    m_detailModel->clear();
    m_packetBytes.clear();
    emit packetBytesChanged();
    m_detailLoading = true;
    emit detailLoadingChanged();
    if (!m_detailError.isEmpty()) {
        m_detailError.clear();
        emit detailErrorChanged();
    }

    QVariantMap detailParams{
        {QStringLiteral("packet_id"), packetID},
        {QStringLiteral("max_depth"), 12},
        {QStringLiteral("max_nodes"), 5000},
    };
    QVariantMap byteParams{
        {QStringLiteral("packet_id"), packetID},
        {QStringLiteral("offset"), 0},
        {QStringLiteral("length"), 0},
        {QStringLiteral("encoding"), QStringLiteral("base64")},
    };
    if (!m_currentSourceID.isEmpty()) {
        detailParams.insert(QStringLiteral("source_id"), m_currentSourceID);
        byteParams.insert(QStringLiteral("source_id"), m_currentSourceID);
    }
    m_client->send(QStringLiteral("packets.details"), detailParams, 60);
    m_client->send(QStringLiteral("packets.bytes"), byteParams, 60);
}

void SessionController::clearSelection()
{
    if (m_selectedPacketID.isEmpty() && m_packetBytes.isEmpty()
        && m_detailModel->rowCount() == 0 && m_detailError.isEmpty()) {
        return;
    }
    m_selectedPacketID.clear();
    emit selectedPacketIDChanged();
    m_detailModel->clear();
    m_packetBytes.clear();
    emit packetBytesChanged();
    if (m_detailLoading) {
        m_detailLoading = false;
        emit detailLoadingChanged();
    }
    if (!m_detailError.isEmpty()) {
        m_detailError.clear();
        emit detailErrorChanged();
    }
}

void SessionController::clearError()
{
    setError(QString());
}

void SessionController::resetStream()
{
    m_packets->clear();
    m_lastPacketID = 0;
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
    if (firstPage) {
        params.insert(QStringLiteral("offset"), 0);
        // Present on the first request so the source-level filter is set or
        // cleared exactly to the GUI's state; later polls keep it sticky.
        params.insert(QStringLiteral("filter"), m_filterText);
        params.insert(QStringLiteral("quick_filters"), m_quickFilters);
    } else {
        params.insert(QStringLiteral("since_id"), QString::number(m_lastPacketID));
    }

    m_requestInFlight = true;
    m_client->send(QStringLiteral("packets.list"), params, 120);
}

void SessionController::handleResponse(const QString &command, const QVariantMap &data)
{
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

    if (command == QStringLiteral("packets.details")) {
        if (data.value(QStringLiteral("packet_id")).toString() != m_selectedPacketID)
            return;
        m_detailModel->setNodes(data.value(QStringLiteral("nodes")).toList());
        m_detailLoading = false;
        emit detailLoadingChanged();
        return;
    }

    if (command == QStringLiteral("packets.bytes")) {
        if (data.value(QStringLiteral("packet_id")).toString() != m_selectedPacketID)
            return;
        m_packetBytes = QByteArray::fromBase64(data.value(QStringLiteral("data")).toByteArray());
        emit packetBytesChanged();
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

    m_packets->appendRows(rows);
    if (m_packets->lastPacketID() > m_lastPacketID)
        m_lastPacketID = m_packets->lastPacketID();

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

    // Inspector failures stay scoped to the inspector; the table keeps working.
    if (command == QStringLiteral("packets.details")) {
        m_detailLoading = false;
        m_detailError = message;
        emit detailLoadingChanged();
        emit detailErrorChanged();
        return;
    }
    if (command == QStringLiteral("packets.bytes"))
        return;

    Q_UNUSED(code)
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

void SessionController::reportError(const QString &message)
{
    setError(message);
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
    if (m_totalCount == total)
        return;
    m_totalCount = total;
    emit totalCountChanged();
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
    row.sourceKind = summary.value(QStringLiteral("source_kind")).toString();
    row.length = summary.value(QStringLiteral("length")).toInt();
    row.originalLength = summary.value(QStringLiteral("original_length")).toInt();
    row.tcpPayloadLength = summary.value(QStringLiteral("tcp_payload_length")).toInt();
    return row;
}
