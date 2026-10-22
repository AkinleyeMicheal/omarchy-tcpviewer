#include "followstreammodel.h"

#include "daemonclient.h"

#include <QDateTime>
#include <QFile>
#include <QTimer>
#include <QUrl>

// Upstream bounded display (FollowStreamViewModel): 4 MiB payload / 10k
// records on screen; raw export ignores the display bound.
static constexpr int kMaximumDisplayedRecords = 10000;
static constexpr qint64 kMaximumDisplayedPayloadBytes = 4 * 1024 * 1024;
static constexpr int kHexBytesPerLine = 16;


FollowStreamModel::FollowStreamModel(QObject *parent)
    : QAbstractListModel(parent)
{
    // CI/screenshot hook: TCPVIEWER_FOLLOW_DIRECTION (both|client-to-server|
    // server-to-client) seeds the direction filter.
    const QString direction = qEnvironmentVariable("TCPVIEWER_FOLLOW_DIRECTION");
    if (direction == QStringLiteral("client-to-server"))
        m_directionFilter = 1;
    else if (direction == QStringLiteral("server-to-client"))
        m_directionFilter = 2;
}

int FollowStreamModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : m_visible.size();
}

QVariant FollowStreamModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() >= m_visible.size())
        return {};
    const Record &record = m_records.at(m_visible.at(index.row()));
    switch (role) {
    case DirectionRole:
        return record.direction;
    case PacketIDRole:
        return static_cast<qint64>(record.packetID);
    case ByteCountRole:
        return record.byteCount;
    case TimeRole:
        return record.timeText;
    case TextPayloadRole:
        return record.textPayload;
    case HexPayloadRole:
        return formatPayloadHex(record.raw);
    default:
        return {};
    }
}

QHash<int, QByteArray> FollowStreamModel::roleNames() const
{
    return {
        {DirectionRole, "direction"},
        {PacketIDRole, "packetID"},
        {ByteCountRole, "byteCount"},
        {TimeRole, "timeText"},
        {TextPayloadRole, "textPayload"},
        {HexPayloadRole, "hexPayload"},
    };
}

void FollowStreamModel::setDirectionFilter(int filter)
{
    const int bounded = qBound(0, filter, 2);
    if (bounded == m_directionFilter)
        return;
    m_directionFilter = bounded;
    beginResetModel();
    m_visible.clear();
    for (int row = 0; row < m_records.size(); ++row) {
        const Record &record = m_records.at(row);
        if (m_directionFilter == 0 || m_directionFilter - 1 == record.direction)
            m_visible.append(row);
    }
    endResetModel();
    emit directionFilterChanged();
    // Status text depends on the selected subset.
    emit hasStreamChanged();
}

QString FollowStreamModel::endpointLabel(const QVariantMap &endpoint)
{
    if (endpoint.isEmpty())
        return QStringLiteral("Unknown");
    const QString address = !endpoint.value(QStringLiteral("address")).isNull()
        ? endpoint.value(QStringLiteral("address")).toString()
        : QStringLiteral("Unknown");
    if (endpoint.contains(QStringLiteral("port")) && !endpoint.value(QStringLiteral("port")).isNull())
        return QStringLiteral("%1:%2").arg(address, endpoint.value(QStringLiteral("port")).toString());
    return address;
}

QString FollowStreamModel::summaryLabel() const
{
    if (!m_hasStream)
        return {};
    return QStringLiteral("%1  ⇄  %2").arg(m_clientLabel, m_serverLabel);
}

QString FollowStreamModel::streamTitle() const
{
    if (!m_hasStream)
        return {};
    const QString number = m_streamID.section(QLatin1Char(':'), 1);
    if (!number.isEmpty())
        return QStringLiteral("%1 · Stream %2").arg(m_protocol.toUpper(), number);
    return m_protocol.toUpper();
}

QString FollowStreamModel::statusText() const
{
    if (!m_hasStream)
        return {};
    qint64 selectedBytes = m_clientBytes + m_serverBytes;
    if (m_directionFilter == 1)
        selectedBytes = m_clientBytes;
    if (m_directionFilter == 2)
        selectedBytes = m_serverBytes;

    qint64 displayed = 0;
    bool displayIsLimited = false;
    for (int row : m_visible) {
        const Record &record = m_records.at(row);
        if (displayed >= kMaximumDisplayedPayloadBytes) {
            displayIsLimited = true;
            break;
        }
        const qint64 remaining = kMaximumDisplayedPayloadBytes - displayed;
        displayed += qMin<qint64>(remaining, record.raw.size());
        if (record.raw.size() > remaining) {
            displayIsLimited = true;
            break;
        }
    }
    if (m_records.size() > kMaximumDisplayedRecords)
        displayIsLimited = true;

    QString byteStatus;
    if (displayIsLimited)
        byteStatus = QStringLiteral("%1 of %2 bytes shown · display limited for responsiveness")
            .arg(displayed).arg(selectedBytes);
    else
        byteStatus = QStringLiteral("%1 bytes").arg(displayed);

    QString truncation;
    if (m_truncated)
        truncation = QStringLiteral(" · truncated at safety limit");
    return QStringLiteral("%1 · snapshot through packet %2%3")
        .arg(byteStatus, QString::number(m_capturedThrough), truncation);
}

QVector<int> FollowStreamModel::searchRows(const QString &query) const
{
    QVector<int> matches;
    const QString needle = query.trimmed();
    if (needle.isEmpty())
        return matches;
    for (int row = 0; row < m_visible.size(); ++row) {
        const Record &record = m_records.at(m_visible.at(row));
        const QString haystack = record.textPayload + QString::number(record.packetID);
        if (haystack.contains(needle, Qt::CaseInsensitive))
            matches.append(row);
    }
    return matches;
}

QString FollowStreamModel::transcriptText(int filter) const
{
    QString output;
    for (int row : m_visible) {
        const Record &record = m_records.at(row);
        if (filter != 0 && filter - 1 != record.direction)
            continue;
        const QString title = record.direction == 0
            ? QStringLiteral("→ Client to Server") : QStringLiteral("← Server to Client");
        output += QStringLiteral("%1 · Packet %2 · %3 B\n")
            .arg(title, QString::number(record.packetID), QString::number(record.byteCount));
        output += record.textPayload;
        if (!record.textPayload.endsWith(QLatin1Char('\n')))
            output += QLatin1Char('\n');
        output += QLatin1Char('\n');
    }
    return output;
}

QByteArray FollowStreamModel::transcriptRaw(int filter) const
{
    QByteArray output;
    for (const Record &record : m_records) {
        // Saved per fixed direction regardless of the on-screen filter (upstream export).
        if (filter == 1 && record.direction != 0)
            continue;
        if (filter == 2 && record.direction != 1)
            continue;
        output.append(record.raw);
    }
    return output;
}

QString FollowStreamModel::suggestedFileName() const
{
    return QStringLiteral("%1-stream-").arg(m_protocol);
}

QString FollowStreamModel::formatPayloadText(const QByteArray &bytes)
{
    // Preserve readable whitespace, replace unsafe control scalars with "·".
    const QString text = QString::fromUtf8(bytes);
    QString result;
    result.reserve(text.size());
    for (const QChar character : text) {
        const char16_t scalar = character.unicode();
        if (scalar == '\n' || scalar == '\r' || scalar == '\t'
            || scalar > 0x1f && scalar != 0x7f) {
            result.append(character);
        } else {
            result.append(QStringLiteral("·"));
        }
    }
    return result;
}

QString FollowStreamModel::formatPayloadHex(const QByteArray &bytes)
{
    // "%08x  " offset, hex padded to bytesPerLine, then the ASCII gutter.
    if (bytes.isEmpty())
        return {};
    QString rows;
    rows.reserve(bytes.size() * 3);
    const int paddedHexLength = kHexBytesPerLine * 3 - 1;
    for (int offset = 0; offset < bytes.size(); offset += kHexBytesPerLine) {
        const int lineEnd = qMin(offset + kHexBytesPerLine, bytes.size());
        QString hexBytes;
        for (int i = offset; i < lineEnd; ++i) {
            if (!hexBytes.isEmpty())
                hexBytes += QLatin1Char(' ');
            hexBytes += QStringLiteral("%1").arg(static_cast<quint8>(bytes.at(i)), 2, 16, QLatin1Char('0'));
        }
        hexBytes += QString(paddedHexLength - hexBytes.size(), QLatin1Char(' '));
        QString ascii;
        for (int i = offset; i < lineEnd; ++i) {
            const quint8 value = static_cast<quint8>(bytes.at(i));
            ascii += QLatin1Char(value >= 0x20 && value <= 0x7e ? char(value) : '.');
        }
        rows += QStringLiteral("%1  %2  %3\n")
            .arg(offset, 8, 16, QLatin1Char('0'))
            .arg(hexBytes)
            .arg(ascii);
    }
    return rows;
}

void FollowStreamModel::applyFollow(const QVariantMap &data)
{
    beginResetModel();
    m_records.clear();
    m_visible.clear();
    m_hasStream = true;
    m_truncated = data.value(QStringLiteral("is_truncated")).toBool();
    m_capturedThrough = data.value(QStringLiteral("captured_through_packet_id")).toString().toULongLong();
    m_protocol = data.value(QStringLiteral("protocol")).toString();
    m_streamID = data.value(QStringLiteral("stream_id")).toString();
    m_clientLabel = endpointLabel(data.value(QStringLiteral("client")).toMap());
    m_serverLabel = endpointLabel(data.value(QStringLiteral("server")).toMap());
    m_clientBytes = data.value(QStringLiteral("client_bytes")).toLongLong();
    m_serverBytes = data.value(QStringLiteral("server_bytes")).toLongLong();

    const QVariantList rows = data.value(QStringLiteral("records")).toList();
    m_records.reserve(rows.size());
    for (const QVariant &value : rows) {
        const QVariantMap info = value.toMap();
        Record record;
        record.direction = info.value(QStringLiteral("direction")).toString() == QStringLiteral("clientToServer") ? 0 : 1;
        record.packetID = info.value(QStringLiteral("packet_id")).toString().toULongLong();
        record.timeText = info.value(QStringLiteral("timestamp")).toString();
        record.raw = QByteArray::fromBase64(info.value(QStringLiteral("data")).toString().toLatin1());
        record.byteCount = record.raw.size();
        record.textPayload = formatPayloadText(record.raw);
        m_records.append(record);
    }

    for (int row = 0; row < m_records.size(); ++row) {
        const Record &record = m_records.at(row);
        if (m_directionFilter == 0 || m_directionFilter - 1 == record.direction)
            m_visible.append(row);
    }
    endResetModel();
    emit hasStreamChanged();
}

void FollowStreamModel::setFollowError(const QString &message)
{
    if (m_followError == message)
        return;
    m_followError = message;
    emit followErrorChanged();
    // A failed follow empties the transcript without dropping window state.
    beginResetModel();
    m_records.clear();
    m_visible.clear();
    m_hasStream = false;
    endResetModel();
    emit hasStreamChanged();
}

FollowSessionController::FollowSessionController(QObject *parent)
    : QObject(parent)
    , m_client(new DaemonClient(this))
    , m_model(new FollowStreamModel(this))
{
    // Launch-with-follow hook (CI/screenshots): follow this packet once the
    // fixture import lands; retry until the packet exists. Registered before
    // start() so the initial connectedChanged sees the pending id.
    const QString followPacket = qEnvironmentVariable("TCPVIEWER_FOLLOW_PACKET");
    m_startupRepresentation = qEnvironmentVariable("TCPVIEWER_FOLLOW_REPRESENTATION") == QStringLiteral("hex") ? 1 : 0;

    connect(m_client, &DaemonClient::response, this, [this](const QString &command, const QVariantMap &data) {
        if (command != QStringLiteral("stream.follow"))
            return;
        setLoading(false);
        m_model->applyFollow(data);
        m_model->setFollowError(QString());
        emit followReady();
        //() << "follow applied, records:" << data.value(QStringLiteral("record_count")).toInt();
    });
    connect(m_client, &DaemonClient::failure, this, [this](const QString &command, const QString &code, const QString &message) {
        Q_UNUSED(code)
        if (command != QStringLiteral("stream.follow"))
            return;
        setLoading(false);
        m_model->setFollowError(message);
        //() << "follow failed:" << message;
        emit followReady();
    });

    connect(m_client, &DaemonClient::connectedChanged, this, [this, followPacket]() {
        if (m_client->connected() && !followPacket.isEmpty() && !m_startupStarted) {
            m_startupStarted = true;
            m_startupPacketID = followPacket;
            connect(this, &FollowSessionController::followReady, this, [this]() {
                if (m_startupAttempts < 20 && !m_model->followError().isEmpty()) {
                    ++m_startupAttempts;
                    QTimer::singleShot(500, this, [this]() { follow(m_startupPacketID); });
                }
            });
            QTimer::singleShot(1200, this, [this]() { follow(m_startupPacketID); });
        }
    });
    m_client->start();
}

void FollowSessionController::setLoading(bool loading)
{
    if (m_loading == loading)
        return;
    m_loading = loading;
    emit loadingChanged();
}

void FollowSessionController::follow(const QString &packetID)
{
    if (packetID.isEmpty())
        return;
    setLoading(true);
    m_client->send(QStringLiteral("stream.follow"),
        {
            {QStringLiteral("packet_id"), packetID},
            {QStringLiteral("encoding"), QStringLiteral("base64")},
        }, 180);
}

bool FollowSessionController::saveFile(const QUrl &target, const QString &text)
{
    return saveFile(target, text.toUtf8());
}

bool FollowSessionController::saveFile(const QUrl &target, const QByteArray &data)
{
    if (target.isEmpty())
        return false;
    QFile file(target.toLocalFile());
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return false;
    return file.write(data) == data.size();
}
