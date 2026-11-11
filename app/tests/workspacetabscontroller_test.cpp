// WorkspaceTabsController state tests: tab CRUD, stable ids, snapshot/apply
// of per-tab workspace state, history, and scripted CI ops.
#include "sessioncontroller.h"
#include "workspacetabscontroller.h"

#include <QTest>

class WorkspaceTabsControllerTest : public QObject
{
    Q_OBJECT

private slots:
    void seedDefaults();
    void seedSplitFirst();
    void newTabAppendsWithStableID();
    void selectTabSnapshotsAndApplies();
    void closeTabRemovesMiddle();
    void closeLastTabKeepsWindowOpen();
    void closeOtherTabsAndToRight();
    void moveTabReordersAndFollows();
    void selectNextTabWraps();
    void historyBackForwardTruncates();
    void setActiveCaptureMode();
    void openSourceInNewTabScopes();
    void toggleSplitPerTab();
    void runScriptSteps();

};


namespace {
QVariant tabData(WorkspaceTabsController &tabs, int row, WorkspaceTabsController::Roles role)
{
    return tabs.data(tabs.index(row), role);
}
} // namespace

void WorkspaceTabsControllerTest::seedDefaults()
{
    // Session without start(): pure state, no daemon traffic.
    SessionController session;
    WorkspaceTabsController tabs;
    tabs.setSession(&session);
    tabs.seed(1, false, QStringLiteral("packets"), QString(), -1);

    QCOMPARE(tabs.count(), 1);
    QCOMPARE(tabs.activeTab(), 0);
    QCOMPARE(tabData(tabs, 0, WorkspaceTabsController::IdRole), QVariant(QStringLiteral("tab-1")));
    QCOMPARE(tabData(tabs, 0, WorkspaceTabsController::LabelRole), QVariant(QStringLiteral("Capture 1")));
    QCOMPARE(tabs.activeCaptureMode(), QStringLiteral("packets"));
    // Single tab: no history, no Back/Forward.
    QVERIFY(!tabs.canBack());
    QVERIFY(!tabs.canForward());
}

void WorkspaceTabsControllerTest::seedSplitFirst()
{
    // Session without start(): pure state, no daemon traffic.
    SessionController session;
    WorkspaceTabsController tabs;
    tabs.setSession(&session);
    tabs.seed(2, true, QStringLiteral("overview"), QString(), -1);

    QCOMPARE(tabs.count(), 2);
    QCOMPARE(tabs.activeCaptureMode(), QStringLiteral("overview"));
    QCOMPARE(tabData(tabs, 0, WorkspaceTabsController::SplitVisibleRole), QVariant(true));
    QCOMPARE(tabData(tabs, 1, WorkspaceTabsController::SplitVisibleRole), QVariant(false));
    // The split seed does not switch tabs: both stay on the seeded mode.
    QCOMPARE(tabData(tabs, 1, WorkspaceTabsController::CaptureModeRole), QVariant(QStringLiteral("overview")));
}

void WorkspaceTabsControllerTest::newTabAppendsWithStableID()
{
    // Session without start(): pure state, no daemon traffic.
    SessionController session;
    WorkspaceTabsController tabs;
    tabs.setSession(&session);
    tabs.seed(1, false, QStringLiteral("packets"), QString(), -1);
    tabs.newTab();

    QCOMPARE(tabs.count(), 2);
    QCOMPARE(tabs.activeTab(), 1);
    QCOMPARE(tabData(tabs, 1, WorkspaceTabsController::IdRole), QVariant(QStringLiteral("tab-2")));
    QCOMPARE(tabData(tabs, 1, WorkspaceTabsController::LabelRole), QVariant(QStringLiteral("Capture 2")));
    // Creating a tab pushes a visit into the history.
    QVERIFY(tabs.canBack());
}

void WorkspaceTabsControllerTest::selectTabSnapshotsAndApplies()
{
    // Session without start(): pure state, no daemon traffic.
    SessionController session;
    WorkspaceTabsController tabs;
    tabs.setSession(&session);
    tabs.seed(1, false, QStringLiteral("packets"), QString(), -1);
    tabs.newTab(); // tab-2 active now

    // Type a filter that belongs to tab-2 only, then walk tabs and confirm
    // each snapshot/apply round trip keeps them independent.
    session.applyFilter(QStringLiteral("tcp"));
    session.setQuickFilters(QVariantList{QStringLiteral("tcp")});
    tabs.selectTab(0);
    QCOMPARE(session.filterText(), QString());
    QCOMPARE(session.quickFilters(), QStringList{});
    tabs.selectTab(1);
    QCOMPARE(session.filterText(), QStringLiteral("tcp"));
    QCOMPARE(session.quickFilters(), QStringList{QStringLiteral("tcp")});
}

void WorkspaceTabsControllerTest::closeTabRemovesMiddle()
{
    // Session without start(): pure state, no daemon traffic.
    SessionController session;
    WorkspaceTabsController tabs;
    tabs.setSession(&session);
    tabs.seed(3, false, QStringLiteral("packets"), QString(), -1);
    // Closing the middle (active tab 0 survives): ids keep their values.

    QVERIFY(tabs.closeTab(1));
    QCOMPARE(tabs.count(), 2);
    QCOMPARE(tabData(tabs, 1, WorkspaceTabsController::IdRole), QVariant(QStringLiteral("tab-3")));
    QVERIFY(!tabs.canBack());
}

void WorkspaceTabsControllerTest::closeLastTabKeepsWindowOpen()
{
    // Session without start(): pure state, no daemon traffic.
    SessionController session;
    WorkspaceTabsController tabs;
    tabs.setSession(&session);
    tabs.seed(1, false, QStringLiteral("packets"), QString(), -1);
    // Upstream: the last close belongs to the window, not the workspace.
    QVERIFY(!tabs.closeTab(0));
    QCOMPARE(tabs.count(), 1);
    QCOMPARE(tabs.activeTab(), 0);
}

void WorkspaceTabsControllerTest::closeOtherTabsAndToRight()
{
    // Session without start(): pure state, no daemon traffic.
    SessionController session;
    WorkspaceTabsController tabs;
    tabs.setSession(&session);
    tabs.seed(3, false, QStringLiteral("packets"), QString(), -1);
    QCOMPARE(tabData(tabs, 2, WorkspaceTabsController::IdRole), QVariant(QStringLiteral("tab-3")));

    tabs.closeOtherTabs(1);
    QCOMPARE(tabs.count(), 1);
    QCOMPARE(tabData(tabs, 0, WorkspaceTabsController::IdRole), QVariant(QStringLiteral("tab-2")));
    QCOMPARE(tabs.activeTab(), 0);
    QCOMPARE(tabs.tabID(0), QStringLiteral("tab-2"));

    // Rebuild and close to the right of the active tab from the far end.
    tabs.seed(3, false, QStringLiteral("packets"), QString(), -1);
    QVERIFY(tabs.selectTab(2));
    tabs.closeTabsToRight(0);
    QCOMPARE(tabs.count(), 1);
    QCOMPARE(tabs.activeTab(), 0);
    QCOMPARE(tabs.tabID(0), QStringLiteral("tab-1"));
}

void WorkspaceTabsControllerTest::moveTabReordersAndFollows()
{
    // Session without start(): pure state, no daemon traffic.
    SessionController session;
    WorkspaceTabsController tabs;
    tabs.setSession(&session);
    tabs.seed(3, false, QStringLiteral("packets"), QString(), -1);
    tabs.moveTab(0, 2);
    QCOMPARE(tabData(tabs, 2, WorkspaceTabsController::IdRole), QVariant(QStringLiteral("tab-1")));
    QCOMPARE(tabData(tabs, 0, WorkspaceTabsController::IdRole), QVariant(QStringLiteral("tab-2")));
    // The moved tab keeps the view, matching the drag interaction.
    QCOMPARE(tabs.activeTab(), 2);
}

void WorkspaceTabsControllerTest::selectNextTabWraps()
{
    // Session without start(): pure state, no daemon traffic.
    SessionController session;
    WorkspaceTabsController tabs;
    tabs.setSession(&session);
    tabs.seed(3, false, QStringLiteral("packets"), QString(), -1);
    tabs.selectNextTab(1);
    QCOMPARE(tabs.activeTab(), 1);
    tabs.selectNextTab(-1);
    QCOMPARE(tabs.activeTab(), 0);
    tabs.selectNextTab(-1);
    QCOMPARE(tabs.activeTab(), 2);
}

void WorkspaceTabsControllerTest::historyBackForwardTruncates()
{
    // Session without start(): pure state, no daemon traffic.
    SessionController session;
    WorkspaceTabsController tabs;
    tabs.setSession(&session);
    tabs.seed(3, false, QStringLiteral("packets"), QString(), -1);
    tabs.selectTab(1);
    tabs.selectTab(2);
    tabs.selectTab(0);
    QVERIFY(tabs.canBack());
    QVERIFY(!tabs.canForward());

    tabs.historyStep(-1); // revisit tab-2 (visited third)
    QCOMPARE(tabs.activeTab(), 2);
    QVERIFY(tabs.canForward());
    tabs.historyStep(-1); // revisit tab-1 (visited second)
    QCOMPARE(tabs.activeTab(), 1);
    // A fresh selection truncates the forward trail like a browser.
    tabs.selectTab(2);
    QVERIFY(!tabs.canForward());
    // The capped trail bounds deeper back walks than upstream needs.
    for (int i = 0; i < 120 && tabs.canBack(); ++i)
        tabs.historyStep(-1);
    QVERIFY(!tabs.canBack());
}

void WorkspaceTabsControllerTest::setActiveCaptureMode()
{
    // Session without start(): pure state, no daemon traffic.
    SessionController session;
    WorkspaceTabsController tabs;
    tabs.setSession(&session);
    tabs.seed(2, false, QStringLiteral("packets"), QString(), -1);
    tabs.selectTab(1);

    tabs.setActiveCaptureMode(QStringLiteral("overview"));
    QCOMPARE(tabs.activeCaptureMode(), QStringLiteral("overview"));
    QCOMPARE(tabData(tabs, 1, WorkspaceTabsController::CaptureModeRole), QVariant(QStringLiteral("overview")));
    // Untouched tab keeps its own view.
    QCOMPARE(tabData(tabs, 0, WorkspaceTabsController::CaptureModeRole), QVariant(QStringLiteral("packets")));
}

void WorkspaceTabsControllerTest::openSourceInNewTabScopes()
{
    // Session without start(): pure state, no daemon traffic.
    SessionController session;
    WorkspaceTabsController tabs;
    tabs.setSession(&session);
    tabs.seed(1, false, QStringLiteral("packets"), QString(), -1);
    tabs.openSourceInNewTab(QStringLiteral("app:/usr/bin/web"));

    QCOMPARE(tabs.count(), 2);
    QCOMPARE(tabs.activeTab(), 1);
    QCOMPARE(tabData(tabs, 1, WorkspaceTabsController::TreeFilterRole), QVariant(QStringLiteral("app:/usr/bin/web")));
    // An empty target is refused silently.
    tabs.openSourceInNewTab(QString());
    QCOMPARE(tabs.count(), 2);
}

void WorkspaceTabsControllerTest::toggleSplitPerTab()
{
    // Session without start(): pure state, no daemon traffic.
    SessionController session;
    WorkspaceTabsController tabs;
    tabs.setSession(&session);
    tabs.seed(2, false, QStringLiteral("packets"), QString(), -1);
    tabs.selectTab(1);
    tabs.toggleSplit();
    QCOMPARE(tabData(tabs, 1, WorkspaceTabsController::SplitVisibleRole), QVariant(true));
    tabs.selectTab(0);
    tabs.toggleSplit();
    QCOMPARE(tabData(tabs, 0, WorkspaceTabsController::SplitVisibleRole), QVariant(true));
    // Split state is per tab: tab two's split survives tab one's toggle.
    QCOMPARE(tabData(tabs, 1, WorkspaceTabsController::SplitVisibleRole), QVariant(true));
}

void WorkspaceTabsControllerTest::runScriptSteps()
{
    // Session without start(): pure state, no daemon traffic.
    SessionController session;
    WorkspaceTabsController tabs;
    tabs.setSession(&session);
    tabs.seed(1, false, QStringLiteral("packets"),
              QStringLiteral("new;mode=packets;sel=0"), -1);
    QCOMPARE(tabs.count(), 2);
    QCOMPARE(tabs.activeTab(), 0);
    QCOMPARE(tabs.activeCaptureMode(), QStringLiteral("packets"));
    // The scripted filter step reaches the session like user input.
    SessionController session2;
    WorkspaceTabsController scripted;
    scripted.setSession(&session2);
    scripted.seed(1, false, QStringLiteral("packets"),
                  QStringLiteral("new;filter=tcp"), -1);
    QCOMPARE(session2.filterText(), QStringLiteral("tcp"));
    QCOMPARE(scripted.activeTab(), 1);
}

QTEST_MAIN(WorkspaceTabsControllerTest)
#include "workspacetabscontroller_test.moc"
