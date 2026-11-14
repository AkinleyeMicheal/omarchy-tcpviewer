#include "workspacetabscontroller.h"

#include "packetmodel.h"
#include "sessioncontroller.h"

#include <QDebug>

WorkspaceTabsController::WorkspaceTabsController(QObject *parent)
    : QAbstractListModel(parent)
{
}

void WorkspaceTabsController::setSession(SessionController *session)
{
    if (m_session == session || m_sessionConnected)
        return;
    m_session = session;
    emit sessionChanged();
    if (!m_session)
        return;
    m_sessionConnected = true;
    // The switched source's rows and source tree land asynchronously; the
    // pending tree scope and selection apply once they are visible, with
    // bounded retries so a vanished node or a live-appending source can't
    // spin forever.
    connect(m_session->packets(), &PacketListModel::revisionChanged,
            this, &WorkspaceTabsController::tickPendingRestore);
    // A source opened into the active tab (import finished, live capture
    // started): record it so the tab's entry matches what it displays.
    // Only the source id — filter/tree/selection keep their pending-restore
    // state until the switched-to rows are visible.
    connect(m_session, &SessionController::sourceOpened, this, [this](const QString &sourceID) {
        if (m_activeTab < 0 || m_activeTab >= m_entries.size())
            return;
        TabEntry &entry = m_entries[m_activeTab];
        if (entry.sourceID == sourceID)
            return;
        entry.sourceID = sourceID;
        const QModelIndex changed = index(m_activeTab);
        emit dataChanged(changed, changed, {SourceIdRole});
    });
}

int WorkspaceTabsController::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : m_entries.size();
}

QVariant WorkspaceTabsController::data(const QModelIndex &index, int role) const
{
    const int row = index.row();
    if (row < 0 || row >= m_entries.size())
        return {};
    const TabEntry &entry = m_entries.at(row);
    switch (role) {
    case IdRole:
        return entry.id;
    case LabelRole:
        return entry.label;
    case SplitVisibleRole:
        return entry.splitVisible;
    case SourceIdRole:
        return entry.sourceID;
    case TreeFilterRole:
        return entry.treeFilter;
    case FilterTextRole:
        return entry.filterText;
    case QuickFiltersRole:
        return entry.quickFilters;
    case SelectedPacketIdRole:
        return entry.selectedPacketID;
    case CaptureModeRole:
        return entry.captureMode;
    }
    return {};
}

QHash<int, QByteArray> WorkspaceTabsController::roleNames() const
{
    return {
        {IdRole, "tabID"},
        {LabelRole, "label"},
        {SplitVisibleRole, "splitVisible"},
        {SourceIdRole, "sourceID"},
        {TreeFilterRole, "treeFilter"},
        {FilterTextRole, "filterText"},
        {QuickFiltersRole, "quickFilters"},
        {SelectedPacketIdRole, "selectedPacketID"},
        {CaptureModeRole, "captureMode"},
    };
}

QString WorkspaceTabsController::activeCaptureMode() const
{
    if (m_activeTab < 0 || m_activeTab >= m_entries.size())
        return QStringLiteral("packets");
    return m_entries.at(m_activeTab).captureMode;
}

void WorkspaceTabsController::setActiveCaptureMode(const QString &mode)
{
    if (m_activeTab < 0 || m_activeTab >= m_entries.size()
        || m_entries[m_activeTab].captureMode == mode)
        return;
    m_entries[m_activeTab].captureMode = mode;
    const QModelIndex changed = index(m_activeTab);
    emit dataChanged(changed, changed, {CaptureModeRole});
    emit activeCaptureModeChanged();
}

void WorkspaceTabsController::seed(int tabs, bool splitFirst, const QString &captureMode,
                                   const QString &script, int selectTarget)
{
    beginResetModel();
    m_entries.clear();
    m_history.clear();
    m_historyCursor = -1;
    m_nextTabNumber = 0;
    m_activeTab = -1;
    endResetModel();
    emit countChanged();
    emit historyChanged();

    m_nextTabNumber = 0;
    const int seeded = qMax(1, tabs);
    for (int i = 0; i < seeded; ++i) {
        TabEntry entry = makeDefaultEntry();
        entry.captureMode = captureMode;
        entry.splitVisible = splitFirst && i == 0;
        appendEntry(entry);
    }
    setActiveIndex(0);
    m_history.append(m_entries.first().id);
    m_historyCursor = 0;
    emit historyChanged();
    emit stateApplied(0);
    emit activeCaptureModeChanged();

    runScript(script, selectTarget);
}

WorkspaceTabsController::TabEntry WorkspaceTabsController::makeDefaultEntry()
{
    const int number = ++m_nextTabNumber;
    TabEntry entry;
    entry.id = QStringLiteral("tab-%1").arg(number);
    entry.label = QStringLiteral("Capture %1").arg(number);
    if (m_session) {
        entry.sourceID = m_session->currentSourceID();
        entry.treeFilter = m_session->sourceTree()
            ? m_session->sourceTree()->selectedNodeId()
            : QString();
        // ⌘T shows the window's current view: the display filter rides the
        // shared state (quick-filter chips stay per-tab defaults).
        entry.filterText = m_session->filterText();
    }
    return entry;
}

void WorkspaceTabsController::snapshotActive()
{
    if (!m_session || m_activeTab < 0 || m_activeTab >= m_entries.size())
        return;
    TabEntry &entry = m_entries[m_activeTab];
    entry.sourceID = m_session->currentSourceID();
    entry.treeFilter = m_session->sourceTree()
        ? m_session->sourceTree()->selectedNodeId()
        : QString();
    entry.filterText = m_session->filterText();
    const QStringList chips = m_session->quickFilters();
    entry.quickFilters.clear();
    for (const QString &chip : chips)
        entry.quickFilters.append(chip);
    entry.selectedPacketID = m_session->selectedPacketID();
    entry.captureMode = activeCaptureMode();
}

void WorkspaceTabsController::appendEntry(const TabEntry &entry)
{
    const int row = m_entries.size();
    beginInsertRows(QModelIndex(), row, row);
    m_entries.append(entry);
    endInsertRows();
    emit countChanged();
}

void WorkspaceTabsController::applyEntry(int index)
{
    if (!m_session || index < 0 || index >= m_entries.size())
        return;
    const TabEntry entry = m_entries.at(index);
    // Filters first: both resets rebuild the stream and clear the local tree
    // scope, so the scope re-asserts after them.
    m_session->applyFilter(entry.filterText);
    m_session->setQuickFilters(entry.quickFilters);
    const QString target = entryScopeTarget(entry);
    if (!entry.sourceID.isEmpty()
        && entry.sourceID != m_session->currentSourceID()) {
        // The tree scope and selection restore once the source's rows and
        // tree have loaded.
        m_pendingRestoreTries = 0;
        m_pendingRestore = PendingRestore{entry.treeFilter, entry.selectedPacketID};
        m_session->selectSource(entry.sourceID);
    } else {
        m_pendingRestore = PendingRestore{};
        if (m_session->sourceTree()
            && m_session->sourceTree()->selectedNodeId() != target)
            m_session->selectTreeFilter(target);
        if (!entry.selectedPacketID.isEmpty())
            emit restoreSelectionRequested(entry.selectedPacketID);
    }
    emit stateApplied(index);
}

bool WorkspaceTabsController::selectTab(int index)
{
    if (index < 0 || index >= m_entries.size() || index == m_activeTab)
        return false;
    snapshotActive();
    setActiveIndex(index);
    applyEntry(index);
    pushHistory(m_entries.at(index).id);
    return true;
}

void WorkspaceTabsController::setActiveIndex(int index)
{
    if (m_activeTab == index)
        return;
    m_activeTab = index;
    emit activeTabChanged(index);
    emit activeCaptureModeChanged();
}

// Create a tab seeded from the shared workspace (upstream ⌘T shows the
// window's live capture).
void WorkspaceTabsController::newTab()
{
    if (!m_session)
        return;
    TabEntry entry = makeDefaultEntry();
    entry.captureMode = activeCaptureMode();
    snapshotActive();
    appendEntry(entry);
    setActiveIndex(m_entries.size() - 1);
    applyEntry(m_activeTab);
    pushHistory(entry.id);
}

void WorkspaceTabsController::openSourceInNewTab(const QString &nodeID)
{
    if (nodeID.isEmpty())
        return;
    newTab();
    TabEntry &entry = m_entries[m_activeTab];
    entry.treeFilter = nodeID;
    const QModelIndex changed = index(m_activeTab);
    emit dataChanged(changed, changed, {TreeFilterRole});
    m_session->selectTreeFilter(nodeID);
}

bool WorkspaceTabsController::closeTab(int index)
{
    if (index < 0 || index >= m_entries.size())
        return false;
    if (m_entries.size() == 1) {
        // Upstream: closing the last tab closes the window (and its live
        // capture).
        return false;
    }
    const QString closedID = m_entries.at(index).id;
    beginRemoveRows(QModelIndex(), index, index);
    m_entries.removeAt(index);
    endRemoveRows();
    emit countChanged();
    m_history.removeAll(closedID);
    m_historyCursor = qMin(m_historyCursor, m_history.size() - 1);
    emit historyChanged();
    if (m_activeTab >= m_entries.size())
        setActiveIndex(m_entries.size() - 1);
    // Re-apply whatever tab is now active: the shared workspace still shows
    // the closed tab's filters when it was the active one.
    applyEntry(m_activeTab);
    return true;
}

void WorkspaceTabsController::closeOtherTabs(int index)
{
    if (index < 0 || index >= m_entries.size())
        return;
    snapshotActive();
    const TabEntry keeper = m_entries.at(index);
    beginResetModel();
    m_entries.clear();
    m_entries.append(keeper);
    endResetModel();
    emit countChanged();
    m_history = QStringList{keeper.id};
    m_historyCursor = 0;
    setActiveIndex(0);
    emit historyChanged();
    applyEntry(0);
}

void WorkspaceTabsController::closeTabsToRight(int index)
{
    if (index < 0 || index >= m_entries.size() - 1)
        return;
    snapshotActive();
    const int removed = m_entries.size() - (index + 1);
    for (int i = 0; i < removed; ++i) {
        const QString closedID = m_entries.at(m_entries.size() - 1).id;
        beginRemoveRows(QModelIndex(), m_entries.size() - 1, m_entries.size() - 1);
        m_entries.removeLast();
        endRemoveRows();
        m_history.removeAll(closedID);
    }
    emit countChanged();
    m_historyCursor = qMin(m_historyCursor, m_history.size() - 1);
    emit historyChanged();
    if (m_activeTab > index) {
        setActiveIndex(index);
        applyEntry(index);
    }
}

void WorkspaceTabsController::moveTab(int from, int to)
{
    if (from == to || from < 0 || to < 0
        || from >= m_entries.size() || to >= m_entries.size())
        return;
    beginMoveRows(QModelIndex(), from, from, QModelIndex(),
                  to > from ? to + 1 : to);
    m_entries.move(from, to);
    endMoveRows();
    setActiveIndex(to);
}

void WorkspaceTabsController::selectNextTab(int delta)
{
    const int size = m_entries.size();
    if (size < 2)
        return;
    selectTab((m_activeTab + delta + size) % size);
}

void WorkspaceTabsController::historyStep(int delta)
{
    const int cursor = m_historyCursor + delta;
    if (cursor < 0 || cursor >= m_history.size())
        return;
    const QString tabID = m_history.at(cursor);
    int index = -1;
    for (int i = 0; i < m_entries.size(); ++i) {
        if (m_entries.at(i).id == tabID) {
            index = i;
            break;
        }
    }
    if (index < 0 || index == m_activeTab)
        return;
    snapshotActive();
    setActiveIndex(index);
    applyEntry(index);
    m_historyCursor = cursor;
    emit historyChanged();
}

void WorkspaceTabsController::toggleSplit()
{
    if (m_activeTab < 0 || m_activeTab >= m_entries.size())
        return;
    m_entries[m_activeTab].splitVisible = !m_entries[m_activeTab].splitVisible;
    const QModelIndex changed = index(m_activeTab);
    emit dataChanged(changed, changed, {SplitVisibleRole});
}

QString WorkspaceTabsController::tabID(int index) const
{
    if (index < 0 || index >= m_entries.size())
        return {};
    return m_entries.at(index).id;
}

void WorkspaceTabsController::setTabLabel(int row, const QString &label)
{
    if (row < 0 || row >= m_entries.size())
        return;
    m_entries[row].label = label;
    const QModelIndex changed = index(row);
    emit dataChanged(changed, changed, {LabelRole});
}

void WorkspaceTabsController::applyActiveTabFilter(const QString &filter)
{
    if (m_activeTab < 0 || m_activeTab >= m_entries.size())
        return;
    m_entries[m_activeTab].filterText = filter;
    const QModelIndex changed = index(m_activeTab);
    emit dataChanged(changed, changed, {FilterTextRole});
    if (m_session)
        m_session->applyFilter(filter);
}

void WorkspaceTabsController::importIntoNewTab(const QVariantList &files, const QString &label)
{
    newTab();
    TabEntry &entry = m_entries[m_activeTab];
    // A fresh offline tab: no filter carries over from the current view.
    entry.filterText.clear();
    const QModelIndex changed = index(m_activeTab);
    emit dataChanged(changed, changed, {FilterTextRole});
    if (!label.isEmpty())
        setTabLabel(m_activeTab, label);
    if (m_session) {
        m_session->applyFilter(QString());
        m_session->importFiles(files);
    }
}

void WorkspaceTabsController::pushHistory(const QString &tabID)
{
    if (m_historyCursor >= 0 && m_history.at(m_historyCursor) == tabID)
        return;
    QStringList next = m_history.mid(0, m_historyCursor + 1);
    next.append(tabID);
    while (next.size() > 100)
        next.removeFirst();
    m_history = next;
    m_historyCursor = next.size() - 1;
    emit historyChanged();
}

void WorkspaceTabsController::runScript(const QString &script, int selectTarget)
{
    if (script.isEmpty()) {
        if (selectTarget > 0)
            selectTab(qMin(selectTarget, m_entries.size() - 1));
        return;
    }
    const QStringList steps = script.split(QLatin1Char(';'), Qt::SkipEmptyParts);
    for (const QString &stepRaw : steps) {
        const QString step = stepRaw.trimmed();
        if (step == QLatin1String("new")) {
            newTab();
        } else if (step.startsWith(QLatin1String("sel="))) {
            bool ok = false;
            const int index = step.mid(4).toInt(&ok);
            if (ok)
                selectTab(qBound(0, index, m_entries.size() - 1));
        } else if (step.startsWith(QLatin1String("filter="))) {
            if (m_session)
                m_session->applyFilter(step.mid(7));
        } else if (step.startsWith(QLatin1String("mode="))) {
            setActiveCaptureMode(step.mid(5));
        }
    }
    if (selectTarget > 0)
        selectTab(qMin(selectTarget, m_entries.size() - 1));
}

void WorkspaceTabsController::tickPendingRestore()
{
    if (m_pendingRestore.treeFilter.isEmpty() && m_pendingRestore.selectedPacketID.isEmpty())
        return;
    if (m_pendingRestoreTries++ > 40) {
        m_pendingRestore = PendingRestore{};
        return;
    }
    if (!m_session || !m_session->sourceTree())
        return;
    const QString target = m_pendingRestore.treeFilter.isEmpty()
        ? QStringLiteral("all") : m_pendingRestore.treeFilter;
    if (m_session->sourceTree()->selectedNodeId() != target) {
        m_session->selectTreeFilter(target);
        if (m_session->sourceTree()->selectedNodeId() != target)
            return; // The source tree has not loaded the node yet.
    }
    const QString packetID = m_pendingRestore.selectedPacketID;
    m_pendingRestore = PendingRestore{};
    if (!packetID.isEmpty())
        emit restoreSelectionRequested(packetID);
}
