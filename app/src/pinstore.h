/*
    PinStore — app-side pinned sources (C2, upstream PacketPinService).

    A pin is a stable sidebar entry under "Favorites > Pinned" for a domain,
    an IP address, or a client (app identity). Clicking one filters the packet
    table through the same tree-filter keys the Apps/Domains/IPs rows use.

    Persistence mirrors upstream PinnedPackets.json but lives in QSettings
    (array "pins"), so it never touches user files outside the app config.
    Stable ids match upstream: "domain:<d>", "ip:<ip>", "client:<key>".
*/
#ifndef PINSTORE_H
#define PINSTORE_H

#include <QVariantList>
#include <QVariantMap>
#include <QVector>

struct PinRecord
{
    QString id;
    QString kind;        // "domain" | "ip" | "client" (upstream raw values)
    QString title;
    QString domain;
    QString ip;
    QString clientKey;
    QString clientDisplay;
    QString iconPath;
    qint64 createdAtMs = 0;

    bool isValid() const;
    QVariantMap toMap() const;
    static PinRecord fromMap(const QVariantMap &map);
};

class PinStore
{
public:
    // Stable id for a (kind, key) pair, matching upstream PacketPin ids.
    static QString idFor(const QString &kind, const QString &key)
    {
        return kind + ':' + key;
    }

    // Upsert by stable id (upstream dedupe: an existing pin stays put).
    // Returns the stored record; replaces none on invalid input (empty store
    // record returned).
    PinRecord upsert(const PinRecord &pin);
    bool remove(const QString &id);
    PinRecord find(const QString &id) const;
    int count() const { return m_pins.size(); }

    const QVector<PinRecord> &records() const { return m_pins; }

    QVariantList toVariantList() const;
    void loadFromVariantList(const QVariantList &values);

    // Fire-and-forget document overlay support: a session document's pins
    // replace the persistent list while its source is open (upstream
    // PacketPinService.documentRecords semantics).
    void replaceAll(QVector<PinRecord> pins);
    static PinRecord fromSessionPin(const QVariantMap &fields);

private:
    QVector<PinRecord> m_pins;
};

#endif // PINSTORE_H
