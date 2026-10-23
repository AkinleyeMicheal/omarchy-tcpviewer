#include "packetmodel.h"

#include <QVariantMap>

PacketListModel::PacketListModel(QObject *parent)
    : QAbstractTableModel(parent)
{
}

int PacketListModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : visibleRowCount();
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
    if (!index.isValid())
        return {};

    const int rowIndex = sourceRow(index.row());
    if (rowIndex < 0 || rowIndex >= m_rows.size())
        return {};

    const PacketRow &row = m_rows.at(rowIndex);
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
    case ClientKeyRole:
        return row.clientKey;
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
    case ClientPidRole:
        return row.clientPid > 0 ? QVariant(row.clientPid) : QVariant();
    case DeltaTimeRole:
        return row.deltaTime;
    case StreamDeltaRole:
        return row.streamDeltaTime;
    case BundleIdentifierRole:
        return row.clientKey;
    case CommentRole:
        return row.comment;
    case TagsRole:
        return QString();
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
        {ClientKeyRole, "clientKey"},
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
        {ClientPidRole, "clientPid"},
        {DeltaTimeRole, "deltaTime"},
        {StreamDeltaRole, "streamDeltaTime"},
        {BundleIdentifierRole, "bundleIdentifier"},
        {CommentRole, "comment"},
        {TagsRole, "tags"},
    };
}

void PacketListModel::clear()
{
    const int oldVisible = visibleRowCount();
    if (m_treeFilterActive) {
        if (oldVisible > 0) {
            beginRemoveRows({}, 0, oldVisible - 1);
            m_rows.clear();
            m_visibleRows.clear();
            endRemoveRows();
        } else {
            m_rows.clear();
            m_visibleRows.clear();
        }
    } else if (!m_rows.isEmpty()) {
        beginRemoveRows({}, 0, m_rows.size() - 1);
        m_rows.clear();
        endRemoveRows();
    }
    m_lastPacketID = 0;
    emit countChanged();
}

int PacketListModel::visibleRowCount() const
{
    return m_treeFilterActive ? m_visibleRows.size() : m_rows.size();
}

int PacketListModel::sourceRow(int visibleRow) const
{
    if (!m_treeFilterActive)
        return visibleRow >= 0 && visibleRow < m_rows.size() ? visibleRow : -1;
    if (visibleRow < 0 || visibleRow >= m_visibleRows.size())
        return -1;
    return m_visibleRows.at(visibleRow);
}

bool PacketListModel::matchesTreeFilter(const PacketRow &row) const
{
    if (!m_treeFilterActive)
        return true;

    if (m_treeFilterAppsOnly && row.clientKey.isEmpty())
        return false;
    if (!m_treeFilterAppKey.isEmpty() && row.clientKey != m_treeFilterAppKey)
        return false;

    const QString domain = normalizedPacketDomain(row.domain);
    if (m_treeFilterMissingDomain) {
        if (!domain.isEmpty())
            return false;
    } else if (!m_treeFilterDomainKey.isEmpty() && domain != m_treeFilterDomainKey) {
        return false;
    }

    if (!m_treeFilterIP.isEmpty()) {
        // Upstream only places no-domain packets in IP buckets.
        if (!domain.isEmpty())
            return false;
        if (normalizedPacketIP(row.source) != m_treeFilterIP
            && normalizedPacketIP(row.destination) != m_treeFilterIP) {
            return false;
        }
    }

    return true;
}

void PacketListModel::rebuildVisibleRows()
{
    m_visibleRows.clear();
    if (!m_treeFilterActive)
        return;

    m_visibleRows.reserve(m_rows.size());
    for (int row = 0; row < m_rows.size(); ++row) {
        if (matchesTreeFilter(m_rows.at(row)))
            m_visibleRows.append(row);
    }
}

void PacketListModel::setTreeFilter(const QString &appKey, const QString &domainKey,
                                    const QString &ip, bool appsOnly, bool missingDomain)
{
    const QString nextAppKey = appKey.trimmed();
    const QString nextDomainKey = normalizedPacketDomain(domainKey);
    const QString nextIP = normalizedPacketIP(ip);
    const bool nextActive = appsOnly || !nextAppKey.isEmpty() || !nextDomainKey.isEmpty()
        || missingDomain || !nextIP.isEmpty();

    if (m_treeFilterActive == nextActive
        && m_treeFilterAppsOnly == appsOnly
        && m_treeFilterMissingDomain == missingDomain
        && m_treeFilterAppKey == nextAppKey
        && m_treeFilterDomainKey == nextDomainKey
        && m_treeFilterIP == nextIP) {
        return;
    }

    beginResetModel();
    m_treeFilterActive = nextActive;
    m_treeFilterAppsOnly = appsOnly;
    m_treeFilterMissingDomain = missingDomain;
    m_treeFilterAppKey = nextAppKey;
    m_treeFilterDomainKey = nextDomainKey;
    m_treeFilterIP = nextIP;
    rebuildVisibleRows();
    endResetModel();
    emit treeFilterChanged();
    emit countChanged();
}

void PacketListModel::clearTreeFilter()
{
    setTreeFilter({}, {}, {}, false, false);
}

int PacketListModel::numberAt(int row) const
{
    const int source = sourceRow(row);
    return source >= 0 ? static_cast<int>(m_rows.at(source).number) : 0;
}

QString PacketListModel::summaryAt(int row) const
{
    const int source = sourceRow(row);
    return source >= 0 ? m_rows.at(source).summary : QString();
}

QString PacketListModel::packetIDAt(int row) const
{
    const int source = sourceRow(row);
    if (source < 0)
        return {};
    return QString::number(m_rows.at(source).number);
}

int PacketListModel::rowForPacketID(const QString &packetID) const
{
    const quint64 id = packetID.toULongLong();
    if (m_treeFilterActive) {
        for (int row = 0; row < m_visibleRows.size(); ++row) {
            if (m_rows.at(m_visibleRows.at(row)).number == id)
                return row;
        }
        return -1;
    }

    for (int row = 0; row < m_rows.size(); ++row) {
        if (m_rows.at(row).number == id)
            return row;
    }
    return -1;
}

QVariantList PacketListModel::snapshotRows() const
{
    QVariantList snapshot;
    const int visible = visibleRowCount();
    snapshot.reserve(visible);
    for (int rowIndex = 0; rowIndex < visible; ++rowIndex) {
        const int source = sourceRow(rowIndex);
        if (source < 0)
            continue;
        const PacketRow &row = m_rows.at(source);
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
    const int source = sourceRow(row);
    if (source < 0)
        return empty;
    return m_rows.at(source).protocol;
}

void PacketListModel::appendRows(const QVector<PacketRow> &rows)
{
    if (rows.isEmpty())
        return;

    if (m_treeFilterActive) {
        const int firstSource = m_rows.size();
        const int firstVisible = m_visibleRows.size();
        QVector<int> newVisible;
        newVisible.reserve(rows.size());
        for (int i = 0; i < rows.size(); ++i) {
            if (matchesTreeFilter(rows.at(i)))
                newVisible.append(firstSource + i);
        }

        if (!newVisible.isEmpty())
            beginInsertRows({}, firstVisible, firstVisible + newVisible.size() - 1);
        m_rows.append(rows);
        m_visibleRows.append(newVisible);
        if (!newVisible.isEmpty())
            endInsertRows();
    } else {
        const int first = m_rows.size();
        beginInsertRows({}, first, first + rows.size() - 1);
        m_rows.append(rows);
        endInsertRows();
    }

    for (const PacketRow &row : rows) {
        if (row.number > m_lastPacketID)
            m_lastPacketID = row.number;
    }
    // totalCount changed even when the active filter hides every new row.
    emit countChanged();
}
