#pragma once

#include <QAbstractListModel>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QtQml/qqmlregistration.h>

class SessionController;

// Workspace tabs (upstream tab mode): each tab owns its source selection,
// sidebar tree scope, display filter, quick-filter chips, selected packet,
// split state, and Packets/Overview view; live tabs share one capture.
// Entries carry stable ids ("tab-N") so CLI/MCP targeting later in Phase F
// survives reordering; the visit history is kept separately from the
// left-to-right order like upstream's Back/Forward.
class WorkspaceTabsController : public QAbstractListModel
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(SessionController *session READ session WRITE setSession NOTIFY sessionChanged)
    Q_PROPERTY(int activeTab READ activeTab NOTIFY activeTabChanged)
    Q_PROPERTY(int count READ count NOTIFY countChanged)
    Q_PROPERTY(bool canBack READ canBack NOTIFY historyChanged)
    Q_PROPERTY(bool canForward READ canForward NOTIFY historyChanged)
    // The active tab's workspace mode ("packets"|"overview"); the UI's single
    // mode store so tab switches restore the saved view.
    Q_PROPERTY(QString activeCaptureMode READ activeCaptureMode
                   WRITE setActiveCaptureMode NOTIFY activeCaptureModeChanged)

public:
    enum Roles {
        IdRole = Qt::UserRole + 1,
        LabelRole,
        SplitVisibleRole,
        SourceIdRole,
        TreeFilterRole,
        FilterTextRole,
        QuickFiltersRole,
        SelectedPacketIdRole,
        CaptureModeRole,
    };
    Q_ENUM(Roles)

    explicit WorkspaceTabsController(QObject *parent = nullptr);

    SessionController *session() const { return m_session; }
    void setSession(SessionController *session);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    int activeTab() const { return m_activeTab; }
    int count() const { return m_entries.size(); }
    bool canBack() const { return m_historyCursor > 0; }
    bool canForward() const { return m_historyCursor < m_history.size() - 1; }
    QString activeCaptureMode() const;
    void setActiveCaptureMode(const QString &mode);

    // Startup seeding (replacing any previous content): tab count, whether
    // the first tab shows the split, the seeded workspace mode, the scripted
    // CI ops ("new" | "sel=k" | "filter=text" | "mode=x", ';'-separated), and
    // the tab to select after the script runs.
    Q_INVOKABLE void seed(int tabs, bool splitFirst, const QString &captureMode,
                          const QString &script, int selectTarget);

    Q_INVOKABLE bool selectTab(int index);
    Q_INVOKABLE void newTab();
    // Sidebar rows: scope the new tab to an app/domain/IP node.
    Q_INVOKABLE void openSourceInNewTab(const QString &nodeID);
    // Returns false only when there is a single tab left: the caller closes
    // the window like upstream's closing-last-tab behavior.
    Q_INVOKABLE bool closeTab(int index);
    Q_INVOKABLE void closeOtherTabs(int index);
    Q_INVOKABLE void closeTabsToRight(int index);
    Q_INVOKABLE void moveTab(int from, int to);
    Q_INVOKABLE void selectNextTab(int delta);
    Q_INVOKABLE void historyStep(int delta);
    Q_INVOKABLE void toggleSplit();
    Q_INVOKABLE QString tabID(int index) const;
    // Rename a tab (file imports name the offline tab after the file; CLI
    // tab management can address it later).
    Q_INVOKABLE void setTabLabel(int row, const QString &label);
    // File ▸ Open flow: fresh tab named after the import, no filter carried
    // over, then the files route through the standard importer.
    Q_INVOKABLE void importIntoNewTab(const QVariantList &files, const QString &label);

signals:
    void sessionChanged();
    void activeTabChanged(int index);
    void countChanged();
    void historyChanged();
    void activeCaptureModeChanged();
    // QML raises the focused workspace and re-points the inspector fetches
    // after a switch (per-pane selection state stays in the view layer).
    void stateApplied(int index);
    // Restore the saved selection once the tab's rows/scope have landed.
    void restoreSelectionRequested(const QString &packetID);

private:
    struct TabEntry {
        QString id;
        QString label;
        bool splitVisible = false;
        QString sourceID;
        QString treeFilter;
        QString filterText;
        QVariantList quickFilters;
        QString selectedPacketID;
        QString captureMode;
    };
    struct PendingRestore {
        QString treeFilter;
        QString selectedPacketID;
    };

    TabEntry makeDefaultEntry();
    void snapshotActive();
    void appendEntry(const TabEntry &entry);
    void applyEntry(int index);
    void pushHistory(const QString &tabID);
    void setActiveIndex(int index);
    void writeRole(int index, int role, const QVariant &value);
    void runScript(const QString &script, int selectTab);
    void tickPendingRestore();
    QString entryScopeTarget(const TabEntry &entry) const
    {
        return entry.treeFilter.isEmpty() ? QStringLiteral("all") : entry.treeFilter;
    }

    SessionController *m_session = nullptr;
    QList<TabEntry> m_entries;
    int m_activeTab = -1;
    int m_nextTabNumber = 0;
    QStringList m_history;
    int m_historyCursor = -1;
    PendingRestore m_pendingRestore;
    int m_pendingRestoreTries = 0;
    bool m_sessionConnected = false;
};
