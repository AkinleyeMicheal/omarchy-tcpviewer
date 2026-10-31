/*
    SavedPacketStore — app-side starred packets (C2, upstream
    SavedPacketService).

    Saving a row keeps a full PacketRow copy (upstream keeps the whole
    PacketSummary) plus the save time and the backing source id. The sidebar's
    "Saved" row surfaces the list; selecting it swaps the packet table to the
    copied rows. Annotation mutations on a source keep matching saved copies
    in sync when the record's backing source is active (upstream backs saved
    packets to the active ingest identity).

    Persistence mirrors upstream SavedPackets.json as a QSettings array
    ("packets/saved"); document-scoped records from session bundles land in
    C5's app-state round-trip.
*/
#ifndef SAVEDPACKETSTORE_H
#define SAVEDPACKETSTORE_H

#include "packetmodel.h"

#include <QVariantList>

struct SavedPacketRecord
{
    QString packetId;      // upstream SavedPacketRecord.id (packet id)
    qint64 savedAtMs = 0;  // upstream savedAt
    QString backing;       // upstream backingIdentity (source id, optional)
    PacketRow row;
};

class SavedPacketStore
{
public:
    // Star rows preserving the passed order; a (packet id, backing) pair
    // already saved is a no-op (upstream upsert semantics). Returns count
    // actually added. Packet ids restart per capture file, so the backing
    // source participates in identity.
    int add(const QVector<PacketRow> &rows, const QString &backing);
    // Drops the first ordered record with a matching packet id (the visible
    // one; retries clear later copies in the rare cross-source id collision).
    bool remove(const QString &packetID);
    void clear() { m_records.clear(); }
    int count() const { return m_records.size(); }

    const QVector<SavedPacketRecord> &records() const { return m_records; }

    // Annotation mirroring for saved copies (upstream applyTextStyleMutation
    // targets savedPacketIDs): apply to every record whose row id matches.
    // A non-empty backing limits the mirror to that source's records, so a
    // mutation on an active capture re-syncs only what backs it. Returns the
    // number of records touched.
    int applyAnnotation(const QVector<quint64> &packetIDs,
                        const PacketListModel::AnnotationChange &change,
                        const QString &backing = QString());

    QVariantList toVariantList() const;
    void loadFromVariantList(const QVariantList &values);

private:
    QVector<SavedPacketRecord> m_records;
};

#endif // SAVEDPACKETSTORE_H
