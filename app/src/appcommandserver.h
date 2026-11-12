#pragma once

#include <QLocalServer>
#include <QLocalSocket>
#include <QObject>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

class SessionController;

// Local command bridge for the running app (upstream's CLI/MCP connection to
// TCP Viewer): a JSON-lines unix socket next to the daemon's, speaking the
// same schema_version 1 envelope. Each request is
// `{"schema_version": 1, "request_id": "...", "command": "...", "params": {...}}`
// and each response is a single JSON object
// `{"schema_version": 1, "request_id": "...", "ok": true, "command": "...",
// "data": {...}}` or `{..., "ok": false, "error": {"code", "message"}}`.
// Commands cover workspace tabs, panes, Overview, endpoint statistics, and
// packet reveal; settings land with the settings UI cluster.
class AppCommandServer : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    // Socket path override for tests/CI; defaults to
    // $XDG_RUNTIME_DIR/omarchy-tcpviewer/app.sock.
    Q_PROPERTY(QString socketPath READ socketPath WRITE setSocketPath
                   NOTIFY socketPathChanged)

public:
    explicit AppCommandServer(QObject *parent = nullptr);
    ~AppCommandServer() override;

    QString socketPath() const;
    void setSocketPath(const QString &path);
    // Listen (or re-listen after a path change); a stale socket file from a
    // crashed instance is removed first, so the newest app instance serves.
    Q_INVOKABLE bool listen();
    Q_INVOKABLE void close();

signals:
    void socketPathChanged();
    // packets reveal: QML brings the window forward and presents the packet.
    void revealRequested(const QString &packetID);

private:
    void handleConnection();
    void handleReadyRead(QLocalSocket *socket);
    void dispatch(QLocalSocket *socket, const QString &requestID,
                  const QString &command, const QVariantMap &params);
    void sendResult(QLocalSocket *socket, const QString &requestID,
                    const QString &command, const QVariant &result);
    void sendError(QLocalSocket *socket, const QString &requestID,
                   const QString &command, const QString &code,
                   const QString &message);

    QString m_socketPath;
    QLocalServer m_server;
};
