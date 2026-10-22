// Endpoint statistics (upstream EndpointStatisticsService + Models): six
// group buckets (Apps, Domains, IPv4, IPv6, TCP, UDP) with directional
// totals, related-value "Multiple" handling, busiest-first sort, and a
// footer over the current group.
#ifndef ENDPOINTSTATSMODEL_H
#define ENDPOINTSTATSMODEL_H

#include <QAbstractTableModel>
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
    };
    Q_ENUM(Role)

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

    // Rebuilds all six groups from the packet table's rows.
    Q_INVOKABLE void rebuild(QObject *packets);

signals:
    void groupChanged();
    void footerChanged();

private:
    struct PacketFacts {
        qint64 bytes = 0;
        QString direction; // outbound/inbound/local/unknown
        QString protocolName;
        QString client;
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
    static Totals directionalTotals(qint64 bytes, const QString &direction, bool reversed);
    static Totals endpointTotals(qint64 bytes, bool source, bool destination);
    static QString transportKey(const Endpoint &endpoint);
    void refreshFooter();

    QHash<QString, Bucket> m_buckets[GroupCount];
    QVector<Bucket> m_rows; // materialized, busiest-first, for the active group
    Totals m_footerTotals;  // whole-capture totals
    Totals m_scopeTotals;   // active-group totals
    int m_group = Group::Ipv4;
    QString m_footerText;
};

#endif // ENDPOINTSTATSMODEL_H
