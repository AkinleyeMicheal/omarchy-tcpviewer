#pragma once

#include <QAbstractListModel>
#include <QVariantList>
#include <QtQml/qqmlregistration.h>

#include <memory>

// Flattened Wireshark protocol tree: expansion is managed here so the QML view
// is a plain virtualized ListView (upstream uses an NSOutlineView).
class PacketDetailModel : public QAbstractListModel
{
    Q_OBJECT
    QML_ELEMENT

public:
    enum Roles {
        NameRole = Qt::UserRole + 1,
        ValueRole,
        KindRole,
        SeverityRole,
        FieldRole,
        FilterRole,
        ByteOffsetRole,
        ByteLengthRole,
        DepthRole,
        HasChildrenRole,
        ExpandedRole,
    };

    explicit PacketDetailModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    void setNodes(const QVariantList &nodes);
    void clear();

    Q_INVOKABLE void toggleExpanded(int row);
    Q_INVOKABLE void setFilterText(const QString &text);
    Q_INVOKABLE int byteOffsetAt(int row) const;
    Q_INVOKABLE int byteLengthAt(int row) const;

private:
    struct Node {
        QString name;
        QString value;
        QString kind;
        QString severity;
        QString fieldName;
        QString filter;
        int byteOffset = -1;
        int byteLength = 0;
        bool expanded = false;
        QVector<std::shared_ptr<Node>> children;
    };

    struct VisibleRow {
        const Node *node = nullptr;
        int depth = 0;
    };

    static std::shared_ptr<Node> parseNode(const QVariantMap &map, int depth = 0);
    static bool nodeMatches(const Node &node, const QString &needle);
    static bool subtreeMatches(const Node &node, const QString &needle);
    void appendVisible(const Node &node, int depth, const QString &needle);
    void rebuildVisible();
    const Node *visibleNode(int row) const;

    QVector<std::shared_ptr<Node>> m_roots;
    QVector<VisibleRow> m_visible;
    QString m_filter;
};
