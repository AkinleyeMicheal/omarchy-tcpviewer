#pragma once

#include <QHash>
#include <QObject>
#include <QQueue>
#include <QSet>
#include <QString>
#include <QVariantList>
#include <QVector>
#include <QtQml/qqmlregistration.h>

class DaemonClient;

// Lazily resolves user-created column values from packet detail trees. The
// table asks only for cells it is about to paint; requests are serialized and
// bounded so a custom column cannot flood the daemon or retain every packet's
// full decode tree.
class PacketCustomColumns : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(int revision READ revision NOTIFY revisionChanged)
    Q_PROPERTY(QString sourceID READ sourceID WRITE setSourceID NOTIFY sourceIDChanged)

public:
    explicit PacketCustomColumns(QObject *parent = nullptr);

    int revision() const { return m_revision; }
    QString sourceID() const { return m_sourceID; }
    void setSourceID(const QString &sourceID);

    Q_INVOKABLE QString value(const QString &columnID, const QString &packetID);
    Q_INVOKABLE void setSampleValue(const QString &columnID, const QString &packetID,
                                    const QString &value);
    Q_INVOKABLE void registerColumn(const QString &columnID, const QString &fieldName);
    Q_INVOKABLE void unregisterColumn(const QString &columnID);
    Q_INVOKABLE void clear();

signals:
    void revisionChanged();
    void sourceIDChanged();

private:
    struct Pending {
        QString columnID;
        QString packetID;
        quint64 generation = 0;
    };

    static QString normalizedField(const QString &fieldName);
    static QString cacheKey(const QString &columnID, const QString &packetID);
    static QString valueInNodes(const QVariantList &nodes, const QString &fieldName,
                                int depth = 0, int *budget = nullptr);
    void enqueue(const QString &columnID, const QString &packetID);
    void pump();
    void store(const QString &columnID, const QString &packetID, const QString &value);
    void finishCurrent(const QString &value);

    DaemonClient *m_client = nullptr;
    QString m_sourceID;
    QHash<QString, QString> m_fieldByColumn;
    QHash<QString, QString> m_values;
    QVector<QString> m_valueOrder;
    int m_valueOrderHead = 0;
    QQueue<Pending> m_queue;
    QSet<QString> m_queued;
    bool m_inFlight = false;
    Pending m_current;
    QString m_currentRequestID;
    quint64 m_generation = 0;
    int m_revision = 0;
};
