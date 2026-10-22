#pragma once

#include <QAbstractListModel>
#include <QString>
#include <QVector>
#include <QtQml/qqmlregistration.h>

// One packet-table row. Mirrors the fields of the daemon's packets.list summary
// that the upstream table shows as columns (see app/design/tokens.md).
struct PacketRow {
    quint64 number = 0;
    QString timeText;
    QString source;
    QString sourcePort;
    QString destination;
    QString destinationPort;
    QString protocol;
    QString client;
    QString domain;
    QString streamId;
    QString summary;
    int length = 0;
    int severity = 0; // 0 normal, 1 warning (orange summary)
};

class PacketListModel : public QAbstractListModel
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(int count READ count NOTIFY countChanged)

public:
    enum Role {
        NumberRole = Qt::UserRole + 1,
        TimeRole,
        SourceRole,
        SourcePortRole,
        DestinationRole,
        DestinationPortRole,
        ProtocolRole,
        ClientRole,
        DomainRole,
        StreamIdRole,
        LengthRole,
        SummaryRole,
        SeverityRole,
    };
    Q_ENUM(Role)

    explicit PacketListModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    Q_INVOKABLE void clear();

    // Appends a batch in one beginInsertRows/endInsertRows pair, matching the
    // upstream table's coalesced row inserts.
    void appendRows(const QVector<PacketRow> &rows);

    int count() const { return m_rows.size(); }

signals:
    void countChanged();

private:
    QVector<PacketRow> m_rows;
    quint64 m_nextNumber = 1;
};
