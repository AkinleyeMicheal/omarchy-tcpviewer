#include "packetmodel.h"

PacketListModel::PacketListModel(QObject *parent)
    : QAbstractListModel(parent)
{
}

int PacketListModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : m_rows.size();
}

QVariant PacketListModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_rows.size())
        return {};

    const PacketRow &row = m_rows.at(index.row());
    switch (role) {
    case NumberRole:
        return QVariant::fromValue(row.number);
    case TimeRole:
        return row.timeText;
    case SourceRole:
        return row.source;
    case SourcePortRole:
        return row.sourcePort;
    case DestinationRole:
        return row.destination;
    case DestinationPortRole:
        return row.destinationPort;
    case ProtocolRole:
        return row.protocol;
    case ClientRole:
        return row.client;
    case DomainRole:
        return row.domain;
    case StreamIdRole:
        return row.streamId;
    case LengthRole:
        return row.length;
    case SummaryRole:
        return row.summary;
    case SeverityRole:
        return row.severity;
    default:
        return {};
    }
}

QHash<int, QByteArray> PacketListModel::roleNames() const
{
    return {
        {NumberRole, "number"},
        {TimeRole, "time"},
        {SourceRole, "source"},
        {SourcePortRole, "sourcePort"},
        {DestinationRole, "destination"},
        {DestinationPortRole, "destinationPort"},
        {ProtocolRole, "protocol"},
        {ClientRole, "client"},
        {DomainRole, "domain"},
        {StreamIdRole, "streamId"},
        {LengthRole, "length"},
        {SummaryRole, "summary"},
        {SeverityRole, "severity"},
    };
}

void PacketListModel::clear()
{
    if (m_rows.isEmpty())
        return;
    beginRemoveRows({}, 0, m_rows.size() - 1);
    m_rows.clear();
    endRemoveRows();
    emit countChanged();
}

void PacketListModel::appendRows(const QVector<PacketRow> &rows)
{
    if (rows.isEmpty())
        return;

    const int first = m_rows.size();
    const int last = first + rows.size() - 1;
    beginInsertRows({}, first, last);
    m_rows.append(rows);
    endInsertRows();
    emit countChanged();
}
