#include "packetdetailmodel.h"

#include <QVariantMap>

PacketDetailModel::PacketDetailModel(QObject *parent)
    : QAbstractListModel(parent)
{
}

int PacketDetailModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : m_visible.size();
}

QVariant PacketDetailModel::data(const QModelIndex &index, int role) const
{
    const Node *node = visibleNode(index.row());
    if (!node)
        return {};

    switch (role) {
    case NameRole: return node->name;
    case ValueRole: return node->value;
    case KindRole: return node->kind;
    case SeverityRole: return node->severity;
    case FieldRole: return node->fieldName;
    case FilterRole: return node->filter;
    case ByteOffsetRole: return node->byteOffset;
    case ByteLengthRole: return node->byteLength;
    case DepthRole: return m_visible.at(index.row()).depth;
    case HasChildrenRole: return !node->children.isEmpty();
    case ExpandedRole: return node->expanded;
    default: return {};
    }
}

QHash<int, QByteArray> PacketDetailModel::roleNames() const
{
    return {
        {NameRole, "name"},
        {ValueRole, "value"},
        {KindRole, "kind"},
        {SeverityRole, "severity"},
        {FieldRole, "field"},
        {FilterRole, "filter"},
        {ByteOffsetRole, "byteOffset"},
        {ByteLengthRole, "byteLength"},
        {DepthRole, "depth"},
        {HasChildrenRole, "hasChildren"},
        {ExpandedRole, "expanded"},
    };
}

void PacketDetailModel::setNodes(const QVariantList &nodes)
{
    m_roots.clear();
    m_roots.reserve(nodes.size());
    for (const QVariant &entry : nodes) {
        auto node = parseNode(entry.toMap());
        if (node) {
            // Upstream expands root protocol groups only (ExpansionState level == 0).
            node->expanded = !node->children.isEmpty();
            m_roots.append(std::move(node));
        }
    }
    rebuildVisible();
}

void PacketDetailModel::clear()
{
    m_roots.clear();
    rebuildVisible();
}

void PacketDetailModel::toggleExpanded(int row)
{
    if (row < 0 || row >= m_visible.size())
        return;
    const Node *constNode = m_visible.at(row).node;
    // Node ownership is shared and stable, so rebuilding the flattened view is safe.
    auto *node = const_cast<Node *>(constNode);
    if (node->children.isEmpty())
        return;
    node->expanded = !node->expanded;
    rebuildVisible();
}

void PacketDetailModel::setFilterText(const QString &text)
{
    const QString trimmed = text.trimmed();
    if (trimmed == m_filter)
        return;
    m_filter = trimmed;
    rebuildVisible();
}

int PacketDetailModel::byteOffsetAt(int row) const
{
    const Node *node = visibleNode(row);
    return node ? node->byteOffset : -1;
}

int PacketDetailModel::byteLengthAt(int row) const
{
    const Node *node = visibleNode(row);
    return node ? node->byteLength : 0;
}

QString PacketDetailModel::fieldNameAt(int row) const
{
    const Node *node = visibleNode(row);
    return node ? node->fieldName : QString();
}

QString PacketDetailModel::valueAt(int row) const
{
    const Node *node = visibleNode(row);
    return node ? node->value : QString();
}

std::shared_ptr<PacketDetailModel::Node> PacketDetailModel::parseNode(const QVariantMap &map, int depth)
{
    // Bound recursion: the daemon clamps depth to 12, so anything deeper is
    // malformed/hostile input and must not be able to exhaust the stack.
    static constexpr int kMaximumDepth = 64;
    if (depth > kMaximumDepth)
        return nullptr;

    auto node = std::make_shared<Node>();
    node->name = map.value(QStringLiteral("name")).toString();
    node->value = map.value(QStringLiteral("value")).toString();
    node->kind = map.value(QStringLiteral("kind")).toString();
    node->severity = map.value(QStringLiteral("severity")).toString();
    node->fieldName = map.value(QStringLiteral("field")).toString();
    node->filter = map.value(QStringLiteral("filter")).toString();

    const QVariantMap range = map.value(QStringLiteral("byte_range")).toMap();
    if (!range.isEmpty()) {
        node->byteOffset = range.value(QStringLiteral("offset"), -1).toInt();
        node->byteLength = range.value(QStringLiteral("length")).toInt();
    }

    const QVariantList children = map.value(QStringLiteral("children")).toList();
    node->children.reserve(children.size());
    for (const QVariant &child : children) {
        if (auto parsed = parseNode(child.toMap(), depth + 1))
            node->children.append(std::move(parsed));
    }
    return node;
}

bool PacketDetailModel::nodeMatches(const Node &node, const QString &needle)
{
    return node.name.contains(needle, Qt::CaseInsensitive)
        || node.value.contains(needle, Qt::CaseInsensitive)
        || node.fieldName.contains(needle, Qt::CaseInsensitive);
}

bool PacketDetailModel::subtreeMatches(const Node &node, const QString &needle)
{
    if (nodeMatches(node, needle))
        return true;
    for (const auto &child : node.children) {
        if (subtreeMatches(*child, needle))
            return true;
    }
    return false;
}

void PacketDetailModel::appendVisible(const Node &node, int depth, const QString &needle)
{
    if (!needle.isEmpty() && !subtreeMatches(node, needle))
        return;

    m_visible.append({&node, depth});
    if (node.children.isEmpty())
        return;

    const bool expand = node.expanded || (!needle.isEmpty() && subtreeMatches(node, needle));
    if (!expand)
        return;
    for (const auto &child : node.children)
        appendVisible(*child, depth + 1, needle);
}

void PacketDetailModel::rebuildVisible()
{
    beginResetModel();
    m_visible.clear();
    for (const auto &root : m_roots)
        appendVisible(*root, 0, m_filter);
    endResetModel();
}

const PacketDetailModel::Node *PacketDetailModel::visibleNode(int row) const
{
    if (row < 0 || row >= m_visible.size())
        return nullptr;
    return m_visible.at(row).node;
}
