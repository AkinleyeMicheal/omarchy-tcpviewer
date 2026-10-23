#pragma once

#include <QElapsedTimer>
#include <QHash>
#include <QObject>
#include <QString>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

class QLocalSocket;
class QTimer;

// Upstream schema_version 1 client: newline-delimited JSON over the daemon's
// Unix socket. Responses carry `ok`; async events carry `event`.
class DaemonClient : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(bool connected READ connected NOTIFY connectedChanged)
    Q_PROPERTY(QString socketPath READ socketPath CONSTANT)
    Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)

public:
    explicit DaemonClient(QObject *parent = nullptr);

    bool connected() const { return m_connected; }
    QString socketPath() const { return m_socketPath; }
    QString lastError() const { return m_lastError; }

    Q_INVOKABLE void start();
    Q_INVOKABLE void stop();
    // Returns the request id; empty on immediate transport failure.
    Q_INVOKABLE QString send(const QString &command, const QVariantMap &params = {},
                             int timeoutSeconds = 30);
    Q_INVOKABLE void subscribeToEvents(bool enabled = true);

signals:
    void connectedChanged();
    void response(const QString &command, const QVariantMap &data);
    void failure(const QString &command, const QString &code, const QString &message);
    // Request-scoped failure for callers that may have abandoned a request
    // (custom columns) and must not consume another request's error.
    void requestFailure(const QString &requestID, const QString &command,
                        const QString &code, const QString &message);
    void event(const QString &name, const QVariantMap &data);
    void lastErrorChanged();

private:
    void scheduleReconnect();
    void handleLine(const QByteArray &line);
    void setLastError(const QString &message);

    QLocalSocket *m_socket = nullptr;
    QTimer *m_reconnectTimer = nullptr;
    QTimer *m_timeoutTimer = nullptr;
    QString m_socketPath;
    QString m_lastError;
    bool m_connected = false;
    bool m_started = false;

    struct Pending {
        QString command;
        qint64 deadlineMs = 0;
    };
    QHash<QString, Pending> m_pending;
    QElapsedTimer m_clock;
};
