#include "endpointstatsmodel.h"

#include "packetmodel.h"

#include <QLocale>
#include <algorithm>

namespace {
constexpr int kColumnCount = 12;

// Upstream numeric cells use grouped integers; footers humanize bytes.
QString groupedCount(qint64 value)
{
    return value == 0 ? QStringLiteral("0") : QLocale().toString(value);
}

QString humanizeBytes(qint64 value)
{
    if (value < 0)
        value = 0;
    const qint64 kb = 1024;
    if (value < kb)
        return QStringLiteral("%1 B").arg(value);
    if (value < kb * kb)
        return QStringLiteral("%1 KB").arg(value / double(kb), 0, 'f', 1);
    if (value < qint64(kb) * kb * kb)
        return QStringLiteral("%1 MB").arg(value / double(kb * kb), 0, 'f', 1);
    return QStringLiteral("%1 GB").arg(value / double(qint64(kb) * kb * kb), 0, 'f', 1);
}

int groupIndexForCanonical(const QString &address)
{
    const bool dotted = address.contains(QLatin1Char('.'));
    const bool colon = address.contains(QLatin1Char(':'));
    if (colon)
        return EndpointStatisticsModel::Group::Ipv6;
    if (dotted)
        return EndpointStatisticsModel::Group::Ipv4;
    return -1; // MAC / other non-IP endpoints are not grouped upstream
}

// TCP family vs UDP family (partial upstream transportGroup level hint).
int transportGroupForProtocol(const QString &protocol)
{
    const QString upper = protocol.toUpper();
    if (upper.contains(QLatin1String("TCP"))
        || upper.contains(QLatin1String("HTTP"))
        || upper.contains(QLatin1String("TLS"))
        || upper.contains(QLatin1String("SSL"))
        || upper.contains(QLatin1String("WEBSOCKET")))
        return EndpointStatisticsModel::Group::Tcp;
    if (upper.contains(QLatin1String("UDP"))
        || upper.contains(QLatin1String("DNS")))
        return EndpointStatisticsModel::Group::Udp;
    return -1;
}
} // namespace

void EndpointStatisticsModel::Totals::add(const Totals &other)
{
    packets += other.packets;
    bytes += other.bytes;
    txPackets += other.txPackets;
    txBytes += other.txBytes;
    rxPackets += other.rxPackets;
    rxBytes += other.rxBytes;
    unclassifiedPackets += other.unclassifiedPackets;
    unclassifiedBytes += other.unclassifiedBytes;
}

QString EndpointStatisticsModel::Totals::summaryText() const
{
    const qint64 classifiedBytes = txBytes + rxBytes + unclassifiedBytes;
    if (classifiedBytes <= 0)
        return QStringLiteral("No byte data");
    const auto percent = [classifiedBytes](qint64 value) {
        return int(double(value) / double(classifiedBytes) * 100.0 + 0.5);
    };
    QStringList parts;
    if (txBytes > 0)
        parts << QStringLiteral("Tx %1%").arg(percent(txBytes));
    if (rxBytes > 0)
        parts << QStringLiteral("Rx %1%").arg(percent(rxBytes));
    if (unclassifiedBytes > 0)
        parts << QStringLiteral("Unclassified %1%").arg(percent(unclassifiedBytes));
    return parts.join(QStringLiteral(" · "));
}

void EndpointStatisticsModel::ValueCounts::add(const QStringList &values)
{
    for (const QString &value : values) {
        if (value.isEmpty())
            continue;
        counts[value]++;
    }
}

void EndpointStatisticsModel::ValueCounts::remove(const QStringList &values)
{
    for (const QString &value : values) {
        auto it = counts.find(value);
        if (it == counts.end())
            continue;
        if (it.value() > 1)
            --it.value();
        else
            counts.erase(it);
    }
}

QString EndpointStatisticsModel::ValueCounts::displayValue(bool *isMultiple) const
{
    if (isMultiple)
        *isMultiple = counts.size() > 1;
    return counts.size() == 1 ? counts.constBegin().key() : counts.size() > 1
        ? QStringLiteral("Multiple") : QString();
}

EndpointStatisticsModel::EndpointStatisticsModel(QObject *parent)
    : QAbstractTableModel(parent)
{
}

int EndpointStatisticsModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : m_rows.size();
}

int EndpointStatisticsModel::columnCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : kColumnCount;
}

QHash<int, QByteArray> EndpointStatisticsModel::roleNames() const
{
    return {
        {AddressRole, "address"},
        {PortRole, "port"},
        {ProtocolRole, "protocol"},
        {ClientRole, "client"},
        {DomainRole, "domain"},
        {PacketsRole, "packets"},
        {BytesRole, "bytes"},
        {TxPacketsRole, "txPackets"},
        {TxBytesRole, "txBytes"},
        {RxPacketsRole, "rxPackets"},
        {RxBytesRole, "rxBytes"},
        {SummaryRole, "summary"},
        {IsMultipleRole, "isMultiple"},
        {CountRole, "count"},
    };
}

QVariant EndpointStatisticsModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() >= m_rows.size() || index.column() >= kColumnCount)
        return {};
    const Bucket &bucket = m_rows.at(index.row());
    if (role == CountRole)
        return bucket.totals.packets;
    if (role == IsMultipleRole) {
        switch (index.column()) {
        case 0: return bucket.identityAddress.isEmpty() && !bucket.addresses.empty() && bucket.addresses.counts.size() > 1;
        case 1: return bucket.identityPort.isEmpty() && bucket.ports.counts.size() > 1;
        case 2: return bucket.protocols.counts.size() > 1;
        case 3: return bucket.clients.counts.size() > 1;
        case 4: return bucket.domains.counts.size() > 1;
        default: return false;
        }
    }
    switch (role) {
    case AddressRole:
        return bucket.identityAddress.isEmpty()
            ? bucket.addresses.displayValue(nullptr) : bucket.identityAddress;
    case PortRole:
        return bucket.identityPort.isEmpty()
            ? bucket.ports.displayValue(nullptr) : bucket.identityPort;
    case ProtocolRole:
        return bucket.protocols.displayValue(nullptr);
    case ClientRole:
        return bucket.clients.displayValue(nullptr);
    case DomainRole:
        return bucket.domains.displayValue(nullptr);
    case PacketsRole:
        return groupedCount(bucket.totals.packets);
    case BytesRole:
        return groupedCount(bucket.totals.bytes);
    case TxPacketsRole:
        return groupedCount(bucket.totals.txPackets);
    case TxBytesRole:
        return groupedCount(bucket.totals.txBytes);
    case RxPacketsRole:
        return groupedCount(bucket.totals.rxPackets);
    case RxBytesRole:
        return groupedCount(bucket.totals.rxBytes);
    case SummaryRole:
        return bucket.totals.summaryText();
    default:
        return {};
    }
}

void EndpointStatisticsModel::setGroup(int group)
{
    const int bounded = qBound(0, group, GroupCount - 1);
    if (m_group == bounded)
        return;
    m_group = bounded;
    emit groupChanged();
    refreshView();
}

QVariantList EndpointStatisticsModel::groupCounts() const
{
    QVariantList counts;
    for (int group = 0; group < GroupCount; ++group)
        counts.append(m_buckets[group].size());
    return counts;
}

EndpointStatisticsModel::Totals EndpointStatisticsModel::directionalTotals(qint64 bytes, const QString &direction, bool reversed)
{
    Totals totals;
    totals.packets = 1;
    totals.bytes = bytes;
    if (direction == QStringLiteral("outbound")) {
        (reversed ? totals.rxPackets : totals.txPackets) = 1;
        (reversed ? totals.rxBytes : totals.txBytes) = bytes;
    } else if (direction == QStringLiteral("inbound")) {
        (reversed ? totals.txPackets : totals.rxPackets) = 1;
        (reversed ? totals.txBytes : totals.rxBytes) = bytes;
    } else {
        totals.unclassifiedPackets = 1;
        totals.unclassifiedBytes = bytes;
    }
    return totals;
}

EndpointStatisticsModel::Totals EndpointStatisticsModel::endpointTotals(qint64 bytes, bool source, bool destination)
{
    const int occurrences = int(source) + int(destination);
    Totals totals;
    totals.packets = occurrences;
    totals.bytes = bytes * occurrences;
    totals.txPackets = source ? 1 : 0;
    totals.txBytes = source ? bytes : 0;
    totals.rxPackets = destination ? 1 : 0;
    totals.rxBytes = destination ? bytes : 0;
    return totals;
}

QString EndpointStatisticsModel::transportKey(const Endpoint &endpoint)
{
    return QStringLiteral("%1:%2").arg(endpoint.address, endpoint.port);
}

void EndpointStatisticsModel::commit(const Contribution &contribution)
{
    // Find first: operator[] would default-insert and make the guard useless.
    auto it = m_buckets[contribution.group].find(contribution.key);
    if (it != m_buckets[contribution.group].end()) {
        it->totals.add(contribution.totals);
        it->addresses.add(contribution.addresses);
        it->ports.add(contribution.ports);
        it->protocols.add(contribution.protocols);
        it->clients.add(contribution.clients);
        it->domains.add(contribution.domains);
        return;
    }
    Bucket fresh;
    fresh.key = contribution.key;
    fresh.identityAddress = contribution.address;
    fresh.identityPort = contribution.identityPort;
    fresh.totals = contribution.totals;
    fresh.addresses.add(contribution.addresses);
    fresh.ports.add(contribution.ports);
    fresh.protocols.add(contribution.protocols);
    fresh.clients.add(contribution.clients);
    fresh.domains.add(contribution.domains);
    m_buckets[contribution.group].insert(contribution.key, fresh);
}

void EndpointStatisticsModel::applyContribution(int group, const QString &key,
                                                const QString &address, const QString &identityPort,
                                                const Totals &totals, const QStringList &addresses,
                                                const QStringList &ports, const QStringList &protocols,
                                                const QStringList &clients, const QStringList &domains)
{
    Contribution contribution;
    contribution.group = group;
    contribution.key = key;
    contribution.address = address;
    contribution.identityPort = identityPort;
    contribution.totals = totals;
    contribution.addresses = addresses;
    contribution.ports = ports;
    contribution.protocols = protocols;
    contribution.clients = clients;
    contribution.domains = domains;
    commit(contribution);
}

void EndpointStatisticsModel::rebuild(QObject *packets)
{
    // QML passes the PacketListModel; keep the read generic via snapshotRows().
    if (!packets || packets->metaObject() == nullptr)
        return;
    QVariantList rowList;
    if (const QMetaObject *meta = packets->metaObject();
        meta->indexOfMethod("snapshotRows()") >= 0) {
        QMetaObject::invokeMethod(packets, "snapshotRows", Q_RETURN_ARG(QVariantList, rowList));
    } else {
        return;
    }

    // Bucket state is invisible until refreshView() resets around m_rows, so
    // clearing + refilling here needs no outer reset (begin/end must pair).
    for (int group = 0; group < GroupCount; ++group)
        m_buckets[group].clear();
    m_footerTotals = Totals();

    for (const QVariant &value : rowList) {
        const QVariantMap row = value.toMap();
        PacketFacts facts;
        facts.bytes = qMax<qint64>(
            row.value(QStringLiteral("originalLength"), row.value(QStringLiteral("length")))
                .toLongLong(), 0);
        facts.direction = row.value(QStringLiteral("direction")).toString();
        facts.protocolName = row.value(QStringLiteral("protocol")).toString();
        if (facts.protocolName.isEmpty())
            facts.protocolName = QStringLiteral("Unknown");
        facts.client = row.value(QStringLiteral("client")).toString();
        facts.domain = row.value(QStringLiteral("domain")).toString();
        facts.source.address = row.value(QStringLiteral("source")).toString();
        facts.source.port = row.value(QStringLiteral("sourcePort")).toString();
        facts.destination.address = row.value(QStringLiteral("destination")).toString();
        facts.destination.port = row.value(QStringLiteral("destinationPort")).toString();
        facts.source.canonical = groupIndexForCanonical(facts.source.address) >= 0;
        facts.destination.canonical = groupIndexForCanonical(facts.destination.address) >= 0;

        m_footerTotals.add(directionalTotals(facts.bytes, facts.direction, false));

        // App/domain related values point at the remote endpoint only.
        QStringList remoteAddresses;
        QStringList remotePorts;
        if (facts.direction == QStringLiteral("outbound")) {
            remoteAddresses = {facts.destination.address};
            remotePorts = {facts.destination.port};
        } else if (facts.direction == QStringLiteral("inbound")) {
            remoteAddresses = {facts.source.address};
            remotePorts = {facts.source.port};
        } else {
            remoteAddresses = {facts.source.address, facts.destination.address};
            remotePorts = {facts.source.port, facts.destination.port};
        }

        if (!facts.client.isEmpty()) {
            applyContribution(Group::Apps, facts.client, QString(), QString(),
                directionalTotals(facts.bytes, facts.direction, false),
                remoteAddresses, remotePorts, {facts.protocolName},
                {facts.client}, {facts.domain});
        }
        // Domains reverse the direction for their totals (upstream behavior).
        if (!facts.domain.isEmpty()) {
            applyContribution(Group::Domains, facts.domain, QString(), QString(),
                directionalTotals(facts.bytes, facts.direction, true),
                remoteAddresses, remotePorts, {facts.protocolName},
                {facts.client}, {facts.domain});
        }

        const int transport = transportGroupForProtocol(facts.protocolName);
        // Two passes per packet: canonical address groups, then transport groups.
        for (int context = 0; context < 2; ++context) {
            const bool transportContext = context == 1;
            if (transportContext && transport < 0)
                continue;
            const Endpoint endpoints[2] = {facts.source, facts.destination};
            for (int side = 0; side < 2; ++side) {
                const Endpoint &endpoint = endpoints[side];
                const bool supported = transportContext
                    ? !endpoint.port.isEmpty()
                    : endpoint.canonical;
                if (!supported || endpoint.address.isEmpty())
                    continue;
                applyContribution(
                    transportContext ? transport : groupIndexForCanonical(endpoint.address),
                    transportContext ? transportKey(endpoint) : endpoint.address,
                    endpoint.address,
                    transportContext ? endpoint.port : QString(),
                    endpointTotals(facts.bytes, side == 0, side == 1),
                    {endpoint.address},
                    transportContext ? QStringList{} : QStringList{endpoint.port},
                    {facts.protocolName}, {facts.client}, {facts.domain});
            }
        }
    }

    refreshView();
}

void EndpointStatisticsModel::refreshView()
{
    // Busiest first (upstream default sort), key as stable tiebreaker.
    QVector<Bucket> rows;
    for (const Bucket &bucket : m_buckets[m_group])
        rows.append(bucket);
    std::sort(rows.begin(), rows.end(), [](const Bucket &lhs, const Bucket &rhs) {
        if (lhs.totals.bytes != rhs.totals.bytes)
            return lhs.totals.bytes > rhs.totals.bytes;
        return lhs.key < rhs.key;
    });

    beginResetModel();
    m_rows = rows;
    endResetModel();
    refreshFooter();
    emit footerChanged();
}

void EndpointStatisticsModel::refreshFooter()
{
    m_scopeTotals = Totals();
    for (const Bucket &bucket : m_rows)
        m_scopeTotals.add(bucket.totals);

    const int count = m_rows.size();
    const QString endpointText = count == 1
        ? QStringLiteral("1 endpoint") : QStringLiteral("%1 endpoints").arg(count);
    const QString packetText = m_scopeTotals.packets == 1
        ? QStringLiteral("1 packet") : QStringLiteral("%1 packets").arg(m_scopeTotals.packets);
    QStringList parts {endpointText, packetText};
    if (m_scopeTotals.txBytes > 0)
        parts << QStringLiteral("Tx %1").arg(humanizeBytes(m_scopeTotals.txBytes));
    if (m_scopeTotals.rxBytes > 0)
        parts << QStringLiteral("Rx %1").arg(humanizeBytes(m_scopeTotals.rxBytes));
    if (m_scopeTotals.unclassifiedBytes > 0)
        parts << QStringLiteral("Unclassified %1").arg(humanizeBytes(m_scopeTotals.unclassifiedBytes));
    m_footerText = parts.join(QStringLiteral(" · "));
}
