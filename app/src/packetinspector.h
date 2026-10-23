// Per-pane inspector state (upstream: every workspace pane owns one). Each
// inspector carries its own daemon connection so split panes can inspect
// different packets concurrently without stalling packet polling.
#ifndef PACKETINSPECTOR_H
#define PACKETINSPECTOR_H

#include "daemonclient.h"
#include "packetdetailmodel.h"

#include <QByteArray>
#include <QObject>
#include <QString>
#include <QtQml/qqmlregistration.h>

class PacketInspector : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(PacketDetailModel *detailModel READ detailModel CONSTANT)
    Q_PROPERTY(QString packetID READ packetID NOTIFY packetIDChanged)
    Q_PROPERTY(QByteArray packetBytes READ packetBytes NOTIFY packetBytesChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)
    // CI hooks (formerly SessionController properties).
    Q_PROPERTY(int autoSelectDetailRow READ autoSelectDetailRow CONSTANT)
    Q_PROPERTY(QString autoDetailFilter READ autoDetailFilter CONSTANT)

public:
    explicit PacketInspector(QObject *parent = nullptr);

    PacketDetailModel *detailModel() const { return m_detailModel; }
    QString packetID() const { return m_packetID; }
    QByteArray packetBytes() const { return m_packetBytes; }
    bool loading() const { return m_loading; }
    QString error() const { return m_error; }
    int autoSelectDetailRow() const { return m_autoSelectDetailRow; }
    QString autoDetailFilter() const { return m_autoDetailFilter; }

    Q_INVOKABLE void select(const QString &packetID, const QString &sourceID);
    Q_INVOKABLE void clear();

signals:
    void packetBytesChanged();
    void loadingChanged();
    void errorChanged();
    void packetIDChanged();

private:
    DaemonClient *m_client = nullptr;
    PacketDetailModel *m_detailModel = nullptr;
    QString m_packetID;
    QByteArray m_packetBytes;
    bool m_loading = false;
    QString m_error;
    int m_autoSelectDetailRow = -1;
    QString m_autoDetailFilter;
};

#endif // PACKETINSPECTOR_H
