#pragma once

#include "daemonclient.h"
#include "packetcolumnlayout.h"
#include "packetcustomcolumns.h"
#include "packetmodel.h"
#include "pinstore.h"
#include "savedpacketstore.h"
#include "sourcetreemodel.h"

#include <QByteArray>
#include <QHash>
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
    Q_PROPERTY(SourceTreeModel *sourceTree READ sourceTree CONSTANT)
    Q_PROPERTY(PacketColumnLayout *columnLayout READ columnLayout CONSTANT)
    Q_PROPERTY(PacketCustomColumns *customColumns READ customColumns CONSTANT)
    Q_PROPERTY(QString selectedPacketID READ selectedPacketID NOTIFY selectedPacketIDChanged)
    // Test hooks for launch behavior (tab count, split panes).
    Q_PROPERTY(bool startupSplit READ startupSplit CONSTANT)
    Q_PROPERTY(int startupTabs READ startupTabs CONSTANT)
    Q_PROPERTY(QVariantList interfaces READ interfaces NOTIFY interfacesChanged)
    Q_PROPERTY(QVariantList sources READ sources NOTIFY sourcesChanged)
    Q_PROPERTY(QVariantMap status READ status NOTIFY statusChanged)
    Q_PROPERTY(QVariantMap loadProgress READ loadProgress NOTIFY statusChanged)
    // Multi-file import progress: {"files": requested, "loaded": finished}.
    // Drives the "Loading file k of N…" status text (upstream importer).
    Q_PROPERTY(QVariantMap importProgress READ importProgress NOTIFY sourcesChanged)
    Q_PROPERTY(bool capturing READ capturing NOTIFY statusChanged)
    // True between a Stop click and the capture.stop reply (or a status
    // change to a non-capturing phase): bridges daemon-side stop latency
    // (queued reads, in-flight follow ops) with button feedback.
    Q_PROPERTY(bool stopInFlight READ stopInFlight NOTIFY stopInFlightChanged)
    Q_PROPERTY(bool connected READ connected NOTIFY connectedChanged)
    Q_PROPERTY(int totalCount READ totalCount NOTIFY totalCountChanged)
    Q_PROPERTY(QString currentSourceID READ currentSourceID NOTIFY currentSourceChanged)
    // CI/screenshot hook: which workspace mode ("packets"|"overview") Main
    // starts in. Overview is the default; TCPVIEWER_CAPTURE_MODE overrides.
    Q_PROPERTY(QString startupCaptureMode READ startupCaptureMode CONSTANT)
    // CI/screenshot hook: hide live interface controls (author: privacy).
    Q_PROPERTY(bool interfacesHidden READ interfacesHidden CONSTANT)
    // CI/screenshot hook: deterministic window size for captures.
    Q_PROPERTY(int startupWindowWidth READ startupWindowWidth CONSTANT)
    Q_PROPERTY(int startupWindowHeight READ startupWindowHeight CONSTANT)
    Q_PROPERTY(QString selectedInterface READ selectedInterface WRITE setSelectedInterface NOTIFY selectedInterfaceChanged)
    Q_PROPERTY(QString filterText READ filterText NOTIFY filterTextChanged)
    // Active quick-filter chip IDs (lowercase upstream ids, e.g. "tcp").
    // Reflects both QML clicks and startup hooks, so chips can highlight the
    // truth rather than their own local state.
    Q_PROPERTY(QStringList quickFilters READ quickFilters NOTIFY quickFiltersChanged)
    // Sidebar Favorites (upstream PacketSourceListService): pinned display-
    // filter expressions and named saved filters, persisted in QSettings next
    // to the overview card layout.
    Q_PROPERTY(QStringList pinnedFilters READ pinnedFilters NOTIFY filtersChanged)
    Q_PROPERTY(QVariantList savedFilters READ savedFilters NOTIFY filtersChanged)
    // Pinned sources (upstream PacketPinService): "Favorites > Pinned" items
    // for domains/IPs/clients. Session-document sources carry their own pins
    // while open (document-scoped rule) and replace the persistent list.
    Q_PROPERTY(QVariantList pinnedItems READ pinnedItems NOTIFY pinsChanged)
    Q_PROPERTY(QString selectedPinID READ selectedPinID NOTIFY pinsChanged)
    // Saved packets (upstream SavedPacketService): starred rows shown as their
    // own workspace under "Favorites > Saved".
    Q_PROPERTY(bool savedMode READ savedMode NOTIFY savedModeChanged)
    Q_PROPERTY(int savedCount READ savedCount NOTIFY savedPacketsChanged)
    Q_PROPERTY(QString errorText READ errorText NOTIFY errorTextChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    // True while an import chain is in flight (gates the Cancel button).
    Q_PROPERTY(bool importing READ importing NOTIFY sourcesChanged)
    Q_PROPERTY(QString capturePhase READ capturePhase NOTIFY statusChanged)
    // Overview page aggregates from capture.overview; QML refreshes while the
    // page is visible (the daemon caches per source revision).
    Q_PROPERTY(QVariantMap overview READ overview NOTIFY overviewChanged)
    Q_PROPERTY(bool overviewLoading READ overviewLoading NOTIFY overviewLoadingChanged)

public:
    explicit SessionController(QObject *parent = nullptr);

    DaemonClient *client() const { return m_client; }
    PacketListModel *packets() const { return m_packets; }
    SourceTreeModel *sourceTree() const { return m_sourceTree; }
    PacketColumnLayout *columnLayout() const { return m_columnLayout; }
    PacketCustomColumns *customColumns() const { return m_customColumns; }
    QString selectedPacketID() const { return m_selectedPacketID; }
    bool startupSplit() const { return qEnvironmentVariableIsSet("TCPVIEWER_SPLIT"); }
    int startupTabs() const
    {
        const int value = qEnvironmentVariableIntValue("TCPVIEWER_TABS");
        return value > 0 ? qBound(1, value, 8) : 1;
    }
    bool startupStatistics() const { return qEnvironmentVariableIsSet("TCPVIEWER_OPEN_STATS"); }
    // CI hook: comma-separated packet IDs to compare (TCPVIEWER_DIFF_PACKETS).
    QString startupDiffPackets() const { return qEnvironmentVariable("TCPVIEWER_DIFF_PACKETS"); }
    QVariantList interfaces() const { return m_interfaces; }
    QVariantList sources() const { return m_sources; }
    QVariantMap status() const { return m_status; }
    QVariantMap loadProgress() const { return m_status.value(QStringLiteral("load_progress")).toMap(); }
    QVariantMap importProgress() const;
    bool importing() const { return !m_importPaths.isEmpty(); }
    bool capturing() const;
    bool stopInFlight() const { return m_stopInFlight; }
    bool connected() const;
    int totalCount() const { return m_totalCount; }
    QString currentSourceID() const { return m_currentSourceID; }
    QString startupCaptureMode() const { return m_startupCaptureMode; }
    bool interfacesHidden() const { return m_interfacesHidden; }
    int startupWindowWidth() const { return m_startupWindowWidth; }
    int startupWindowHeight() const { return m_startupWindowHeight; }
    QString selectedInterface() const { return m_selectedInterface; }
    void setSelectedInterface(const QString &interfaceID);
    QString filterText() const { return m_filterText; }
    QStringList quickFilters() const { return m_quickFilters; }
    QStringList pinnedFilters() const { return m_pinnedFilters; }
    QVariantList savedFilters() const { return m_savedFilters; }
    QVariantList pinnedItems() const;
    QString selectedPinID() const { return m_selectedPinID; }
    bool savedMode() const { return m_savedMode; }
    int savedCount() const { return m_savedStore.count(); }
    QString errorText() const { return m_errorText; }
    // Loading state: explicit setLoading() calls OR an import chain in
    // flight (packet pages of an auto-selected file would otherwise clear
    // m_loading mid-chain and hide the cancel affordance).
    bool loading() const { return m_loading || importing(); }
    QString capturePhase() const { return m_status.value(QStringLiteral("phase")).toString(); }
    QVariantMap overview() const { return m_overview; }
    bool overviewLoading() const { return m_overviewLoading; }

    Q_INVOKABLE void start();
    Q_INVOKABLE void refreshInterfaces();
    Q_INVOKABLE void refreshSources();
    Q_INVOKABLE void startCapture(const QString &interfaceID);
    Q_INVOKABLE void stopCapture();
    Q_INVOKABLE void pauseCapture();
    Q_INVOKABLE void resumeCapture();
    Q_INVOKABLE void importFiles(const QVariantList &urls);
    // Aborts an in-flight import chain: daemon cancels the current file's
    // document load, drops the loading sources and stops the remaining files.
    Q_INVOKABLE void cancelImport();
    Q_INVOKABLE void reportError(const QString &message);
    // Clipboard/file helpers used by Overview "Share" actions (upstream
    // Share menu: Copy as Markdown / Save as Markdown).
    Q_INVOKABLE void copyToClipboard(const QString &text);
    Q_INVOKABLE bool writeTextFile(const QString &path, const QString &text);
    // Test hooks (CI/screenshots): read a single environment variable.
    Q_INVOKABLE QString envValue(const QString &name) const;
    // Test hook: TCPVIEWER_OPEN_STATS opens the statistics window at launch.
    Q_PROPERTY(bool startupStatistics READ startupStatistics CONSTANT)
    Q_PROPERTY(QString startupDiffPackets READ startupDiffPackets CONSTANT)
    Q_INVOKABLE void closeSource(const QString &sourceID);
    Q_INVOKABLE void selectSource(const QString &sourceID);
    Q_INVOKABLE void clearPackets();
    Q_INVOKABLE void applyFilter(const QString &filter);
    Q_INVOKABLE void setQuickFilters(const QVariantList &quickFilters);

    // Packet annotations (upstream row context menu): highlight color,
    // strikethrough and the TCP Viewer comment. Single-row in C1 — bulk
    // selection joins with the export slice. Includes the client-side
    // sanitize mirror so the optimistic row matches the daemon's stored
    // comment exactly.
    Q_INVOKABLE void setPacketHighlightColor(const QString &packetID, const QString &colorName);
    Q_INVOKABLE void togglePacketStrikethrough(const QString &packetID);
    Q_INVOKABLE void resetPacketTextStyle(const QString &packetID);
    Q_INVOKABLE void setPacketComment(const QString &packetID, const QString &comment);

    void dispatchPacketAnnotation(const QString &packetID,
                                  PacketListModel::AnnotationChange change,
                                  const QString &command, QVariantMap params);
    // Sidebar Favorites: pin/unpin the current display-filter expression and
    // manage named filters. saveFilter returns "" on success or a user-facing
    // validation message (mirrors upstream PacketCustomFilterService).
    Q_INVOKABLE void pinFilter(const QString &expression);
    Q_INVOKABLE void unpinFilter(const QString &expression);
    Q_INVOKABLE QString saveFilter(const QString &name, const QString &query);
    Q_INVOKABLE void removeSavedFilter(const QString &name);
    // Pinned sources + saved packets (upstream PacketPinService /
    // SavedPacketService, C2). Pins filter through the tree-filter keys;
    // selecting one is a sidebar selection that outlives the tree node state.
    // Saving stars a row's full summary so it survives the source closing.
    Q_INVOKABLE void pinPacketAt(int row);
    Q_INVOKABLE void pinDomain(const QString &domain);
    Q_INVOKABLE void pinIPAddress(const QString &address);
    Q_INVOKABLE void removePin(const QString &pinID);
    Q_INVOKABLE void selectPin(const QString &pinID);
    Q_INVOKABLE void savePacketAt(int row);
    Q_INVOKABLE void removeSavedPacket(const QString &packetID);
    Q_INVOKABLE void selectSavedPackets();
    Q_INVOKABLE void selectTreeFilter(const QString &nodeId);
    Q_INVOKABLE void toggleTreeExpanded(const QString &nodeId);
    Q_INVOKABLE void selectPacket(const QString &packetID);
    // Reveal targets the inspector of the main pane (follow-stream reveals).
    Q_INVOKABLE void revealPacket(const QString &packetID);
    Q_INVOKABLE void clearSelection();
    Q_INVOKABLE void clearError();
    // Create a packet-table column from a protocol detail field. The sample
    // value belongs to the packet the user right-clicked in the inspector.
    Q_INVOKABLE QString createCustomColumn(const QString &fieldName, const QString &title,
                                           const QString &sampleValue, const QString &packetID);
    Q_INVOKABLE void exportAll(const QString &path, const QString &format);
    Q_INVOKABLE void exportSelected(const QString &path, const QString &format);
    Q_INVOKABLE void exportSession(const QString &path);
    Q_INVOKABLE void requestOverview();
    // Overview card picker persistence (upstream TCPViewer.overview.cards).
    Q_INVOKABLE QVariantList overviewCards() const;
    Q_INVOKABLE void setOverviewCards(const QVariantList &cards);

signals:
    void interfacesChanged();
    void sourcesChanged();
    void statusChanged();
    void connectedChanged();
    void totalCountChanged();
    void currentSourceChanged();
    void selectedInterfaceChanged();
    void filterTextChanged();
    void quickFiltersChanged();
    void filtersChanged();
    void pinsChanged();
    void savedModeChanged();
    void savedPacketsChanged();
    void errorTextChanged();
    void loadingChanged();
    void selectedPacketIDChanged();
    // Emitted by revealPacket for the follow-window reveal flow.
    void revealRequested(const QString &packetID);
    void sourceOpened(const QString &sourceID);
    void exportFinished(const QString &path, int packetCount);
    void overviewChanged();
    void overviewLoadingChanged();
    void stopInFlightChanged();

private:
    void handleConnectedChanged();
    void handleResponse(const QString &command, const QVariantMap &data);
    // packets.list rides the request-id-aware signal so a response from a
    // superseded stream rebuild (e.g. an import racing a capture.state event)
    // is dropped instead of appended twice.
    void handlePacketListResponse(const QString &command, const QString &requestID,
                                  const QVariantMap &data);
    void handleResponseRequestFailure(const QString &requestID, const QString &command,
                                      const QString &code, const QString &message);
    void handleFailure(const QString &command, const QString &code, const QString &message);
    void handleEvent(const QString &name, const QVariantMap &data);
    void handlePackets(const QVariantMap &data);
    void setStatus(const QVariantMap &status);
    void refreshStatus();
    void selectSourceInternal(const QString &sourceID);
    void resetStream();
    void requestPackets(bool firstPage);
    void persistSavedFilters();
    // Pinned sources + saved packets (C2). Pin mutations write through to
    // QSettings; document overlays stay in memory only. Saved annotations
    // persist on every mutation (matrix stays small — dozens of records).
    void persistPins();
    void persistSavedPackets();
    // Active pin store: the document overlay wins while a session-doc source
    // is open (upstream PacketPinService useDocumentRecords).
    const PinStore *activePinStore() const
    {
        const auto it = m_documentPins.constFind(m_currentSourceID);
        return it != m_documentPins.constEnd() ? &it.value() : &m_pinStore;
    }
    void handleSessionState(const QVariantMap &data);
    void leaveSavedMode();
    void setError(const QString &message);
    void setLoading(bool loading);
    void setStopInFlight(bool stopInFlight);
    void setTotalCount(int total);
    void setFilterTextInternal(const QString &filter);
    void applyTreeSelectHook();
    static PacketRow parseSummary(const QVariantMap &summary);

    PinStore m_pinStore;
    QHash<QString, PinStore> m_documentPins;
    QString m_selectedPinID;
    SavedPacketStore m_savedStore;
    bool m_savedMode = false;
    // Saved workspace re-entry: the source the packets table showed before
    // "Saved" was selected.
    QString m_lastNonSavedSourceID;

    DaemonClient *m_client = nullptr;
    PacketListModel *m_packets = nullptr;
    SourceTreeModel *m_sourceTree = nullptr;
    PacketColumnLayout *m_columnLayout = nullptr;
    PacketCustomColumns *m_customColumns = nullptr;
    QTimer *m_pollTimer = nullptr;
    QTimer *m_statusTimer = nullptr;

    QVariantList m_interfaces;
    QVariantList m_sources;
    QVariantMap m_status;
    QVariantMap m_overview;
    QString m_overviewRevisionKey;
    QString m_currentSourceID;
    QString m_startupCaptureMode;
    // CI/screenshot hook: TCPVIEWER_FILTER applies a display filter to the
    // first opened source (also exercises the Favorites selection state).
    QString m_startupFilter;
    bool m_startupFilterApplied = false;
    bool m_interfacesHidden = false;
    int m_startupWindowWidth = 0;
    int m_startupWindowHeight = 0;
    QString m_selectedInterface;
    QString m_filterText;
    QString m_errorText;
    QString m_pendingSelectPath;
    QStringList m_quickFilters;
    QStringList m_pinnedFilters;
    QVariantList m_savedFilters;
    bool m_loading = false;
    bool m_requestInFlight = false;
    bool m_overviewLoading = false;
    bool m_stopInFlight = false;
    int m_totalCount = 0;
    quint64 m_lastPacketID = 0;
    qint64 m_lastPacketTimestamp = 0;
    QHash<QString, qint64> m_lastStreamTimestamp;
    // Stream rebuild epoch: resetStream/selectSourceInternal bumps it; packet
    // pages are accepted only when their fetch still belongs to this epoch.
    qint64 m_streamEpoch = 0;
    QHash<QString, qint64> m_pageEpoch;
    int m_pageSize = 5000;
    QStringList m_pendingOpenFiles;
    // Paths of the import chain in flight (multi-file progress display).
    QStringList m_importPaths;
    QString m_selectedPacketID;
    // CI hook: TCPVIEWER_CAPTURE_IFACE starts live capture after startup.
    QString m_startupCaptureIface;
    bool m_startupCaptureStarted = false;
    // CI hook: TCPVIEWER_TREE_SELECT selects a source-tree node once it exists.
    QString m_treeSelectNode;
    bool m_treeSelectApplied = false;
};
