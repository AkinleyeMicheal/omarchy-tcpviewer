// Follow-stream transcript state (upstream FollowStreamViewModel.swift):
// immutable reassembled snapshot, direction filter applied client-side,
// bounded on-screen representation, and text/hex payload rendering.
#ifndef FOLLOWSTREAMMODEL_H
#define FOLLOWSTREAMMODEL_H

#include <QAbstractListModel>
#include <QByteArray>
#include <QUrl>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

class DaemonClient;

class FollowStreamModel : public QAbstractListModel
{
    Q_OBJECT
    QML_ELEMENT
    // 0 both, 1 client-to-server, 2 server-to-client.
    Q_PROPERTY(int directionFilter READ directionFilter WRITE setDirectionFilter
               NOTIFY directionFilterChanged)
    Q_PROPERTY(bool hasStream READ hasStream NOTIFY hasStreamChanged)
    Q_PROPERTY(QString summaryLabel READ summaryLabel NOTIFY hasStreamChanged)
    Q_PROPERTY(QString statusText READ statusText NOTIFY hasStreamChanged)
    Q_PROPERTY(QString streamTitle READ streamTitle NOTIFY hasStreamChanged)
    Q_PROPERTY(QString followError READ followError NOTIFY followErrorChanged)

public:
    enum Role {
        DirectionRole = Qt::UserRole + 1,
        PacketIDRole,
        ByteCountRole,
        TimeRole,
        TextPayloadRole,
        HexPayloadRole,
    };
    Q_ENUM(Role)

    struct Record {
        int direction = 0; // 0 c2s, 1 s2c
        quint64 packetID = 0;
        int byteCount = 0;
        QString timeText;
        QString textPayload;
        QByteArray raw;
    };

    explicit FollowStreamModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    int directionFilter() const { return m_directionFilter; }
    void setDirectionFilter(int filter);
    bool hasStream() const { return m_hasStream; }
    QString summaryLabel() const;
    QString statusText() const;
    QString streamTitle() const;
    QString followError() const { return m_followError; }
    void setFollowError(const QString &message);

    // Rows (visible list) containing the query in payload or header text.
    Q_INVOKABLE QVector<int> searchRows(const QString &query) const;

    // Export helpers (upstream Save Transcript / Export Client|Server Bytes).
    Q_INVOKABLE QString transcriptText(int filter) const;
    Q_INVOKABLE QByteArray transcriptRaw(int filter) const;
    Q_INVOKABLE QString suggestedFileName() const;

    // Replaces the snapshot from a stream.follow success payload.
    void applyFollow(const QVariantMap &data);

signals:
    void hasStreamChanged();
    void directionFilterChanged();
    void followErrorChanged();

private:
    static QString formatPayloadText(const QByteArray &bytes);
    static QString formatPayloadHex(const QByteArray &bytes);
    static QString endpointLabel(const QVariantMap &endpoint);

    QVector<Record> m_records;
    QVector<int> m_visible;
    int m_directionFilter = 0;
    bool m_truncated = false;
    bool m_hasStream = false;
    qint64 m_clientBytes = 0;
    qint64 m_serverBytes = 0;
    quint64 m_capturedThrough = 0;
    QString m_protocol = QStringLiteral("tcp");
    QString m_streamID;
    QString m_clientLabel;
    QString m_serverLabel;
    QString m_followError;
};

// Independent controller for the Follow Stream window: it keeps its own
// DaemonClient connection so the follow request never stalls packet polling,
// and it mirrors upstream FollowStreamWindowController's lifecycle.
class FollowSessionController : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(FollowStreamModel *model READ model CONSTANT)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    // Test hook: TCPVIEWER_FOLLOW_REPRESENTATION seeds the transcript mode (0
    // text, 1 hex); -1 lets the window keep its default.
    Q_PROPERTY(int startupRepresentation READ startupRepresentation CONSTANT)

public:
    explicit FollowSessionController(QObject *parent = nullptr);

    FollowStreamModel *model() const { return m_model; }
    bool loading() const { return m_loading; }
    int startupRepresentation() const { return m_startupRepresentation; }

    Q_INVOKABLE void follow(const QString &packetID);
    // Save Transcript… / Export Client|Server Bytes…
    Q_INVOKABLE static bool saveFile(const QUrl &target, const QString &text);
    Q_INVOKABLE static bool saveFile(const QUrl &target, const QByteArray &data);

signals:
    // Emitted after a follow response (success or failure) so the QML shell
    // can open or raise the Follow Stream window.
    void followReady();
    void loadingChanged();

private:
    void setLoading(bool loading);

    DaemonClient *m_client = nullptr;
    FollowStreamModel *m_model = nullptr;
    bool m_loading = false;
    // Launch-with-follow hook (TCPVIEWER_FOLLOW_PACKET).
    QString m_startupPacketID;
    int m_startupAttempts = 0;
    bool m_startupStarted = false;
    int m_startupRepresentation = -1;
};

#endif // FOLLOWSTREAMMODEL_H
