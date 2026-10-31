#pragma once

#include <QAbstractTableModel>
#include <QString>
#include <QVector>
#include <QtQml/qqmlregistration.h>

// Shared by the table filter and the source tree so keys match exactly.
inline QString normalizedPacketDomain(const QString &value)
{
    QString domain = value.trimmed().toLower();
    while (domain.endsWith(QLatin1Char('.')))
        domain.chop(1);
    return domain;
}

inline QString normalizedPacketIP(const QString &value)
{
    QString address = value.trimmed().toLower();
    if (address.startsWith(QStringLiteral("::ffff:")) && address.contains(QLatin1Char('.')))
        address.remove(0, 7);
    return address;
}

// One packet-table row. Mirrors the fields of the daemon's packets.list summary
// that the upstream table shows as columns (see app/design/tokens.md).
struct PacketRow {
    quint64 number = 0;
    QString packetId;
    QString timeText;
    QString source;
    QString sourcePort;
    QString destination;
    QString destinationPort;
    QString protocol;
    QString client;
    // Stable app identity used by the source tree (executable path first).
    QString clientKey;
    int clientPid = 0;
    QString domain;
    QString streamId;
    QString summary;
    QString tcpFlags;
    QString direction;
    QString interfaceName;
    QString decodeStatus;
    QString sourceKind;
    QString deltaTime;
    QString streamDeltaTime;
    QString comment;
    QString highlightColor; // upstream PacketHighlightColor raw value ("")
    bool strikethrough = false;
    qint64 timestampMs = 0;
    int length = 0;
    int originalLength = 0; // on-wire size; statistics use it, fallback mimics length
    int tcpPayloadLength = 0;
    int severity = 0; // 0 normal, 1 warning (orange summary)
};

// Full-row persistence shape (saved packets): unlike snapshotRows' display
// subset, these maps round-trip every PacketRow field.
QVariantMap packetRowToMap(const PacketRow &row);
PacketRow packetRowFromMap(const QVariantMap &map);

class PacketListModel : public QAbstractTableModel
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(int count READ count NOTIFY countChanged)
    Q_PROPERTY(int totalCount READ totalCount NOTIFY countChanged)
    Q_PROPERTY(bool treeFilterActive READ treeFilterActive NOTIFY treeFilterChanged)
    // Bumped on every row-set mutation (clear/append/load). QML bindings for
    // derived values that C++ computes on demand (pin counts) re-run off it.
    Q_PROPERTY(int revision READ revision NOTIFY revisionChanged)

public:
    enum Role {
        NumberRole = Qt::UserRole + 1,
        PacketIdRole,
        TimeRole,
        SourceRole,
        SourcePortRole,
        DestinationRole,
        DestinationPortRole,
        ProtocolRole,
        ClientRole,
        ClientKeyRole,
        DomainRole,
        StreamIdRole,
        LengthRole,
        SummaryRole,
        SeverityRole,
        TcpFlagsRole,
        DirectionRole,
        InterfaceRole,
        DecodeStatusRole,
        SourceKindRole,
        TcpPayloadRole,
        ClientPidRole,
        DeltaTimeRole,
        StreamDeltaRole,
        BundleIdentifierRole,
        CommentRole,
        TagsRole,
        HighlightColorRole,
        StrikethroughRole,
    };
    Q_ENUM(Role)

    explicit PacketListModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    int columnCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    Q_INVOKABLE void clear();
    // TableView needs the visible-column count; a QAbstractListModel would only
    // instantiate one column per row.
    Q_INVOKABLE void setColumnCount(int count);
    Q_INVOKABLE QString packetIDAt(int row) const;
    Q_INVOKABLE int rowForPacketID(const QString &packetID) const;
    Q_INVOKABLE int numberAt(int row) const;
    Q_INVOKABLE QString summaryAt(int row) const;
    // Annotation readbacks for the row context menu (upstream reads the
    // shared row store when building the Highlight/Strikethrough state).
    Q_INVOKABLE QString highlightColorAt(int row) const;
    Q_INVOKABLE bool strikethroughAt(int row) const;
    Q_INVOKABLE QString commentAt(int row) const;

    // Optimistic annotation write that mirrors the upstream in-place
    // ingest-state mutation and the daemon's per-row semantics:
    // - highlightColorChange: "" keeps each row's current color.
    // - strikeToggle flips each row independently; styleReset clears both.
    // - commentChange replaces the stored TCP Viewer comment (pre-sanitized
    //   by the controller to mirror upstream PacketComment.sanitized).
    // Returns the ids that actually changed.
    struct AnnotationChange {
        QString highlightColorChange;
        bool hasHighlightChange = false;
        bool strikeToggle = false;
        bool styleReset = false;
        QString commentChange;
        bool hasCommentChange = false;
    };
    QVector<quint64> applyAnnotation(const QVector<quint64> &packetIDs,
                                     const AnnotationChange &change);
    // Flat snapshot for derived models (endpoint statistics).
    Q_INVOKABLE QVariantList snapshotRows() const;
    // Client-key readback for the row menu's Pin action (upstream pins the
    // selected app identity; disabled when a row has no client).
    Q_INVOKABLE const QString &clientKeyAt(int row) const;
    // Display name of the row's client (Pin menu title).
    Q_INVOKABLE QString clientNameAt(int row) const;
    // Full-row snapshot (saved packets): the persistence shape of
    // packetRowToMap for one visible row.
    Q_INVOKABLE QVariantMap rowSnapshotAt(int row) const;
    // Pinned-source counts (upstream shows per-pin packet counts from its
    // source-list assignments): count rows whose keys match a kind/filter,
    // mirroring the tree's appKey/domain/ip scope. Kind is "domain"/"ip"/
    // "client"; key is the domain name, IP address, or client key.
    Q_INVOKABLE int countForPin(const QString &kind, const QString &key) const;
    // Replace the whole table from serialized rows (Saved workspace):
    // saved records render as normal rows, no daemon backing.
    Q_INVOKABLE void loadRows(const QVariantList &rows);
    Q_INVOKABLE const QString &protocolAt(int row) const;
    // Sidebar scope filter. Empty keys mean "any"; missingDomain selects the
    // upstream "IP Addresses" pseudo-domain. IP matches only no-domain packets.
    Q_INVOKABLE void setTreeFilter(const QString &appKey, const QString &domainKey,
                                   const QString &ip, bool appsOnly, bool missingDomain);
    Q_INVOKABLE void clearTreeFilter();

    // Appends a batch in one beginInsertRows/endInsertRows pair, matching the
    // upstream table's coalesced row inserts.
    void appendRows(const QVector<PacketRow> &rows);

    int count() const { return visibleRowCount(); }
    int totalCount() const { return m_rows.size(); }
    int revision() const { return m_revision; }
    bool treeFilterActive() const { return m_treeFilterActive; }
    quint64 lastPacketID() const { return m_lastPacketID; }

signals:
    void countChanged();
    void treeFilterChanged();
    void revisionChanged();

private:
    int visibleRowCount() const;
    int sourceRow(int visibleRow) const;
    bool matchesTreeFilter(const PacketRow &row) const;
    void rebuildVisibleRows();

    QVector<PacketRow> m_rows;
    int m_revision = 0;
    QVector<int> m_visibleRows;
    quint64 m_lastPacketID = 0;
    int m_columnCount = 1;

    bool m_treeFilterActive = false;
    bool m_treeFilterAppsOnly = false;
    bool m_treeFilterMissingDomain = false;
    QString m_treeFilterAppKey;
    QString m_treeFilterDomainKey;
    QString m_treeFilterIP;
};
