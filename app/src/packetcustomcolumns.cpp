#include "packetcustomcolumns.h"

#include "daemonclient.h"

#include <QVariantMap>

namespace {

constexpr int maximumQueuedRequests = 512;
constexpr int maximumCachedValues = 200'000;
constexpr int maximumDetailNodes = 10'000;
constexpr int maximumDetailDepth = 32;

QString normalizedField(const QString &fieldName)
{
    QString normalized = fieldName.trimmed().toLower();
    if (normalized.size() > 200)
        normalized.truncate(200);
    return normalized;
}

} // namespace

PacketCustomColumns::PacketCustomColumns(QObject *parent)
    : QObject(parent)
    , m_client(new DaemonClient(this))
{
    connect(m_client, &DaemonClient::response, this,
            [this](const QString &command, const QVariantMap &data) {
        if (command != QStringLiteral("packets.details") || !m_inFlight)
            return;
        const QString packetID = data.value(QStringLiteral("packet_id")).toString();
        const QString sourceID = data.value(QStringLiteral("source_id")).toString();
        if (packetID != m_current.packetID
            || (!sourceID.isEmpty() && !m_sourceID.isEmpty() && sourceID != m_sourceID)) {
            return;
        }
        const QString field = m_fieldByColumn.value(m_current.columnID);
        int budget = maximumDetailNodes;
        const QString value = valueInNodes(
            data.value(QStringLiteral("nodes")).toList(), field, 0, &budget);
        finishCurrent(value);
    });
    connect(m_client, &DaemonClient::requestFailure, this,
            [this](const QString &requestID, const QString &command, const QString &, const QString &) {
        if (command != QStringLiteral("packets.details") || !m_inFlight
            || requestID != m_currentRequestID) {
            return;
        }
        finishCurrent(QString());
    });
    connect(m_client, &DaemonClient::connectedChanged, this, [this]() {
        if (m_client->connected())
            pump();
    });
    m_client->start();
}

void PacketCustomColumns::setSourceID(const QString &sourceID)
{
    if (m_sourceID == sourceID)
        return;
    m_sourceID = sourceID;
    clear();
    emit sourceIDChanged();
}

QString PacketCustomColumns::value(const QString &columnID, const QString &packetID)
{
    if (columnID.isEmpty() || packetID.isEmpty())
        return {};
    if (!m_fieldByColumn.contains(columnID))
        return {};
    const QString key = cacheKey(columnID, packetID);
    if (m_values.contains(key))
        return m_values.value(key);
    enqueue(columnID, packetID);
    return {};
}

void PacketCustomColumns::setSampleValue(const QString &columnID, const QString &packetID,
                                         const QString &value)
{
    if (columnID.isEmpty() || packetID.isEmpty() || !m_fieldByColumn.contains(columnID))
        return;
    store(columnID, packetID, value);
    emit revisionChanged();
}

void PacketCustomColumns::registerColumn(const QString &columnID, const QString &fieldName)
{
    const QString normalized = normalizedField(fieldName);
    if (columnID.isEmpty() || normalized.isEmpty())
        return;
    if (m_fieldByColumn.value(columnID) == normalized)
        return;
    m_fieldByColumn.insert(columnID, normalized);
    clear();
}

void PacketCustomColumns::unregisterColumn(const QString &columnID)
{
    if (!m_fieldByColumn.remove(columnID))
        return;
    clear();
}

void PacketCustomColumns::clear()
{
    ++m_generation;
    m_values.clear();
    m_valueOrder.clear();
    m_valueOrderHead = 0;
    m_queue.clear();
    m_queued.clear();
    // Do not cancel an in-flight request: DaemonClient has no cancellation.
    // Its response/failure is ignored by generation/request-ID checks.
    m_inFlight = false;
    m_current = {};
    m_currentRequestID.clear();
    emit revisionChanged();
}

QString PacketCustomColumns::normalizedField(const QString &fieldName)
{
    return ::normalizedField(fieldName);
}

QString PacketCustomColumns::cacheKey(const QString &columnID, const QString &packetID)
{
    return columnID + QChar(0x1f) + packetID;
}

QString PacketCustomColumns::valueInNodes(const QVariantList &nodes, const QString &fieldName,
                                          int depth, int *budget)
{
    if (fieldName.isEmpty() || depth > maximumDetailDepth || !budget || *budget <= 0)
        return {};
    for (const QVariant &value : nodes) {
        if (*budget <= 0)
            break;
        --*budget;
        const QVariantMap node = value.toMap();
        if (normalizedField(node.value(QStringLiteral("field")).toString()) == fieldName) {
            const QString display = node.value(QStringLiteral("value")).toString();
            return display.isEmpty()
                ? node.value(QStringLiteral("raw_value")).toString() : display;
        }
        const QVariantList children = node.value(QStringLiteral("children")).toList();
        if (!children.isEmpty()) {
            const QString found = valueInNodes(children, fieldName, depth + 1, budget);
            if (!found.isNull())
                return found;
        }
    }
    return {};
}

void PacketCustomColumns::enqueue(const QString &columnID, const QString &packetID)
{
    if (m_queue.size() >= maximumQueuedRequests)
        return;
    const QString key = cacheKey(columnID, packetID);
    if (m_queued.contains(key))
        return;
    m_queued.insert(key);
    m_queue.enqueue(Pending{columnID, packetID, m_generation});
    pump();
}

void PacketCustomColumns::pump()
{
    if (m_inFlight || m_queue.isEmpty() || !m_client->connected())
        return;

    m_current = m_queue.dequeue();
    if (m_current.generation != m_generation) {
        pump();
        return;
    }
    const QString field = m_fieldByColumn.value(m_current.columnID);
    if (field.isEmpty()) {
        pump();
        return;
    }
    const QString key = cacheKey(m_current.columnID, m_current.packetID);
    if (m_values.contains(key)) {
        m_queued.remove(key);
        pump();
        return;
    }

    m_inFlight = true;
    QVariantMap params{
        {QStringLiteral("packet_id"), m_current.packetID},
        {QStringLiteral("max_depth"), 12},
        {QStringLiteral("max_nodes"), 5000},
    };
    if (!m_sourceID.isEmpty())
        params.insert(QStringLiteral("source_id"), m_sourceID);
    m_currentRequestID = m_client->send(QStringLiteral("packets.details"), params, 60);
    if (m_currentRequestID.isEmpty()) {
        finishCurrent(QString());
        return;
    }
}

void PacketCustomColumns::store(const QString &columnID, const QString &packetID,
                                const QString &value)
{
    const QString key = cacheKey(columnID, packetID);
    if (!m_values.contains(key))
        m_valueOrder.append(key);
    m_values.insert(key, value);

    while (m_values.size() > maximumCachedValues && m_valueOrderHead < m_valueOrder.size()) {
        const QString oldest = m_valueOrder.at(m_valueOrderHead++);
        m_values.remove(oldest);
    }
    if (m_valueOrderHead > 4096 && m_valueOrderHead * 2 > m_valueOrder.size()) {
        m_valueOrder = m_valueOrder.mid(m_valueOrderHead);
        m_valueOrderHead = 0;
    }
}

void PacketCustomColumns::finishCurrent(const QString &value)
{
    if (!m_inFlight)
        return;
    const Pending finished = m_current;
    const QString key = cacheKey(finished.columnID, finished.packetID);
    m_inFlight = false;
    m_current = {};
    m_currentRequestID.clear();
    m_queued.remove(key);
    if (finished.generation == m_generation)
        store(finished.columnID, finished.packetID, value);
    emit revisionChanged();
    pump();
}
