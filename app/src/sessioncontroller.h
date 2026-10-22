#pragma once

#include "daemonclient.h"
#include "packetmodel.h"

#include <QObject>
#include <QVariantList>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

class QTimer;

// Owns the viewer's daemon session: interface list, capture lifecycle, source
// selection, and the pull-based packet stream (packets.list --since-id).
class SessionController : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(DaemonClient *client READ client CONSTANT)
    Q_PROPERTY(PacketListModel *packets READ packets CONSTANT)
    Q_PROPERTY(QVariantList interfaces READ interfaces NOTIFY interfacesChanged)
    Q_PROPERTY(QVariantList sources READ sources NOTIFY sourcesChanged)
    Q_PROPERTY(QVariantMap status READ status NOTIFY statusChanged)
    Q_PROPERTY(QVariantMap loadProgress READ loadProgress NOTIFY statusChanged)
    Q_PROPERTY(bool capturing READ capturing NOTIFY statusChanged)
    Q_PROPERTY(bool connected READ connected NOTIFY connectedChanged)
    Q_PROPERTY(int totalCount READ totalCount NOTIFY totalCountChanged)
    Q_PROPERTY(QString currentSourceID READ currentSourceID NOTIFY currentSourceChanged)
    Q_PROPERTY(QString selectedInterface READ selectedInterface WRITE setSelectedInterface NOTIFY selectedInterfaceChanged)
    Q_PROPERTY(QString filterText READ filterText NOTIFY filterTextChanged)
    Q_PROPERTY(QString errorText READ errorText NOTIFY errorTextChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    Q_PROPERTY(QString capturePhase READ capturePhase NOTIFY statusChanged)

public:
    explicit SessionController(QObject *parent = nullptr);

    DaemonClient *client() const { return m_client; }
    PacketListModel *packets() const { return m_packets; }
    QVariantList interfaces() const { return m_interfaces; }
    QVariantList sources() const { return m_sources; }
    QVariantMap status() const { return m_status; }
    QVariantMap loadProgress() const { return m_status.value(QStringLiteral("load_progress")).toMap(); }
    bool capturing() const;
    bool connected() const;
    int totalCount() const { return m_totalCount; }
    QString currentSourceID() const { return m_currentSourceID; }
    QString selectedInterface() const { return m_selectedInterface; }
    void setSelectedInterface(const QString &interfaceID);
    QString filterText() const { return m_filterText; }
    QString errorText() const { return m_errorText; }
    bool loading() const { return m_loading; }
    QString capturePhase() const { return m_status.value(QStringLiteral("phase")).toString(); }

    Q_INVOKABLE void start();
    Q_INVOKABLE void refreshInterfaces();
    Q_INVOKABLE void refreshSources();
    Q_INVOKABLE void startCapture(const QString &interfaceID);
    Q_INVOKABLE void stopCapture();
    Q_INVOKABLE void pauseCapture();
    Q_INVOKABLE void resumeCapture();
    Q_INVOKABLE void importFiles(const QVariantList &urls);
    Q_INVOKABLE void closeSource(const QString &sourceID);
    Q_INVOKABLE void selectSource(const QString &sourceID);
    Q_INVOKABLE void clearPackets();
    Q_INVOKABLE void applyFilter(const QString &filter);
    Q_INVOKABLE void setQuickFilters(const QVariantList &quickFilters);
    Q_INVOKABLE void clearError();

signals:
    void interfacesChanged();
    void sourcesChanged();
    void statusChanged();
    void connectedChanged();
    void totalCountChanged();
    void currentSourceChanged();
    void selectedInterfaceChanged();
    void filterTextChanged();
    void errorTextChanged();
    void loadingChanged();
    void sourceOpened(const QString &sourceID);

private:
    void handleConnectedChanged();
    void handleResponse(const QString &command, const QVariantMap &data);
    void handleFailure(const QString &command, const QString &code, const QString &message);
    void handleEvent(const QString &name, const QVariantMap &data);
    void handlePackets(const QVariantMap &data);
    void setStatus(const QVariantMap &status);
    void refreshStatus();
    void selectSourceInternal(const QString &sourceID);
    void resetStream();
    void requestPackets(bool firstPage);
    void setError(const QString &message);
    void setLoading(bool loading);
    void setTotalCount(int total);
    void setFilterTextInternal(const QString &filter);
    static PacketRow parseSummary(const QVariantMap &summary);

    DaemonClient *m_client = nullptr;
    PacketListModel *m_packets = nullptr;
    QTimer *m_pollTimer = nullptr;
    QTimer *m_statusTimer = nullptr;

    QVariantList m_interfaces;
    QVariantList m_sources;
    QVariantMap m_status;
    QString m_currentSourceID;
    QString m_selectedInterface;
    QString m_filterText;
    QString m_errorText;
    QString m_pendingSelectPath;
    QStringList m_quickFilters;
    bool m_loading = false;
    bool m_requestInFlight = false;
    int m_totalCount = 0;
    quint64 m_lastPacketID = 0;
    int m_pageSize = 5000;
    QStringList m_pendingOpenFiles;
};
