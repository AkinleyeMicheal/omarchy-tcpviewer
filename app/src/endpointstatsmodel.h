// Endpoint statistics (upstream EndpointStatisticsService + Models): six
// group buckets (Apps, Domains, IPv4, IPv6, TCP, UDP) with directional
// totals, related-value "Multiple" handling, busiest-first sort, and a
// footer over the current group.
#ifndef ENDPOINTSTATSMODEL_H
#define ENDPOINTSTATSMODEL_H

#include <QAbstractTableModel>
#include <QCollator>
#include <QStringList>
#include <QtQml/qqmlregistration.h>

class PacketListModel;

class EndpointStatisticsModel : public QAbstractTableModel
{
    Q_OBJECT
    QML_ELEMENT
    // Forward-declared PacketListModel rows feed rebuilds.
    Q_PROPERTY(int group READ group WRITE setGroup NOTIFY groupChanged)
    Q_PROPERTY(QString footerText READ footerText NOTIFY footerChanged)
    Q_PROPERTY(QVariantList groupCounts READ groupCounts NOTIFY footerChanged)
    Q_PROPERTY(int count READ count NOTIFY footerChanged)
    // Search (upstream EndpointStatisticsTablePresenter: whitespace-split
    // terms, ALL contained in the joined identity fields) and the active
    // group's sort state (per group, default busiest-first = Bytes desc).
    Q_PROPERTY(QString searchText READ searchText WRITE setSearchText NOTIFY searchChanged)
    Q_PROPERTY(int sortColumn READ sortColumn NOTIFY sortChanged)
    Q_PROPERTY(bool sortAscending READ sortAscending NOTIFY sortChanged)

public:
    // Six groups, upstream order (EndpointStatisticsGroup).
    enum Group {
        Apps = 0,
        Domains,
        Ipv4,
        Ipv6,
        Tcp,
        Udp,
        GroupCount,
    };

    enum Role {
        AddressRole = Qt::UserRole + 1,
        PortRole,
        ProtocolRole,
        ClientRole,
        DomainRole,
        PacketsRole,
        BytesRole,
        TxPacketsRole,
        TxBytesRole,
        RxPacketsRole,
        RxBytesRole,
        SummaryRole,
        IsMultipleRole,
        CountRole,
        KeyRole,
    };
    Q_ENUM(Role)

    // Columns share the wire order with upstream EndpointStatisticsTableColumn.
    enum Column {
        Address = 0,
        Port,
        ProtocolName,
        Client,
        Domain,
        Packets,
        Bytes,
        TxPackets,
        TxBytes,
        RxPackets,
        RxBytes,
        Summary,
    };

    struct Endpoint {
        QString address;
        QString port;
        bool canonical = false; // dotted-quad or IPv6 text
    };

    struct Totals {
        qint64 packets = 0;
        qint64 bytes = 0;
        qint64 txPackets = 0;
        qint64 txBytes = 0;
        qint64 rxPackets = 0;
        qint64 rxBytes = 0;
        qint64 unclassifiedPackets = 0;
        qint64 unclassifiedBytes = 0;

        void add(const Totals &other);
        // "Tx 62% · Rx 38%" (EndpointStatisticsTotals.summary).
        QString summaryText() const;
    };

    // Value-count tracker showing "Multiple" past one distinct value.
    struct ValueCounts {
        QHash<QString, qint64> counts;

        void add(const QStringList &values);
        void remove(const QStringList &values);
        QString displayValue(bool *isMultiple) const;
        bool empty() const { return counts.isEmpty(); }
    };

    struct Bucket {
        QString key;
        QString identityAddress;
        QString identityPort; // set only for transport groups
        Totals totals;
        ValueCounts addresses;
        ValueCounts ports;
        ValueCounts protocols;
        ValueCounts clients;
        ValueCounts domains;
    };

    explicit EndpointStatisticsModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = {}) const override;
    int columnCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    int group() const { return m_group; }
    void setGroup(int group);
    QString footerText() const { return m_footerText; }
    int count() const { return m_rows.size(); }
    QVariantList groupCounts() const;

    QString searchText() const { return m_searchText; }
    void setSearchText(const QString &text);
    int sortColumn() const { return m_sortColumn[m_group]; }
    bool sortAscending() const { return m_sortAscending[m_group]; }

    // Rebuilds all six groups from the packet table's rows.
    Q_INVOKABLE void rebuild(QObject *packets);

    // Row identity for selection tracking that survives the 2 s live rebuild
    // (upstream keys selections by EndpointStatisticsRow.ID, not row index).
    Q_INVOKABLE QString keyAt(int row) const;
    // Raw (unformatted) cell values + per-column "Multiple" flags for copy.
    Q_INVOKABLE QVariantMap rawRow(const QString &key) const;
    // Visible-column exports (upstream EndpointStatisticsTableExportFormatter).
    Q_INVOKABLE QString rowsAsCsv(const QStringList &keys, const QVariantList &columns) const;
    Q_INVOKABLE QString rowsAsJson(const QStringList &keys, const QVariantList &columns) const;
    // Unique non-placeholder values of one semantic field (0 address,
    // 1 domain, 2 client) joined for the menu's Copy Address/Domain/App.
    Q_INVOKABLE QString joinedValues(const QStringList &keys, int field) const;
    // Scope for Show Related Packets: a sidebar node id, or a display filter
    // for transport rows (upstream picks the closest sidebar scope and keeps
    // the exact endpoint match in the packet table).
    Q_INVOKABLE QVariantMap relatedScope(const QString &key) const;
    // Header click: same column toggles direction, a new column starts with
    // the AppKit prototype (numeric descending, text ascending).
    Q_INVOKABLE void clickSort(int column);
    // Column catalog so QML and the exporters share titles/defaults.
    Q_INVOKABLE static QString columnTitle(int column);
    Q_INVOKABLE static QString columnJsonKey(int column);
    Q_INVOKABLE static bool columnDefaultVisible(int column, int group);
    Q_INVOKABLE static int columnDefaultWidth(int column);

    static QVector<int> validatedColumns(const QVariantList &columns);

signals:
    void groupChanged();
    void footerChanged();
    void searchChanged();
    void sortChanged();

private:
    struct PacketFacts {
        qint64 bytes = 0;
        QString direction; // outbound/inbound/local/unknown
        QString protocolName;
        QString client;
        // Stable app identity (executable path) matching the sidebar keys.
        QString clientKey;
        QString domain;
        Endpoint source;
        Endpoint destination;
    };

    void applyContribution(int group, const QString &key, const QString &address,
                           const QString &identityPort, const Totals &totals,
                           const QStringList &addresses, const QStringList &ports,
                           const QStringList &protocols, const QStringList &clients,
                           const QStringList &domains);
    struct Contribution { // internal shortcut type
        int group;
        QString key;
        QString address;
        QString identityPort;
        Totals totals;
        QStringList addresses;
        QStringList ports;
        QStringList protocols;
        QStringList clients;
        QStringList domains;
    };
    void commit(const Contribution &contribution);
    void refreshView();
    bool matchesSearch(const Bucket &bucket) const;
    void sortRows(QVector<Bucket> &rows) const;
    static Totals directionalTotals(qint64 bytes, const QString &direction, bool reversed);
    static Totals endpointTotals(qint64 bytes, bool source, bool destination);
    static QString transportKey(const Endpoint &endpoint);
    // Raw cell text for one column (collapsed "Multiple" for aggregates) and
    // its placeholder flag; the numeric totals expose plain decimal strings.
    static QString rawColumnValue(const Bucket &bucket, int column);
    static bool isAggregateColumn(const Bucket &bucket, int column);
    // Three-way compare of one column (numeric, port, summary share, or
    // collated text with empty-last); 0 when equal.
    static int compareColumn(const Bucket &lhs, const Bucket &rhs, int column,
                             const QCollator &collator);
    void refreshFooter();

    QHash<QString, Bucket> m_buckets[GroupCount];
    QVector<Bucket> m_rows; // filtered + sorted, for the active group
    Totals m_footerTotals;  // whole-capture totals
    Totals m_scopeTotals;   // active-group totals
    int m_group = Group::Ipv4;
    QString m_footerText;
    QString m_searchText;
    // Per-group sort state; defaults model the busiest-first order.
    int m_sortColumn[GroupCount] = {Bytes, Bytes, Bytes, Bytes, Bytes, Bytes};
    bool m_sortAscending[GroupCount] = {false, false, false, false, false, false};
};

#endif // ENDPOINTSTATSMODEL_H
