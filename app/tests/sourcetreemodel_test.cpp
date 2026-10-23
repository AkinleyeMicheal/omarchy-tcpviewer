#include "packetmodel.h"
#include "sourcetreemodel.h"

#include <QAbstractItemModel>
#include <QSignalSpy>
#include <QtTest>

namespace {

PacketRow makeRow(quint64 number, const QString &client, const QString &clientKey,
                  const QString &domain, const QString &source, const QString &destination)
{
    PacketRow row;
    row.number = number;
    row.packetId = QString::number(number);
    row.client = client;
    row.clientKey = clientKey;
    row.domain = domain;
    row.source = source;
    row.destination = destination;
    row.protocol = QStringLiteral("TCP");
    row.summary = QStringLiteral("summary");
    return row;
}

int findNode(const SourceTreeModel &model, const QString &id)
{
    for (int row = 0; row < model.rowCount(); ++row) {
        const QModelIndex index = model.index(row, 0);
        if (model.data(index, SourceTreeModel::NodeIdRole).toString() == id)
            return row;
    }
    return -1;
}

int nodeCount(const SourceTreeModel &model, const QString &id)
{
    const int row = findNode(model, id);
    if (row < 0)
        return -1;
    return model.data(model.index(row, 0), SourceTreeModel::CountRole).toInt();
}

} // namespace

class SourceTreeModelTest : public QObject
{
    Q_OBJECT

private slots:
    void countsAndHierarchy();
    void nodeFilters();
    void packetModelFiltering();
    void countOnlyRefreshDoesNotReset();
    void resetClearsTree();
};

void SourceTreeModelTest::countsAndHierarchy()
{
    SourceTreeModel tree;
    tree.appendRows({
        makeRow(1, QStringLiteral("curl"), QStringLiteral("/usr/bin/curl"),
                QStringLiteral("example.com"), QStringLiteral("10.0.0.2"), QStringLiteral("93.184.216.34")),
        makeRow(2, QStringLiteral("curl"), QStringLiteral("/usr/bin/curl"),
                QString(), QStringLiteral("10.0.0.2"), QStringLiteral("1.1.1.1")),
        makeRow(3, QStringLiteral("firefox"), QStringLiteral("/usr/bin/firefox"),
                QString(), QStringLiteral("10.0.0.2"), QStringLiteral("8.8.8.8")),
        makeRow(4, QString(), QString(),
                QString(), QStringLiteral("10.0.0.2"), QStringLiteral("9.9.9.9")),
    });
    tree.rebuildNow();

    QCOMPARE(nodeCount(tree, QStringLiteral("all")), 4);
    QCOMPARE(nodeCount(tree, QStringLiteral("folder:apps")), 3);
    QCOMPARE(nodeCount(tree, QStringLiteral("folder:domains")), 4);
    QCOMPARE(nodeCount(tree, QStringLiteral("app:/usr/bin/curl")), 2);
    QCOMPARE(nodeCount(tree, QStringLiteral("app:/usr/bin/firefox")), 1);
    QCOMPARE(nodeCount(tree, QStringLiteral("domain:example.com")), 1);
    QCOMPARE(nodeCount(tree, QStringLiteral("domain:")), 3);

    // Apps and Domains folders start expanded; app rows and IP Addresses do not.
    QVERIFY(findNode(tree, QStringLiteral("app:/usr/bin/curl")) >= 0);
    QVERIFY(findNode(tree, QStringLiteral("app-domain:/usr/bin/curl:example.com")) < 0);

    tree.toggleExpanded(QStringLiteral("app:/usr/bin/curl"));
    QCOMPARE(nodeCount(tree, QStringLiteral("app-domain:/usr/bin/curl:example.com")), 1);
    QCOMPARE(nodeCount(tree, QStringLiteral("app-domain:/usr/bin/curl:")), 1);

    tree.toggleExpanded(QStringLiteral("app-domain:/usr/bin/curl:"));
    QCOMPARE(nodeCount(tree, QStringLiteral("app-ip:/usr/bin/curl:1.1.1.1")), 1);
    QCOMPARE(nodeCount(tree, QStringLiteral("app-ip:/usr/bin/curl:10.0.0.2")), 1);

    QVERIFY(findNode(tree, QStringLiteral("ip:8.8.8.8")) < 0);
    tree.toggleExpanded(QStringLiteral("domain:"));
    QCOMPARE(nodeCount(tree, QStringLiteral("ip:10.0.0.2")), 3);
    QCOMPARE(nodeCount(tree, QStringLiteral("ip:8.8.8.8")), 1);
}

void SourceTreeModelTest::nodeFilters()
{
    SourceTreeModel tree;
    tree.appendRows({
        makeRow(1, QStringLiteral("curl"), QStringLiteral("/usr/bin/curl"),
                QStringLiteral("example.com"), QStringLiteral("10.0.0.2"), QStringLiteral("93.184.216.34")),
        makeRow(2, QStringLiteral("curl"), QStringLiteral("/usr/bin/curl"),
                QString(), QStringLiteral("10.0.0.2"), QStringLiteral("1.1.1.1")),
    });
    tree.rebuildNow();
    tree.toggleExpanded(QStringLiteral("app:/usr/bin/curl"));
    tree.toggleExpanded(QStringLiteral("app-domain:/usr/bin/curl:"));
    tree.toggleExpanded(QStringLiteral("domain:"));

    PacketTreeFilter all = tree.filterForNode(QStringLiteral("all"));
    QVERIFY(all.valid);
    QVERIFY(!all.active);

    PacketTreeFilter apps = tree.filterForNode(QStringLiteral("folder:apps"));
    QVERIFY(apps.valid);
    QVERIFY(apps.active);
    QVERIFY(apps.appsOnly);

    PacketTreeFilter app = tree.filterForNode(QStringLiteral("app:/usr/bin/curl"));
    QVERIFY(app.active);
    QCOMPARE(app.appKey, QStringLiteral("/usr/bin/curl"));

    PacketTreeFilter appDomain = tree.filterForNode(QStringLiteral("app-domain:/usr/bin/curl:"));
    QVERIFY(appDomain.active);
    QCOMPARE(appDomain.appKey, QStringLiteral("/usr/bin/curl"));
    QVERIFY(appDomain.missingDomain);

    PacketTreeFilter ip = tree.filterForNode(QStringLiteral("ip:1.1.1.1"));
    QVERIFY(ip.active);
    QCOMPARE(ip.ip, QStringLiteral("1.1.1.1"));
    QVERIFY(ip.missingDomain);

    tree.selectNode(QStringLiteral("app:/usr/bin/curl"));
    QCOMPARE(tree.selectedNodeId(), QStringLiteral("app:/usr/bin/curl"));
    QVERIFY(!tree.filterForNode(QStringLiteral("does-not-exist")).valid);
}

void SourceTreeModelTest::packetModelFiltering()
{
    PacketListModel model;
    model.appendRows({
        makeRow(1, QStringLiteral("curl"), QStringLiteral("/usr/bin/curl"),
                QStringLiteral("example.com"), QStringLiteral("10.0.0.2"), QStringLiteral("93.184.216.34")),
        makeRow(2, QStringLiteral("curl"), QStringLiteral("/usr/bin/curl"),
                QString(), QStringLiteral("10.0.0.2"), QStringLiteral("1.1.1.1")),
        makeRow(3, QStringLiteral("firefox"), QStringLiteral("/usr/bin/firefox"),
                QString(), QStringLiteral("10.0.0.2"), QStringLiteral("8.8.8.8")),
        makeRow(4, QString(), QString(),
                QString(), QStringLiteral("10.0.0.2"), QStringLiteral("9.9.9.9")),
    });

    QCOMPARE(model.count(), 4);
    QCOMPARE(model.totalCount(), 4);

    model.setTreeFilter(QStringLiteral("/usr/bin/curl"), {}, {}, false, false);
    QCOMPARE(model.count(), 2);
    QCOMPARE(model.totalCount(), 4);
    QCOMPARE(model.packetIDAt(0), QStringLiteral("1"));
    QCOMPARE(model.packetIDAt(1), QStringLiteral("2"));

    model.setTreeFilter(QStringLiteral("/usr/bin/curl"), {}, {}, false, true);
    QCOMPARE(model.count(), 1);
    QCOMPARE(model.packetIDAt(0), QStringLiteral("2"));

    model.setTreeFilter({}, {}, QStringLiteral("1.1.1.1"), false, true);
    QCOMPARE(model.count(), 1);
    QCOMPARE(model.packetIDAt(0), QStringLiteral("2"));

    model.setTreeFilter({}, QStringLiteral("example.com"), {}, false, false);
    QCOMPARE(model.count(), 1);
    QCOMPARE(model.packetIDAt(0), QStringLiteral("1"));

    model.setTreeFilter({}, {}, {}, true, false);
    QCOMPARE(model.count(), 3);

    model.appendRows({
        makeRow(5, QStringLiteral("curl"), QStringLiteral("/usr/bin/curl"),
                QString(), QStringLiteral("10.0.0.2"), QStringLiteral("1.1.1.1")),
    });
    QCOMPARE(model.count(), 4);
    QCOMPARE(model.totalCount(), 5);

    model.clearTreeFilter();
    QCOMPARE(model.count(), 5);
    QCOMPARE(model.packetIDAt(4), QStringLiteral("5"));
}

void SourceTreeModelTest::countOnlyRefreshDoesNotReset()
{
    SourceTreeModel tree;
    tree.appendRows({
        makeRow(1, QStringLiteral("curl"), QStringLiteral("/usr/bin/curl"),
                QStringLiteral("example.com"), QStringLiteral("10.0.0.2"), QStringLiteral("93.184.216.34")),
    });
    tree.rebuildNow();

    QSignalSpy resetSpy(&tree, &QAbstractItemModel::modelReset);
    QSignalSpy dataSpy(&tree, &QAbstractItemModel::dataChanged);
    tree.appendRows({
        makeRow(2, QStringLiteral("curl"), QStringLiteral("/usr/bin/curl"),
                QStringLiteral("example.com"), QStringLiteral("10.0.0.2"), QStringLiteral("93.184.216.34")),
    });
    tree.rebuildNow();

    QCOMPARE(resetSpy.count(), 0);
    QVERIFY(dataSpy.count() >= 1);
    QCOMPARE(nodeCount(tree, QStringLiteral("app:/usr/bin/curl")), 2);
    QCOMPARE(nodeCount(tree, QStringLiteral("domain:example.com")), 2);
}

void SourceTreeModelTest::resetClearsTree()
{
    SourceTreeModel tree;
    tree.appendRows({
        makeRow(1, QStringLiteral("curl"), QStringLiteral("/usr/bin/curl"),
                QStringLiteral("example.com"), QStringLiteral("10.0.0.2"), QStringLiteral("93.184.216.34")),
    });
    tree.rebuildNow();
    QCOMPARE(tree.count(), 5); // All, Apps, app, Domains, domain.

    tree.reset();
    QCOMPARE(tree.count(), 1);
    QCOMPARE(tree.selectedNodeId(), QStringLiteral("all"));
    QCOMPARE(nodeCount(tree, QStringLiteral("all")), 0);
}

QTEST_GUILESS_MAIN(SourceTreeModelTest)
#include "sourcetreemodel_test.moc"
