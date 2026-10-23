#include "packetinspector.h"

#include <QVariantMap>

PacketInspector::PacketInspector(QObject *parent)
    : QObject(parent)
    , m_client(new DaemonClient(this))
    , m_detailModel(new PacketDetailModel(this))
{
    // Test hooks: TCPVIEWER_SELECT_DETAIL_ROW pins the detail row after decode;
    // TCPVIEWER_DETAIL_FILTER pre-fills the inspector filter field.
    bool rowParsed = false;
    const int envRow = qEnvironmentVariableIntValue("TCPVIEWER_SELECT_DETAIL_ROW", &rowParsed);
    m_autoSelectDetailRow = rowParsed && envRow >= 0 ? envRow : -1;
    m_autoDetailFilter = qEnvironmentVariable("TCPVIEWER_DETAIL_FILTER");

    connect(m_client, &DaemonClient::response, this,
            [this](const QString &command, const QVariantMap &data) {
        // Responses associated with an older selection are discarded.
        const QString packetID = data.value(QStringLiteral("packet_id")).toString();
        if (command == QStringLiteral("packets.details")) {
            if (packetID != m_packetID)
                return;
            m_detailModel->setNodes(data.value(QStringLiteral("nodes")).toList());
            m_loading = false;
            emit loadingChanged();
            return;
        }
        if (command == QStringLiteral("packets.bytes")) {
            if (packetID != m_packetID)
                return;
            m_packetBytes = QByteArray::fromBase64(
                data.value(QStringLiteral("data")).toByteArray());
            emit packetBytesChanged();
            return;
        }
    });
    connect(m_client, &DaemonClient::failure, this,
            [this](const QString &command, const QString &code, const QString &message) {
        Q_UNUSED(code)
        if (command != QStringLiteral("packets.details"))
            return;
        m_loading = false;
        m_error = message;
        emit loadingChanged();
        emit errorChanged();
    });

    m_client->start();
}

void PacketInspector::select(const QString &packetID, const QString &sourceID)
{
    if (packetID.isEmpty()) {
        clear();
        return;
    }
    if (packetID == m_packetID)
        return;

    m_packetID = packetID;
    m_detailModel->clear();
    m_packetBytes.clear();
    emit packetBytesChanged();
    emit packetIDChanged();
    m_loading = true;
    emit loadingChanged();
    if (!m_error.isEmpty()) {
        m_error.clear();
        emit errorChanged();
    }

    QVariantMap detailParams{
        {QStringLiteral("packet_id"), packetID},
        {QStringLiteral("max_depth"), 12},
        {QStringLiteral("max_nodes"), 5000},
    };
    QVariantMap byteParams{
        {QStringLiteral("packet_id"), packetID},
        {QStringLiteral("offset"), 0},
        {QStringLiteral("length"), 0},
        {QStringLiteral("encoding"), QStringLiteral("base64")},
    };
    if (!sourceID.isEmpty()) {
        detailParams.insert(QStringLiteral("source_id"), sourceID);
        byteParams.insert(QStringLiteral("source_id"), sourceID);
    }
    m_client->send(QStringLiteral("packets.details"), detailParams, 60);
    m_client->send(QStringLiteral("packets.bytes"), byteParams, 60);
}

void PacketInspector::clear()
{
    if (m_packetID.isEmpty() && m_packetBytes.isEmpty()
        && m_detailModel->rowCount() == 0 && m_error.isEmpty() && !m_loading) {
        return;
    }
    m_packetID.clear();
    m_detailModel->clear();
    m_packetBytes.clear();
    emit packetBytesChanged();
    emit packetIDChanged();
    m_loading = false;
    emit loadingChanged();
    if (!m_error.isEmpty()) {
        m_error.clear();
        emit errorChanged();
    }
}
