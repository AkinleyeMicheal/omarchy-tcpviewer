#include "endpointstatsmodel.h"

#include "packetmodel.h"

#include <QCollator>
#include <QRegularExpression>
#include <QLocale>
#include <QSet>
#include <algorithm>

namespace {
constexpr int kColumnCount = 12;

// Column catalog shared with the exporters; wire order matches upstream
// EndpointStatisticsTableColumn (titles, snake_case JSON keys).
constexpr const char *kColumnTitles[kColumnCount] = {
    "Address", "Port", "Protocol", "Client", "Domain", "Packets",
    "Bytes", "Tx Packets", "Tx Bytes", "Rx Packets", "Rx Bytes", "Summary",
};
constexpr const char *kColumnJsonKeys[kColumnCount] = {
    "address", "port", "protocol", "client", "domain", "packets",
    "bytes", "tx_packets", "tx_bytes", "rx_packets", "rx_bytes", "summary",
};

// Upstream numeric columns sort busiest-first on first click.
bool isNumericColumn(int column)
{
    return column >= EndpointStatisticsModel::Column::Packets
        && column <= EndpointStatisticsModel::Column::RxBytes;
}

int compareQuantified(qint64 lhs, qint64 rhs)
{
    return lhs < rhs ? -1 : (lhs > rhs ? 1 : 0);
}

bool needsFormulaProtection(const QString &value);

// CSV field: quote when it contains a delimiter/newline; prefix an
// apostrophe so spreadsheet apps do not run formula injection.
QString csvField(const QString &value, bool protectsFormula)
{
    QString field = value;
    if (protectsFormula && needsFormulaProtection(field))
        field.prepend(QLatin1Char('\''));
    if (field.contains(QLatin1Char(',')) || field.contains(QLatin1Char('"'))
        || field.contains(QLatin1Char('\r')) || field.contains(QLatin1Char('\n'))) {
        field.replace(QLatin1Char('"'), QStringLiteral("\"\""));
        return QLatin1Char('"') + field + QLatin1Char('"');
    }
    return field;
}

bool needsFormulaProtection(const QString &value)
{
    if (!value.isEmpty()
        && (value.at(0) == QLatin1Char('\t') || value.at(0) == QLatin1Char('\r')))
        return true;
    for (const QChar &character : value) {
        if (!character.isSpace())
            return QStringLiteral("=+-@").contains(character);
    }
    return false;
}

QString jsonString(const QString &value)
{
    QString result = QStringLiteral("\"");
    for (const QChar &character : value) {
        switch (character.unicode()) {
        case 0x22: result += QStringLiteral("\\\""); break;
        case 0x5C: result += QStringLiteral("\\\\"); break;
        case 0x08: result += QStringLiteral("\\b"); break;
        case 0x0C: result += QStringLiteral("\\f"); break;
        case 0x0A: result += QStringLiteral("\\n"); break;
        case 0x0D: result += QStringLiteral("\\r"); break;
        case 0x09: result += QStringLiteral("\\t"); break;
        default:
            if (character.unicode() < 0x20)
                result += QStringLiteral("\\u%1").arg(int(character.unicode()), 4, 16, QLatin1Char('0'));
            else
                result += character;
        }
    }
    return result + QLatin1Char('"');
}

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
        {KeyRole, "key"},
    };
}

QVariant EndpointStatisticsModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() >= m_rows.size() || index.column() >= kColumnCount)
        return {};
    const Bucket &bucket = m_rows.at(index.row());
    if (role == CountRole)
        return bucket.totals.packets;
    if (role == KeyRole)
        return bucket.key;
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
    // Sort state is per group (upstream sortByGroup).
    emit sortChanged();
    refreshView();
}

void EndpointStatisticsModel::setSearchText(const QString &text)
{
    if (m_searchText == text)
        return;
    m_searchText = text;
    emit searchChanged();
    refreshView();
}

void EndpointStatisticsModel::clickSort(int column)
{
    if (column < 0 || column >= kColumnCount)
        return;
    if (m_sortColumn[m_group] == column) {
        m_sortAscending[m_group] = !m_sortAscending[m_group];
    } else {
        m_sortColumn[m_group] = column;
        // AppKit sortDescriptorPrototype: numeric columns start descending.
        m_sortAscending[m_group] = !isNumericColumn(column);
    }
    emit sortChanged();
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
        // Apps group by the stable identity (executable path), matching the
        // sidebar's app keys; the display name stays a related value.
        facts.clientKey = row.value(QStringLiteral("clientKey")).toString();
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

        // Apps group the client identity; two processes sharing a display
        // name stay separate rows (upstream PacketSourceClientKey).
        if (!facts.clientKey.isEmpty()) {
            applyContribution(Group::Apps, facts.clientKey, QString(), QString(),
                directionalTotals(facts.bytes, facts.direction, false),
                remoteAddresses, remotePorts, {facts.protocolName},
                {facts.client.isEmpty() ? facts.clientKey : facts.client}, {facts.domain});
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
    // Search first (upstream presentation filter), then the group's sort.
    QVector<Bucket> rows;
    rows.reserve(m_buckets[m_group].size());
    for (const Bucket &bucket : m_buckets[m_group]) {
        if (matchesSearch(bucket))
            rows.append(bucket);
    }
    sortRows(rows);

    beginResetModel();
    m_rows = rows;
    endResetModel();
    refreshFooter();
    emit footerChanged();
}

// Whitespace-split terms, ALL contained in the joined identity fields
// (upstream EndpointStatisticsTablePresenter).
bool EndpointStatisticsModel::matchesSearch(const Bucket &bucket) const
{
    const QStringList terms = m_searchText.split(QRegularExpression(QStringLiteral("\\s+")),
        Qt::SkipEmptyParts);
    if (terms.isEmpty())
        return true;
    const QString searchable = QStringList {
        bucket.key,
        rawColumnValue(bucket, Address),
        rawColumnValue(bucket, Port),
        rawColumnValue(bucket, ProtocolName),
        rawColumnValue(bucket, Client),
        rawColumnValue(bucket, Domain),
    }.join(QLatin1Char(' ')).toLower();
    for (const QString &term : terms) {
        if (!searchable.contains(term.toLower()))
            return false;
    }
    return true;
}

void EndpointStatisticsModel::sortRows(QVector<Bucket> &rows) const
{
    const int column = m_sortColumn[m_group];
    const bool ascending = m_sortAscending[m_group];
    QCollator collator = QCollator(QLocale());
    collator.setNumericMode(true);
    collator.setCaseSensitivity(Qt::CaseInsensitive);
    std::sort(rows.begin(), rows.end(),
        [column, ascending, &collator](const Bucket &lhs, const Bucket &rhs) {
            const int compared = compareColumn(lhs, rhs, column, collator);
            if (compared == 0)
                return collator.compare(lhs.key, rhs.key) < 0;
            return ascending ? compared < 0 : compared > 0;
        });
}

QString EndpointStatisticsModel::rawColumnValue(const Bucket &bucket, int column)
{
    switch (column) {
    case Address:
        return bucket.identityAddress.isEmpty()
            ? bucket.addresses.displayValue(nullptr) : bucket.identityAddress;
    case Port:
        return bucket.identityPort.isEmpty()
            ? bucket.ports.displayValue(nullptr) : bucket.identityPort;
    case ProtocolName:
        return bucket.protocols.displayValue(nullptr);
    case Client:
        return bucket.clients.displayValue(nullptr);
    case Domain:
        return bucket.domains.displayValue(nullptr);
    case Packets:
        return QString::number(bucket.totals.packets);
    case Bytes:
        return QString::number(bucket.totals.bytes);
    case TxPackets:
        return QString::number(bucket.totals.txPackets);
    case TxBytes:
        return QString::number(bucket.totals.txBytes);
    case RxPackets:
        return QString::number(bucket.totals.rxPackets);
    case RxBytes:
        return QString::number(bucket.totals.rxBytes);
    case Summary:
        return bucket.totals.summaryText();
    default:
        return QString();
    }
}

bool EndpointStatisticsModel::isAggregateColumn(const Bucket &bucket, int column)
{
    switch (column) {
    case Address:
        return bucket.identityAddress.isEmpty() && !bucket.addresses.empty()
            && bucket.addresses.counts.size() > 1;
    case Port:
        return bucket.identityPort.isEmpty() && bucket.ports.counts.size() > 1;
    case ProtocolName:
        return bucket.protocols.counts.size() > 1;
    case Client:
        return bucket.clients.counts.size() > 1;
    case Domain:
        return bucket.domains.counts.size() > 1;
    default:
        return false;
    }
}

int EndpointStatisticsModel::compareColumn(const Bucket &lhs, const Bucket &rhs, int column,
                                           const QCollator &collator)
{
    // Totals always exist, so numeric columns never hit the nil branch.
    switch (column) {
    case Packets: return compareQuantified(lhs.totals.packets, rhs.totals.packets);
    case Bytes: return compareQuantified(lhs.totals.bytes, rhs.totals.bytes);
    case TxPackets: return compareQuantified(lhs.totals.txPackets, rhs.totals.txPackets);
    case TxBytes: return compareQuantified(lhs.totals.txBytes, rhs.totals.txBytes);
    case RxPackets: return compareQuantified(lhs.totals.rxPackets, rhs.totals.rxPackets);
    case RxBytes: return compareQuantified(lhs.totals.rxBytes, rhs.totals.rxBytes);
    case Summary: {
        // Tx byte share (upstream compareSummary).
        const double lhsTotal = double(lhs.totals.txBytes) + double(lhs.totals.rxBytes)
            + double(lhs.totals.unclassifiedBytes);
        const double rhsTotal = double(rhs.totals.txBytes) + double(rhs.totals.rxBytes)
            + double(rhs.totals.unclassifiedBytes);
        const double lhsShare = lhsTotal == 0 ? 0 : double(lhs.totals.txBytes) / lhsTotal;
        const double rhsShare = rhsTotal == 0 ? 0 : double(rhs.totals.txBytes) / rhsTotal;
        return lhsShare < rhsShare ? -1 : (lhsShare > rhsShare ? 1 : 0);
    }
    case Port: {
        // Ports sort numerically when both parse (upstream UInt64 branch).
        bool lhsOk = false;
        bool rhsOk = false;
        const quint64 lhsPort = rawColumnValue(lhs, Port).toULongLong(&lhsOk);
        const quint64 rhsPort = rawColumnValue(rhs, Port).toULongLong(&rhsOk);
        if (lhsOk && rhsOk)
            return compareQuantified(qint64(lhsPort), qint64(rhsPort));
        [[fallthrough]];
    }
    default: {
        // Text columns: empty values sort last; the collator keeps the
        // Finder-like ordering of upstream localizedStandardCompare.
        const QString lhsValue = rawColumnValue(lhs, column);
        const QString rhsValue = rawColumnValue(rhs, column);
        if (lhsValue.isEmpty() || rhsValue.isEmpty()) {
            if (lhsValue.isEmpty() && !rhsValue.isEmpty())
                return 1;
            if (!lhsValue.isEmpty() && rhsValue.isEmpty())
                return -1;
            return 0;
        }
        return collator.compare(lhsValue, rhsValue) < 0 ? -1
            : (collator.compare(lhsValue, rhsValue) > 0 ? 1 : 0);
    }
    }
}

QString EndpointStatisticsModel::columnTitle(int column)
{
    return column >= 0 && column < kColumnCount
        ? QString::fromUtf8(kColumnTitles[column]) : QString();
}

QString EndpointStatisticsModel::columnJsonKey(int column)
{
    return column >= 0 && column < kColumnCount
        ? QString::fromUtf8(kColumnJsonKeys[column]) : QString();
}

bool EndpointStatisticsModel::columnDefaultVisible(int column, int group)
{
    if (group < 0 || group >= GroupCount)
        return true;
    if (column == Address)
        return group != Group::Apps && group != Group::Domains;
    if (column == Port)
        return group == Group::Tcp || group == Group::Udp;
    return true;
}

int EndpointStatisticsModel::columnDefaultWidth(int column)
{
    switch (column) {
    case Address: return 190;
    case Port: return 72;
    case ProtocolName: return 100;
    case Client: return 150;
    case Domain: return 190;
    case Packets: case Bytes: return 98;
    case TxPackets: case RxPackets: return 105;
    case TxBytes: case RxBytes: return 100;
    case Summary: return 190;
    default: return 100;
    }
}

QString EndpointStatisticsModel::keyAt(int row) const
{
    return row >= 0 && row < m_rows.size() ? m_rows.at(row).key : QString();
}

QVariantMap EndpointStatisticsModel::rawRow(const QString &key) const
{
    QVariantMap map;
    const auto it = m_buckets[m_group].constFind(key);
    if (it == m_buckets[m_group].constEnd())
        return map;
    const Bucket &bucket = it.value();
    QVariantList multiple;
    for (int column = 0; column < kColumnCount; ++column) {
        map.insert(QString::fromUtf8(kColumnJsonKeys[column]), rawColumnValue(bucket, column));
        multiple.append(isAggregateColumn(bucket, column));
    }
    map.insert(QStringLiteral("multiple"), multiple);
    map.insert(QStringLiteral("valid"), true);
    return map;
}

QString EndpointStatisticsModel::joinedValues(const QStringList &keys, int field) const
{
    const int column = field == 0 ? Address : (field == 1 ? Domain : Client);
    QStringList values;
    QSet<QString> seen;
    for (const QString &key : keys) {
        const auto it = m_buckets[m_group].constFind(key);
        if (it == m_buckets[m_group].constEnd())
            continue;
        const QString value = rawColumnValue(it.value(), column);
        if (value.isEmpty() || isAggregateColumn(it.value(), column) || seen.contains(value))
            continue;
        seen.insert(value);
        values << value;
    }
    return values.join(QLatin1Char('\n'));
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

// Visible-column exports (upstream EndpointStatisticsTableExportFormatter):
// CSV with formula-protected fields and CRLF rows, pretty JSON with the
// snake_case wire keys.
QString EndpointStatisticsModel::rowsAsCsv(const QStringList &keys, const QVariantList &columns) const
{
    const QVector<int> cols = validatedColumns(columns);
    if (cols.isEmpty())
        return QString();
    QStringList lines;
    QStringList header;
    for (const int column : cols)
        header << csvField(QString::fromUtf8(kColumnTitles[column]), false);
    lines << header.join(QLatin1Char(','));
    for (const QString &key : keys) {
        const auto it = m_buckets[m_group].constFind(key);
        if (it == m_buckets[m_group].constEnd())
            continue;
        QStringList fields;
        for (const int column : cols)
            fields << csvField(rawColumnValue(it.value(), column), !isNumericColumn(column));
        lines << fields.join(QLatin1Char(','));
    }
    return lines.join(QStringLiteral("\r\n"));
}

QString EndpointStatisticsModel::rowsAsJson(const QStringList &keys, const QVariantList &columns) const
{
    const QVector<int> cols = validatedColumns(columns);
    if (keys.isEmpty())
        return QStringLiteral("[]");
    QString result = QStringLiteral("[\n");
    bool firstRow = true;
    for (const QString &key : keys) {
        const auto it = m_buckets[m_group].constFind(key);
        if (it == m_buckets[m_group].constEnd())
            continue;
        if (!firstRow)
            result += QStringLiteral(",\n");
        firstRow = false;
        if (cols.isEmpty()) {
            result += QStringLiteral("  {}");
            continue;
        }
        result += QStringLiteral("  {\n");
        for (int index = 0; index < cols.size(); ++index) {
            if (index > 0)
                result += QStringLiteral(",\n");
            const int column = cols.at(index);
            result += QStringLiteral("    \"%1\": %2").arg(QString::fromUtf8(kColumnJsonKeys[column]),
                isNumericColumn(column) ? rawColumnValue(it.value(), column)
                                        : jsonString(rawColumnValue(it.value(), column)));
        }
        result += QStringLiteral("\n  }");
    }
    result += QStringLiteral("\n]");
    return result;
}

QVector<int> EndpointStatisticsModel::validatedColumns(const QVariantList &columns)
{
    QVector<int> cols;
    for (const QVariant &value : columns) {
        const int column = value.toInt();
        if (column >= 0 && column < kColumnCount)
            cols << column;
    }
    return cols;
}

// Scope for Show Related Packets: the closest sidebar node, or the All
// Packets scope plus an exact display filter for transport rows.
QVariantMap EndpointStatisticsModel::relatedScope(const QString &key) const
{
    QVariantMap scope;
    const auto it = m_buckets[m_group].constFind(key);
    if (it == m_buckets[m_group].constEnd())
        return scope;
    const Bucket &bucket = it.value();
    switch (m_group) {
    case Group::Apps:
        // The Apps key IS the sidebar's app key (stable client identity).
        scope.insert(QStringLiteral("nodeId"), QStringLiteral("app:") + key);
        break;
    case Group::Domains:
        scope.insert(QStringLiteral("nodeId"),
            QStringLiteral("domain:") + normalizedPacketDomain(key));
        break;
    case Group::Ipv4:
    case Group::Ipv6:
        scope.insert(QStringLiteral("nodeId"),
            QStringLiteral("ip:") + normalizedPacketIP(key));
        break;
    case Group::Tcp:
    case Group::Udp: {
        scope.insert(QStringLiteral("nodeId"), QStringLiteral("all"));
        bool portOk = false;
        const int port = bucket.identityPort.toInt(&portOk);
        const int addressGroup = groupIndexForCanonical(bucket.identityAddress);
        if (!portOk || port <= 0 || (addressGroup != Group::Ipv4 && addressGroup != Group::Ipv6))
            break;
        const QString ipField = addressGroup == Group::Ipv6
            ? QStringLiteral("ipv6.addr") : QStringLiteral("ip.addr");
        const QString transport = m_group == Group::Tcp
            ? QStringLiteral("tcp.port") : QStringLiteral("udp.port");
        scope.insert(QStringLiteral("filter"),
            QStringLiteral("%1 == %2 && %3 == %4").arg(ipField, bucket.identityAddress,
                transport, QString::number(port)));
        break;
    }
    default:
        break;
    }
    return scope;
}
