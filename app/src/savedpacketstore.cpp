#include "savedpacketstore.h"

#include <QDateTime>
#include <QSet>

int SavedPacketStore::add(const QVector<PacketRow> &rows, const QString &backing)
{
    // Upstream savePackets: star each selected summary with its save time;
    // re-saving an id keeps the original record.
    int added = 0;
    for (const PacketRow &row : rows) {
        if (row.packetId.isEmpty())
            continue;
        bool exists = false;
        for (const SavedPacketRecord &record : m_records) {
            if (record.backing == backing && record.packetId == row.packetId) {
                exists = true;
                break;
            }
        }
        if (exists)
            continue;

        SavedPacketRecord record;
        record.packetId = row.packetId;
        record.savedAtMs = QDateTime::currentMSecsSinceEpoch();
        record.backing = backing;
        record.row = row;
        m_records.append(record);
        ++added;
    }
    return added;
}

bool SavedPacketStore::remove(const QString &packetID)
{
    for (int i = 0; i < m_records.size(); ++i) {
        if (m_records.at(i).packetId == packetID) {
            m_records.removeAt(i);
            return true;
        }
    }
    return false;
}

int SavedPacketStore::applyAnnotation(const QVector<quint64> &packetIDs,
                                      const PacketListModel::AnnotationChange &change,
                                      const QString &backing)
{
    // Mirror the model's per-row semantics on the stored copies: identical
    // rules for highlight keep / strike toggle / reset / comment replace.
    QSet<quint64> wanted;
    wanted.reserve(packetIDs.size());
    for (quint64 id : packetIDs)
        wanted.insert(id);

    int touched = 0;
    for (SavedPacketRecord &record : m_records) {
        if (!backing.isEmpty() && record.backing != backing)
            continue;
        const quint64 id = record.row.packetId.toULongLong();
        if (id == 0 || !wanted.contains(id))
            continue;
        ++touched;

        if (change.hasHighlightChange && !change.highlightColorChange.isEmpty())
            record.row.highlightColor = change.highlightColorChange;
        if (change.strikeToggle)
            record.row.strikethrough = !record.row.strikethrough;
        if (change.styleReset) {
            record.row.highlightColor.clear();
            record.row.strikethrough = false;
        }
        if (change.hasCommentChange)
            record.row.comment = change.commentChange;
    }
    return touched;
}

QVariantList SavedPacketStore::toVariantList() const
{
    QVariantList values;
    values.reserve(m_records.size());
    for (const SavedPacketRecord &record : m_records) {
        QVariantMap map = packetRowToMap(record.row);
        map.insert(QStringLiteral("savedAt"), record.savedAtMs);
        map.insert(QStringLiteral("backing"), record.backing);
        values.append(map);
    }
    return values;
}

void SavedPacketStore::loadFromVariantList(const QVariantList &values)
{
    m_records.clear();
    for (const QVariant &value : values) {
        const QVariantMap map = value.toMap();
        const QString packetId = map.value(QStringLiteral("packetId")).toString();
        if (packetId.isEmpty())
            continue;
        SavedPacketRecord record;
        record.packetId = packetId;
        record.savedAtMs = map.value(QStringLiteral("savedAt")).toLongLong();
        record.backing = map.value(QStringLiteral("backing")).toString();
        record.row = packetRowFromMap(map);
        m_records.append(record);
    }
}
