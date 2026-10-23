#ifndef DIFFCONTROLLER_H
#define DIFFCONTROLLER_H

#include "daemonclient.h"
#include "diffalgorithms.h"

#include <QAbstractListModel>
#include <QByteArray>
#include <QObject>
#include <QStringList>
#include <QVariantList>
#include <QVector>
#include <QtQml/qqmlregistration.h>

// Upstream DiffPoolModel: packets snapshot into a pool, then two are assigned
// to Left/Right. The pool survives source changes and is capped like upstream.
class DiffPoolModel : public QAbstractListModel
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(int count READ count NOTIFY countChanged)

public:
    enum Role {
        EntryIdRole = Qt::UserRole + 1,
        PacketIdRole,
        SourceIdRole,
        NumberRole,
        SummaryRole,
        SideRole,
    };
    Q_ENUM(Role)

    explicit DiffPoolModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    Q_INVOKABLE QString add(const QString &sourceID, const QString &packetID,
                            quint64 number, const QString &summary);
    Q_INVOKABLE void setSide(const QString &entryID, const QString &side);
    Q_INVOKABLE void removeEntry(const QString &entryID);
    Q_INVOKABLE void clear();
    Q_INVOKABLE QString sideForEntry(const QString &entryID) const;

    int count() const { return static_cast<int>(m_entries.size()); }

    QString entryIDForSide(const QString &side) const;
    QString packetIDForEntry(const QString &entryID) const;
    QString sourceIDForEntry(const QString &entryID) const;
    QString summaryForEntry(const QString &entryID) const;
    quint64 numberForEntry(const QString &entryID) const;

signals:
    void sidesChanged();
    void countChanged();

private:
    struct Entry {
        QString entryID;
        QString sourceID;
        QString packetID;
        quint64 number = 0;
        QString summary;
        QString side; // "left", "right", or empty
    };

    int indexForEntry(const QString &entryID) const;
    int indexForSide(const QString &side) const;
    QVector<Entry> m_entries;
};

// Owns two daemon connections (one per side), fetches detail trees and bytes,
// and exposes diff rows for the QML window. Upstream DiffTextComparison caps
// each side at 2000 lines; diffLines applies the same bound.
class DiffController : public QObject
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(DiffPoolModel *pool READ pool CONSTANT)
    Q_PROPERTY(QString contentKind READ contentKind WRITE setContentKind NOTIFY contentKindChanged)
    Q_PROPERTY(QString displayMode READ displayMode WRITE setDisplayMode NOTIFY displayModeChanged)
    Q_PROPERTY(QVariantList sideBySideRows READ sideBySideRows NOTIFY rowsChanged)
    Q_PROPERTY(QVariantList unifiedRows READ unifiedRows NOTIFY rowsChanged)
    Q_PROPERTY(QVariantList changeRows READ changeRows NOTIFY rowsChanged)
    Q_PROPERTY(int differenceCount READ differenceCount NOTIFY rowsChanged)
    Q_PROPERTY(bool ready READ ready NOTIFY stateChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY stateChanged)
    Q_PROPERTY(QString error READ error NOTIFY stateChanged)
    Q_PROPERTY(QString leftTitle READ leftTitle NOTIFY titlesChanged)
    Q_PROPERTY(QString rightTitle READ rightTitle NOTIFY titlesChanged)
    Q_PROPERTY(QByteArray leftBytes READ leftBytes NOTIFY bytesChanged)
    Q_PROPERTY(QByteArray rightBytes READ rightBytes NOTIFY bytesChanged)
    Q_PROPERTY(int leftChangeOffset READ leftChangeOffset NOTIFY bytesChanged)
    Q_PROPERTY(int leftChangeLength READ leftChangeLength NOTIFY bytesChanged)
    Q_PROPERTY(int rightChangeOffset READ rightChangeOffset NOTIFY bytesChanged)
    Q_PROPERTY(int rightChangeLength READ rightChangeLength NOTIFY bytesChanged)

public:
    explicit DiffController(QObject *parent = nullptr);

    DiffPoolModel *pool() const { return m_pool; }
    QString contentKind() const { return m_contentKind; }
    QString displayMode() const { return m_displayMode; }
    QVariantList sideBySideRows() const { return m_sideBySideRows; }
    QVariantList unifiedRows() const { return m_unifiedRows; }
    QVariantList changeRows() const { return m_changeRows; }
    int differenceCount() const { return m_changeRows.size(); }
    bool ready() const;
    bool loading() const;
    QString error() const;
    QString leftTitle() const;
    QString rightTitle() const;
    QByteArray leftBytes() const { return m_left.bytes; }
    QByteArray rightBytes() const { return m_right.bytes; }
    int leftChangeOffset() const { return m_byteRange.leftOffset; }
    int leftChangeLength() const { return m_byteRange.leftLength; }
    int rightChangeOffset() const { return m_byteRange.rightOffset; }
    int rightChangeLength() const { return m_byteRange.rightLength; }

    void setContentKind(const QString &kind);
    void setDisplayMode(const QString &mode);

    Q_INVOKABLE void addPacket(const QString &sourceID, const QString &packetID,
                               quint64 number, const QString &summary);
    Q_INVOKABLE void setSide(const QString &entryID, const QString &side);
    Q_INVOKABLE void removeEntry(const QString &entryID);
    Q_INVOKABLE void clear();
    Q_INVOKABLE int nextChangeRow(int currentRow, bool backwards) const;

signals:
    void contentKindChanged();
    void displayModeChanged();
    void rowsChanged();
    void stateChanged();
    void titlesChanged();
    void bytesChanged();

private:
    struct Side {
        DaemonClient *client = nullptr;
        QString entryID;
        QString packetID;
        QString sourceID;
        QStringList lines;
        QByteArray bytes;
        bool detailsLoaded = false;
        bool bytesLoaded = false;
        QString error;
    };

    void updateSides();
    void requestSide(Side &side);
    void handleResponse(Side &side, const QString &command, const QVariantMap &data);
    void handleFailure(Side &side, const QString &command, const QString &message);
    void recomputeDetails();
    void recomputeBytes();
    void rebuildChangeRows();
    QString titleForSide(const QString &side) const;
    bool sideReady(const Side &side) const;

    DiffPoolModel *m_pool = nullptr;
    Side m_left;
    Side m_right;
    QString m_contentKind = QStringLiteral("details");
    QString m_displayMode = QStringLiteral("sideBySide");
    QVariantList m_sideBySideRows;
    QVariantList m_unifiedRows;
    QVariantList m_changeRows;
    DiffByteRange m_byteRange;
};

#endif // DIFFCONTROLLER_H
