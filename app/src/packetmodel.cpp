#include "packetmodel.h"

#include <QVariantMap>

PacketListModel::PacketListModel(QObject *parent)
    : QAbstractTableModel(parent)
{
}

int PacketListModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : m_rows.size();
}

int PacketListModel::columnCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : m_columnCount;
}

void PacketListModel::setColumnCount(int count)
{
    count = qMax(1, count);
    if (count == m_columnCount)
        return;
    beginResetModel();
    m_columnCount = count;
    endResetModel();
}

QVariant PacketListModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_rows.size())
        return {};

    const PacketRow &row = m_rows.at(index.row());
    switch (role) {
    case NumberRole:
        return QVariant::fromValue(row.number);
    case PacketIdRole:
        return row.packetId;
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
    case TcpFlagsRole:
        return row.tcpFlags;
    case DirectionRole:
        return row.direction;
    case InterfaceRole:
        return row.interfaceName;
    case DecodeStatusRole:
        return row.decodeStatus;
    case SourceKindRole:
        return row.sourceKind;
    case TcpPayloadRole:
        return row.tcpPayloadLength;
    default:
        return {};
    }
}

QHash<int, QByteArray> PacketListModel::roleNames() const
{
    return {
        {NumberRole, "number"},
        {PacketIdRole, "packetId"},
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
        {TcpFlagsRole, "tcpFlags"},
        {DirectionRole, "direction"},
        {InterfaceRole, "interface"},
        {DecodeStatusRole, "decodeStatus"},
        {SourceKindRole, "sourceKind"},
        {TcpPayloadRole, "tcpPayloadLength"},
    };
}

void PacketListModel::clear()
{
    m_lastPacketID = 0;
    if (m_rows.isEmpty())
        return;
    beginRemoveRows({}, 0, m_rows.size() - 1);
    m_rows.clear();
    endRemoveRows();
    emit countChanged();
}

QString PacketListModel::packetIDAt(int row) const
{
    if (row < 0 || row >= m_rows.size())
        return {};
    return QString::number(m_rows.at(row).number);
}

int PacketListModel::rowForPacketID(const QString &packetID) const
{
    const quint64 id = packetID.toULongLong();
    for (int row = 0; row < m_rows.size(); ++row) {
        if (m_rows.at(row).number == id)
            return row;
    }
    return -1;
}

QVariantList PacketListModel::snapshotRows() const
{
    QVariantList snapshot;
    snapshot.reserve(m_rows.size());
    for (const PacketRow &row : m_rows) {
        QVariantMap map;
        map.insert(QStringLiteral("number"), QVariant::fromValue(row.number));
        map.insert(QStringLiteral("length"), row.length);
        // Older daemons may omit original_length; statistics fall back to length.
        map.insert(QStringLiteral("originalLength"),
                   row.originalLength > 0 ? row.originalLength : row.length);
        map.insert(QStringLiteral("source"), row.source);
        map.insert(QStringLiteral("sourcePort"), row.sourcePort);
        map.insert(QStringLiteral("destination"), row.destination);
        map.insert(QStringLiteral("destinationPort"), row.destinationPort);
        map.insert(QStringLiteral("protocol"), row.protocol);
        map.insert(QStringLiteral("client"), row.client);
        map.insert(QStringLiteral("domain"), row.domain);
        map.insert(QStringLiteral("direction"), row.direction);
        snapshot.append(map);
    }
    return snapshot;
}

const QString &PacketListModel::protocolAt(int row) const
{
    static const QString empty;
    if (row < 0 || row >= m_rows.size())
        return empty;
    return m_rows.at(row).protocol;
}

void PacketListModel::appendRows(const QVector<PacketRow> &rows)
{
    if (rows.isEmpty())
        return;

    const int first = m_rows.size();
    const int last = first + rows.size() - 1;
    beginInsertRows({}, first, last);
    m_rows.append(rows);
    for (const PacketRow &row : rows) {
        if (row.number > m_lastPacketID)
            m_lastPacketID = row.number;
    }
    endInsertRows();
    emit countChanged();
}
