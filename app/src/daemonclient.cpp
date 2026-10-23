#include "daemonclient.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalSocket>
#include <QTimer>
#include <QUuid>
#include <QVariantList>

namespace {
// Daemon response lines are capped at 16 MiB server-side. Abort a peer that
// keeps streaming an unterminated line so the client buffer cannot grow
// without bound.
constexpr qint64 kMaxReadBufferBytes = 20 * 1024 * 1024;
} // namespace

DaemonClient::DaemonClient(QObject *parent)
    : QObject(parent)
{
    const QString override = qEnvironmentVariable("TCPVIEWER_SOCKET");
    if (!override.isEmpty()) {
        m_socketPath = override;
    } else {
        const QString runtimeDir = qEnvironmentVariable("XDG_RUNTIME_DIR");
        if (runtimeDir.isEmpty()) {
            // The daemon refuses to run without a systemd user runtime dir.
            // Never fall back to a world-writable directory: a foreign user
            // could replace the socket and impersonate tcpviewerd.
            setLastError(QStringLiteral("XDG_RUNTIME_DIR is not set."));
        } else {
            m_socketPath = runtimeDir
                + QStringLiteral("/omarchy-tcpviewer/tcpviewerd.sock");
        }
    }

    m_socket = new QLocalSocket(this);
    connect(m_socket, &QLocalSocket::connected, this, [this]() {
        m_connected = true;
        m_reconnectTimer->stop();
        setLastError(QString());
        emit connectedChanged();
        subscribeToEvents(true);
    });
    connect(m_socket, &QLocalSocket::disconnected, this, [this]() {
        m_connected = false;
        emit connectedChanged();
        m_pending.clear();
        if (m_started)
            scheduleReconnect();
    });
    connect(m_socket, &QLocalSocket::errorOccurred, this,
            [this](QLocalSocket::LocalSocketError error) {
                if (error == QLocalSocket::PeerClosedError)
                    return;
                setLastError(m_socket->errorString());
                m_connected = false;
                emit connectedChanged();
                if (m_started)
                    scheduleReconnect();
            });
    connect(m_socket, &QLocalSocket::readyRead, this, [this]() {
        while (m_socket->canReadLine()) {
            const QByteArray line = m_socket->readLine().trimmed();
            if (!line.isEmpty())
                handleLine(line);
        }
        // Reject unbounded partial lines from a misbehaving socket peer.
        if (!m_socket->canReadLine() && m_socket->bytesAvailable() > kMaxReadBufferBytes) {
            setLastError(QStringLiteral("tcpviewerd sent an oversized response."));
            m_socket->abort();
            return;
        }
    });

    m_reconnectTimer = new QTimer(this);
    m_reconnectTimer->setSingleShot(true);
    m_reconnectTimer->setInterval(1000);
    connect(m_reconnectTimer, &QTimer::timeout, this, [this]() {
        if (!m_started || m_connected)
            return;
        m_socket->abort();
        m_socket->connectToServer(m_socketPath);
    });

    m_timeoutTimer = new QTimer(this);
    m_timeoutTimer->setInterval(1000);
    connect(m_timeoutTimer, &QTimer::timeout, this, [this]() {
        const qint64 now = m_clock.elapsed();
        QList<QString> expired;
        for (auto it = m_pending.cbegin(); it != m_pending.cend(); ++it) {
            if (it->deadlineMs > 0 && now > it->deadlineMs)
                expired.append(it.key());
        }
        for (const QString &id : expired) {
            const Pending pending = m_pending.take(id);
            const QString message = QStringLiteral("No response from tcpviewerd within the timeout.");
            emit failure(pending.command, QStringLiteral("timeout"), message);
            emit requestFailure(id, pending.command, QStringLiteral("timeout"), message);
        }
    });
    m_clock.start();
}

void DaemonClient::start()
{
    if (m_started)
        return;
    m_started = true;
    m_timeoutTimer->start();
    if (m_socketPath.isEmpty()) {
        setLastError(QStringLiteral("Cannot locate tcpviewerd: XDG_RUNTIME_DIR is not set."));
        return;
    }
    m_socket->connectToServer(m_socketPath);
    if (m_socket->state() != QLocalSocket::ConnectedState)
        scheduleReconnect();
}

void DaemonClient::stop()
{
    m_started = false;
    m_reconnectTimer->stop();
    m_timeoutTimer->stop();
    m_socket->abort();
}

void DaemonClient::scheduleReconnect()
{
    if (!m_reconnectTimer->isActive())
        m_reconnectTimer->start();
}

QString DaemonClient::send(const QString &command, const QVariantMap &params, int timeoutSeconds)
{
    if (!m_connected) {
        setLastError(QStringLiteral("tcpviewerd is not connected."));
        return {};
    }

    const QString requestID = QUuid::createUuid().toString(QUuid::WithoutBraces);
    QJsonObject envelope{
        {QStringLiteral("schema_version"), 1},
        {QStringLiteral("request_id"), requestID},
        {QStringLiteral("command"), command},
    };
    if (!params.isEmpty())
        envelope.insert(QStringLiteral("params"), QJsonObject::fromVariantMap(params));

    m_socket->write(QJsonDocument(envelope).toJson(QJsonDocument::Compact));
    m_socket->write("\n");
    m_socket->flush();

    Pending pending;
    pending.command = command;
    pending.deadlineMs = timeoutSeconds > 0 ? m_clock.elapsed() + qint64(timeoutSeconds) * 1000 : 0;
    m_pending.insert(requestID, pending);
    return requestID;
}

void DaemonClient::subscribeToEvents(bool enabled)
{
    if (!m_connected)
        return;
    const QString requestID = QUuid::createUuid().toString(QUuid::WithoutBraces);
    QJsonObject envelope{
        {QStringLiteral("schema_version"), 1},
        {QStringLiteral("request_id"), requestID},
        {QStringLiteral("command"), QStringLiteral("events.subscribe")},
        {QStringLiteral("params"), QJsonObject{{QStringLiteral("enabled"), enabled}}},
    };
    m_socket->write(QJsonDocument(envelope).toJson(QJsonDocument::Compact));
    m_socket->write("\n");
    m_socket->flush();
}

void DaemonClient::handleLine(const QByteArray &line)
{
    QJsonParseError parseError;
    const QJsonDocument document = QJsonDocument::fromJson(line, &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isObject())
        return;

    const QJsonObject object = document.object();

    if (object.contains(QStringLiteral("event"))) {
        emit event(object.value(QStringLiteral("event")).toString(),
                   object.value(QStringLiteral("data")).toObject().toVariantMap());
        return;
    }

    const QString requestID = object.value(QStringLiteral("request_id")).toString();
    const Pending pending = m_pending.take(requestID);
    const QString command = object.value(QStringLiteral("command")).toString(
        pending.command.isEmpty() ? requestID : pending.command);

    if (object.value(QStringLiteral("ok")).toBool()) {
        emit response(command, object.value(QStringLiteral("data")).toObject().toVariantMap());
        return;
    }

    const QJsonObject error = object.value(QStringLiteral("error")).toObject();
    const QString code = error.value(QStringLiteral("code")).toString(QStringLiteral("unknown"));
    const QString message = error.value(QStringLiteral("message"))
        .toString(QStringLiteral("Unknown daemon error."));
    emit failure(command, code, message);
    emit requestFailure(requestID, command, code, message);
}

void DaemonClient::setLastError(const QString &message)
{
    if (m_lastError == message)
        return;
    m_lastError = message;
    emit lastErrorChanged();
}
