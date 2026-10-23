#pragma once

#include "packetmodel.h"

#include <QAbstractListModel>
#include <QHash>
#include <QSet>
#include <QStringList>
#include <QTimer>
#include <QtQml/qqmlregistration.h>

// Sidebar scope selected from the source tree. An invalid filter means the
// requested node no longer exists; an inactive one is the "All" scope.
struct PacketTreeFilter {
    bool valid = false;
    bool active = false;
    bool appsOnly = false;
    bool missingDomain = false;
    QString appKey;
    QString domainKey;
    QString ip;
};

// Upstream packet-source tree (PacketSourceListService): All -> Apps (app ->
// domains/IPs) and Domains (domain -> IPs for the IP Addresses pseudo-domain).
// Counts are over the packets currently loaded in the table.
class SourceTreeModel : public QAbstractListModel
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(int count READ count NOTIFY countChanged)
    Q_PROPERTY(QString selectedNodeId READ selectedNodeId NOTIFY selectedNodeIdChanged)
    Q_PROPERTY(QString filterText READ filterText WRITE setFilterText NOTIFY filterTextChanged)

public:
    enum Role {
        NodeIdRole = Qt::UserRole + 1,
        ParentIdRole,
        TitleRole,
        CountRole,
        KindRole,
        DepthRole,
        ExpandedRole,
        HasChildrenRole,
        SelectedRole,
        AppKeyRole,
        DomainKeyRole,
        MissingDomainRole,
        IpRole,
    };
    Q_ENUM(Role)

    explicit SourceTreeModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    void reset();
    void appendRows(const QVector<PacketRow> &rows);
    void rebuildNow();

    Q_INVOKABLE void selectNode(const QString &nodeId);
    Q_INVOKABLE void toggleExpanded(const QString &nodeId);
    PacketTreeFilter filterForNode(const QString &nodeId) const;

    int count() const { return m_nodes.size(); }
    QString selectedNodeId() const { return m_selectedNodeId; }
    QString filterText() const { return m_filterText; }
    void setFilterText(const QString &text);

signals:
    void countChanged();
    void selectedNodeIdChanged();
    void filterTextChanged();

private:
    struct Node {
        QString id;
        QString parentId;
        QString title;
        QString kind;
        QString appKey;
        QString domainKey;
        QString ip;
        int count = 0;
        int depth = 0;
        bool hasChildren = false;
        bool expanded = false;
        bool missingDomain = false;
    };

    struct AppBucket {
        QString title;
        int count = 0;
        QHash<QString, int> domainCounts;
        QStringList domainOrder;
        QHash<QString, int> ipCounts;
        QStringList ipOrder;
    };

    void addApp(const PacketRow &row, const QString &domain);
    void addDomain(const QString &domain);
    void addIP(QHash<QString, int> &counts, QStringList &order,
               const QString &address, int maximum);
    static bool incrementCount(QHash<QString, int> &counts, QStringList &order,
                               const QString &key, int maximum);
    static QString normalizedDomain(const QString &value);
    static QString normalizedIP(const QString &value);
    static QString appTitle(const PacketRow &row);

    QVector<Node> m_nodes;
    QHash<QString, int> m_nodeIndexById;
    QSet<QString> m_expanded;
    QString m_selectedNodeId = QStringLiteral("all");
    QTimer m_rebuildTimer;

    QHash<QString, AppBucket> m_apps;
    QStringList m_appOrder;
    QHash<QString, int> m_domainCounts;
    QStringList m_domainOrder;
    QHash<QString, int> m_ipCounts;
    QStringList m_ipOrder;

    int m_totalPackets = 0;
    int m_packetsWithClient = 0;
    int m_packetsWithoutDomain = 0;
    QString m_filterText;

    void filterNodes(QVector<Node> &nodes) const;
};
