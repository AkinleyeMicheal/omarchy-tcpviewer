#include "sourcetreemodel.h"

#include <algorithm>
#include <utility>

namespace {

constexpr int maximumApps = 10'000;
constexpr int maximumDomains = 50'000;
constexpr int maximumIPs = 50'000;
constexpr int maximumChildrenPerApp = 5'000;
// The QML tree is a flat list, unlike upstream's lazy NSOutlineView. Cap the
// expanded rows so a hostile capture cannot force millions of delegate rows.
constexpr int maximumFlatNodes = 200'000;

QString domainTitle(const QString &key)
{
    return key.isEmpty() ? QStringLiteral("IP Addresses") : key;
}

} // namespace

SourceTreeModel::SourceTreeModel(QObject *parent)
    : QAbstractListModel(parent)
{
    m_rebuildTimer.setSingleShot(true);
    m_rebuildTimer.setInterval(200);
    connect(&m_rebuildTimer, &QTimer::timeout, this, &SourceTreeModel::rebuildNow);
    reset();
}

int SourceTreeModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : m_nodes.size();
}

QVariant SourceTreeModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_nodes.size())
        return {};

    const Node &node = m_nodes.at(index.row());
    switch (role) {
    case NodeIdRole:
        return node.id;
    case ParentIdRole:
        return node.parentId;
    case TitleRole:
        return node.title;
    case CountRole:
        return node.count;
    case KindRole:
        return node.kind;
    case DepthRole:
        return node.depth;
    case ExpandedRole:
        return node.expanded;
    case HasChildrenRole:
        return node.hasChildren;
    case SelectedRole:
        return node.id == m_selectedNodeId;
    case AppKeyRole:
        return node.appKey;
    case DomainKeyRole:
        return node.domainKey;
    case MissingDomainRole:
        return node.missingDomain;
    case IpRole:
        return node.ip;
    default:
        return {};
    }
}

QHash<int, QByteArray> SourceTreeModel::roleNames() const
{
    return {
        {NodeIdRole, "nodeId"},
        {ParentIdRole, "parentId"},
        {TitleRole, "title"},
        {CountRole, "count"},
        {KindRole, "kind"},
        {DepthRole, "depth"},
        {ExpandedRole, "expanded"},
        {HasChildrenRole, "hasChildren"},
        {SelectedRole, "selected"},
        {AppKeyRole, "appKey"},
        {DomainKeyRole, "domainKey"},
        {MissingDomainRole, "missingDomain"},
        {IpRole, "ip"},
    };
}

void SourceTreeModel::reset()
{
    m_rebuildTimer.stop();

    beginResetModel();
    m_nodes.clear();
    m_nodeIndexById.clear();
    m_apps.clear();
    m_appOrder.clear();
    m_domainCounts.clear();
    m_domainOrder.clear();
    m_ipCounts.clear();
    m_ipOrder.clear();
    m_totalPackets = 0;
    m_packetsWithClient = 0;
    m_packetsWithoutDomain = 0;
    m_expanded.clear();
    m_expanded.insert(QStringLiteral("folder:apps"));
    m_expanded.insert(QStringLiteral("folder:domains"));
    m_selectedNodeId = QStringLiteral("all");
    endResetModel();

    // Keep the All scope selectable even before the first packet arrives.
    rebuildNow();
    emit countChanged();
    emit selectedNodeIdChanged();
}

void SourceTreeModel::appendRows(const QVector<PacketRow> &rows)
{
    if (rows.isEmpty())
        return;

    for (const PacketRow &row : rows) {
        const QString domain = normalizedDomain(row.domain);
        ++m_totalPackets;
        addDomain(domain);

        if (domain.isEmpty())
            ++m_packetsWithoutDomain;

        if (!row.clientKey.trimmed().isEmpty()) {
            ++m_packetsWithClient;
            addApp(row, domain);
        }

        if (domain.isEmpty()) {
            const QString source = normalizedIP(row.source);
            const QString destination = normalizedIP(row.destination);
            addIP(m_ipCounts, m_ipOrder, source, maximumIPs);
            if (destination != source)
                addIP(m_ipCounts, m_ipOrder, destination, maximumIPs);
        }
    }

    if (!m_rebuildTimer.isActive())
        m_rebuildTimer.start();
}

void SourceTreeModel::addDomain(const QString &domain)
{
    incrementCount(m_domainCounts, m_domainOrder, domain, maximumDomains);
}

void SourceTreeModel::addApp(const PacketRow &row, const QString &domain)
{
    const QString key = row.clientKey.trimmed();
    auto it = m_apps.find(key);
    if (it == m_apps.end()) {
        if (m_appOrder.size() >= maximumApps)
            return;
        AppBucket bucket;
        bucket.title = appTitle(row);
        m_apps.insert(key, bucket);
        m_appOrder.append(key);
        it = m_apps.find(key);
    }

    AppBucket &app = it.value();
    ++app.count;
    incrementCount(app.domainCounts, app.domainOrder, domain, maximumChildrenPerApp);

    if (domain.isEmpty()) {
        const QString source = normalizedIP(row.source);
        const QString destination = normalizedIP(row.destination);
        addIP(app.ipCounts, app.ipOrder, source, maximumChildrenPerApp);
        if (destination != source)
            addIP(app.ipCounts, app.ipOrder, destination, maximumChildrenPerApp);
    }
}

void SourceTreeModel::addIP(QHash<QString, int> &counts, QStringList &order,
                            const QString &address, int maximum)
{
    if (address.isEmpty())
        return;
    incrementCount(counts, order, address, maximum);
}

bool SourceTreeModel::incrementCount(QHash<QString, int> &counts, QStringList &order,
                                     const QString &key, int maximum)
{
    auto it = counts.find(key);
    if (it != counts.end()) {
        ++it.value();
        return true;
    }
    // The empty key is the IP Addresses pseudo-domain and must never be capped.
    if (!key.isEmpty() && order.size() >= maximum)
        return false;
    counts.insert(key, 1);
    order.append(key);
    return true;
}

QString SourceTreeModel::normalizedDomain(const QString &value)
{
    return normalizedPacketDomain(value);
}

QString SourceTreeModel::normalizedIP(const QString &value)
{
    return normalizedPacketIP(value);
}

QString SourceTreeModel::appTitle(const PacketRow &row)
{
    QString title = row.client.trimmed();
    if (title.isEmpty())
        title = row.clientKey.trimmed();
    return title.left(128);
}

void SourceTreeModel::setFilterText(const QString &text)
{
    const QString trimmed = text.trimmed();
    if (trimmed == m_filterText)
        return;

    m_filterText = trimmed;
    emit filterTextChanged();
    rebuildNow();
}

void SourceTreeModel::filterNodes(QVector<Node> &nodes) const
{
    if (m_filterText.isEmpty())
        return;

    // Match on text/ids; keep matched nodes and all ancestors so matching
    // subtrees stay navigable.
    QHash<QString, bool> includeFromDescendants;
    QVector<bool> matchNode(nodes.size(), false);
    for (int i = 0; i < nodes.size(); ++i) {
        const Node &node = nodes.at(i);
        matchNode[i] = node.id == QStringLiteral("all")
            || node.title.contains(m_filterText, Qt::CaseInsensitive)
            || node.id.contains(m_filterText, Qt::CaseInsensitive)
            || node.ip.contains(m_filterText, Qt::CaseInsensitive)
            || node.appKey.contains(m_filterText, Qt::CaseInsensitive);
    }

    // Mark nodes to keep: keep if the node itself matches, or if any
    // descendant below it is kept.
    for (int i = nodes.size() - 1; i >= 0; --i) {
        const Node &node = nodes.at(i);
        const bool includeNode = matchNode.at(i)
            || includeFromDescendants.value(node.id, false);
        includeFromDescendants.insert(node.id, includeNode);
        if (!node.parentId.isEmpty()) {
            const bool includeParent = includeFromDescendants.value(node.parentId, false);
            includeFromDescendants.insert(node.parentId, includeNode || includeParent);
        }
    }

    QVector<Node> filtered;
    filtered.reserve(nodes.size());
    for (int i = 0; i < nodes.size(); ++i) {
        if (includeFromDescendants.value(nodes.at(i).id, matchNode.at(i)))
            filtered.append(nodes.at(i));
    }
    nodes = std::move(filtered);
}

void SourceTreeModel::rebuildNow()
{
    m_rebuildTimer.stop();

    const bool filterActive = !m_filterText.isEmpty();

    QVector<Node> nodes;
    nodes.reserve(m_apps.size() + m_domainCounts.size() + m_ipCounts.size() + 4);
    const auto appendNode = [&nodes](Node node) {
        if (nodes.size() < maximumFlatNodes)
            nodes.append(std::move(node));
    };

    Node all;
    all.id = QStringLiteral("all");
    all.title = QStringLiteral("All Packets");
    all.kind = QStringLiteral("all");
    all.count = m_totalPackets;
    appendNode(all);

    if (m_packetsWithClient > 0 && !m_apps.isEmpty()) {
        const QString appsId = QStringLiteral("folder:apps");
        Node apps;
        apps.id = appsId;
        apps.title = QStringLiteral("Apps");
        apps.kind = QStringLiteral("group");
        apps.count = m_packetsWithClient;
        apps.hasChildren = true;
        apps.expanded = filterActive || m_expanded.contains(appsId);
        appendNode(apps);

        // Insertion order matches upstream's orderedAppBuckets and keeps live
        // count updates from reshuffling rows under the pointer.
        for (const QString &appKey : m_appOrder) {
            const auto appIt = m_apps.constFind(appKey);
            if (appIt == m_apps.constEnd())
                continue;
            const AppBucket &app = appIt.value();
            const QString appId = QStringLiteral("app:") + appKey;
            Node appNode;
            appNode.id = appId;
            appNode.parentId = appsId;
            appNode.title = app.title;
            appNode.kind = QStringLiteral("app");
            appNode.appKey = appKey;
            appNode.count = app.count;
            appNode.depth = 1;
            appNode.hasChildren = !app.domainCounts.isEmpty();
            appNode.expanded = filterActive || m_expanded.contains(appId);
            appendNode(appNode);

            if (!appNode.expanded)
                continue;

            for (const QString &domainKey : app.domainOrder) {
                const QString domainId = QStringLiteral("app-domain:") + appKey
                    + QLatin1Char(':') + domainKey;
                Node domainNode;
                domainNode.id = domainId;
                domainNode.parentId = appId;
                domainNode.title = domainTitle(domainKey);
                domainNode.kind = QStringLiteral("domain");
                domainNode.appKey = appKey;
                domainNode.domainKey = domainKey;
                domainNode.missingDomain = domainKey.isEmpty();
                domainNode.count = app.domainCounts.value(domainKey);
                domainNode.depth = 2;
                domainNode.hasChildren = domainNode.missingDomain && !app.ipCounts.isEmpty();
                domainNode.expanded = filterActive || m_expanded.contains(domainId);
                appendNode(domainNode);

                if (!domainNode.expanded || !domainNode.hasChildren)
                    continue;

                for (const QString &ip : app.ipOrder) {
                    Node ipNode;
                    ipNode.id = QStringLiteral("app-ip:") + appKey + QLatin1Char(':') + ip;
                    ipNode.parentId = domainId;
                    ipNode.title = ip;
                    ipNode.kind = QStringLiteral("ip");
                    ipNode.appKey = appKey;
                    ipNode.ip = ip;
                    ipNode.missingDomain = true;
                    ipNode.count = app.ipCounts.value(ip);
                    ipNode.depth = 3;
                    appendNode(ipNode);
                }
            }
        }
    }

    if (m_totalPackets > 0) {
        const QString domainsId = QStringLiteral("folder:domains");
        Node domains;
        domains.id = domainsId;
        domains.title = QStringLiteral("Domains");
        domains.kind = QStringLiteral("group");
        domains.count = m_totalPackets;
        domains.hasChildren = !m_domainCounts.isEmpty();
        domains.expanded = filterActive || m_expanded.contains(domainsId);
        appendNode(domains);

        if (domains.expanded) {
            for (const QString &domainKey : m_domainOrder) {
                const QString domainId = QStringLiteral("domain:") + domainKey;
                Node domainNode;
                domainNode.id = domainId;
                domainNode.parentId = domainsId;
                domainNode.title = domainTitle(domainKey);
                domainNode.kind = QStringLiteral("domain");
                domainNode.domainKey = domainKey;
                domainNode.missingDomain = domainKey.isEmpty();
                domainNode.count = m_domainCounts.value(domainKey);
                domainNode.depth = 1;
                domainNode.hasChildren = domainNode.missingDomain && !m_ipCounts.isEmpty();
                domainNode.expanded = filterActive || m_expanded.contains(domainId);
                appendNode(domainNode);

                if (!domainNode.expanded || !domainNode.hasChildren)
                    continue;

                for (const QString &ip : m_ipOrder) {
                    Node ipNode;
                    ipNode.id = QStringLiteral("ip:") + ip;
                    ipNode.parentId = domainId;
                    ipNode.title = ip;
                    ipNode.kind = QStringLiteral("ip");
                    ipNode.ip = ip;
                    ipNode.missingDomain = true;
                    ipNode.count = m_ipCounts.value(ip);
                    ipNode.depth = 2;
                    appendNode(ipNode);
                }
            }
        }
    }

    filterNodes(nodes);

    bool sameStructure = nodes.size() == m_nodes.size();
    if (sameStructure) {
        for (int i = 0; i < nodes.size(); ++i) {
            if (nodes.at(i).id != m_nodes.at(i).id) {
                sameStructure = false;
                break;
            }
        }
    }
    const bool nodeCountChanged = nodes.size() != m_nodes.size();

    if (sameStructure) {
        // Count-only refresh: keep the ListView scroll position and selection.
        m_nodes = std::move(nodes);
        m_nodeIndexById.clear();
        m_nodeIndexById.reserve(m_nodes.size());
        for (int i = 0; i < m_nodes.size(); ++i)
            m_nodeIndexById.insert(m_nodes.at(i).id, i);
        if (!m_nodes.isEmpty())
            emit dataChanged(index(0), index(m_nodes.size() - 1));
    } else {
        beginResetModel();
        m_nodes = std::move(nodes);
        m_nodeIndexById.clear();
        m_nodeIndexById.reserve(m_nodes.size());
        for (int i = 0; i < m_nodes.size(); ++i)
            m_nodeIndexById.insert(m_nodes.at(i).id, i);
        endResetModel();
    }

    if (nodeCountChanged)
        emit countChanged();
}

void SourceTreeModel::selectNode(const QString &nodeId)
{
    if (nodeId.isEmpty() || !m_nodeIndexById.contains(nodeId))
        return;
    if (m_selectedNodeId == nodeId)
        return;

    m_selectedNodeId = nodeId;
    rebuildNow();
    emit selectedNodeIdChanged();
}

void SourceTreeModel::toggleExpanded(const QString &nodeId)
{
    const int index = m_nodeIndexById.value(nodeId, -1);
    if (index < 0 || !m_nodes.at(index).hasChildren)
        return;

    if (m_expanded.contains(nodeId))
        m_expanded.remove(nodeId);
    else
        m_expanded.insert(nodeId);
    rebuildNow();
}

PacketTreeFilter SourceTreeModel::filterForNode(const QString &nodeId) const
{
    const int index = m_nodeIndexById.value(nodeId, -1);
    if (index < 0)
        return {};

    const Node &node = m_nodes.at(index);
    PacketTreeFilter filter;
    filter.valid = true;

    if (node.kind == QStringLiteral("group")) {
        if (node.id == QStringLiteral("folder:apps")) {
            filter.appsOnly = true;
            filter.active = true;
        }
        return filter;
    }

    if (node.kind == QStringLiteral("app")) {
        filter.appKey = node.appKey;
    } else if (node.kind == QStringLiteral("domain")) {
        filter.appKey = node.appKey;
        filter.domainKey = node.domainKey;
        filter.missingDomain = node.missingDomain;
    } else if (node.kind == QStringLiteral("ip")) {
        filter.appKey = node.appKey;
        filter.ip = node.ip;
        filter.missingDomain = true;
    }

    filter.active = !filter.appKey.isEmpty() || !filter.domainKey.isEmpty()
        || filter.missingDomain || !filter.ip.isEmpty();
    return filter;
}
