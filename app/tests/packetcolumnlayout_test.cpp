#include "packetcolumnlayout.h"

#include <QSettings>
#include <QTemporaryDir>
#include <QtTest>

namespace {

bool menuEntryVisible(const PacketColumnLayout &layout, const QString &identifier)
{
    const QVariantList entries = layout.menuEntries();
    for (const QVariant &value : entries) {
        const QVariantMap entry = value.toMap();
        if (entry.value(QStringLiteral("id")).toString() == identifier)
            return entry.value(QStringLiteral("visible")).toBool();
    }
    return false;
}

// Writes a settings file whose persisted order puts Comment first — a
// malformed layout the loader must correct (Comment pinned last).
QString settingsWithReorderedComment(const QTemporaryDir &directory)
{
    const QString settings = directory.filePath(QStringLiteral("reordered.ini"));
    QSettings store(settings, QSettings::IniFormat);
    store.setValue(QStringLiteral("packetTable/columnLayout"),
                   QStringLiteral(
                       "{\"version\":1,\"columns\":["
                       "{\"identifier\":\"comment\",\"visible\":true,\"width\":220},"
                       "{\"identifier\":\"number\",\"visible\":true,\"width\":60},"
                       "{\"identifier\":\"summary\",\"visible\":true,\"width\":180}]}"));
    store.sync();
    return settings;
}

QStringList columnIDs(const PacketColumnLayout &layout)
{
    QStringList identifiers;
    const QVariantList columns = layout.columns();
    for (const QVariant &value : columns)
        identifiers.append(value.toMap().value(QStringLiteral("id")).toString());
    return identifiers;
}

} // namespace

class PacketColumnLayoutTest : public QObject
{
    Q_OBJECT

private slots:
    void defaultsAndLimits();
    void createsAndReusesCustomColumns();
    void cannotHideTheLastVisibleColumn();
    void persistsVisibilityWidthsAndCustomColumns();
    void ignoresMalformedSettings();
    void reordersVisibleColumnsAndPersistsOrder();
    void keepsCommentPinnedLast();
};

void PacketColumnLayoutTest::defaultsAndLimits()
{
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    PacketColumnLayout layout(nullptr, directory.filePath(QStringLiteral("settings.ini")));

    // Upstream PacketTableColumnService: Comment is a default-visible
    // built-in kept as the flexible trailing column.
    QCOMPARE(layout.visibleCount(), 10);
    QCOMPARE(layout.columns().first().toMap().value(QStringLiteral("id")).toString(),
             QStringLiteral("number"));
    QCOMPARE(layout.columns().last().toMap().value(QStringLiteral("id")).toString(),
             QStringLiteral("comment"));
    QVERIFY(!menuEntryVisible(layout, QStringLiteral("sourcePort")));

    QVERIFY(layout.toggleColumn(QStringLiteral("sourcePort")));
    QCOMPARE(layout.visibleCount(), 11);
    QVERIFY(menuEntryVisible(layout, QStringLiteral("sourcePort")));

    QVERIFY(layout.setColumnWidth(QStringLiteral("source"), 1));
    QCOMPARE(layout.columnWidth(QStringLiteral("source")),
             layout.columnMinimumWidth(QStringLiteral("source")));
    QVERIFY(layout.setColumnWidth(QStringLiteral("source"), 5000));
    QCOMPARE(layout.columnWidth(QStringLiteral("source")), 2000);
}

void PacketColumnLayoutTest::createsAndReusesCustomColumns()
{
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    PacketColumnLayout layout(nullptr, directory.filePath(QStringLiteral("settings.ini")));

    const QString identifier = layout.createCustomColumn(
        QStringLiteral("TCP.FLAGS.STR"), QStringLiteral("TCP Flags"));
    QCOMPARE(identifier, QStringLiteral("custom.field.tcp.flags.str"));
    QCOMPARE(layout.customColumns().size(), 1);
    QVERIFY(menuEntryVisible(layout, identifier));

    const QString duplicate = layout.createCustomColumn(
        QStringLiteral("tcp.flags.str"), QStringLiteral("Duplicate"));
    QCOMPARE(duplicate, identifier);
    QCOMPARE(layout.customColumns().size(), 1);
    QCOMPARE(layout.fieldForColumn(identifier), QStringLiteral("tcp.flags.str"));

    QVERIFY(layout.removeCustomColumn(identifier));
    QVERIFY(layout.customColumns().isEmpty());
}

void PacketColumnLayoutTest::cannotHideTheLastVisibleColumn()
{
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    PacketColumnLayout layout(nullptr, directory.filePath(QStringLiteral("settings.ini")));

    const QVariantList entries = layout.menuEntries();
    for (const QVariant &value : entries) {
        const QVariantMap entry = value.toMap();
        if (entry.value(QStringLiteral("visible")).toBool()
            && entry.value(QStringLiteral("id")).toString() != QStringLiteral("number")) {
            QVERIFY(layout.setColumnVisible(entry.value(QStringLiteral("id")).toString(), false));
        }
    }
    QCOMPARE(layout.visibleCount(), 1);
    QVERIFY(!layout.setColumnVisible(QStringLiteral("number"), false));
    QCOMPARE(layout.visibleCount(), 1);
}

void PacketColumnLayoutTest::persistsVisibilityWidthsAndCustomColumns()
{
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const QString settings = directory.filePath(QStringLiteral("settings.ini"));

    {
        PacketColumnLayout layout(nullptr, settings);
        QVERIFY(layout.toggleColumn(QStringLiteral("tcpFlags")));
        QVERIFY(layout.setColumnWidth(QStringLiteral("summary"), 444));
        const QString custom = layout.createCustomColumn(
            QStringLiteral("tcp.window_size_value"), QStringLiteral("Window"));
        QVERIFY(!custom.isEmpty());
    }

    PacketColumnLayout restored(nullptr, settings);
    QVERIFY(menuEntryVisible(restored, QStringLiteral("tcpFlags")));
    QCOMPARE(restored.columnWidth(QStringLiteral("summary")), 444);
    QCOMPARE(restored.customColumns().size(), 1);
    QCOMPARE(restored.customColumns().first().toMap().value(QStringLiteral("fieldName")).toString(),
             QStringLiteral("tcp.window_size_value"));
    QVERIFY(menuEntryVisible(restored, QStringLiteral("custom.field.tcp.window_size_value")));
}

void PacketColumnLayoutTest::ignoresMalformedSettings()
{
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const QString settings = directory.filePath(QStringLiteral("settings.ini"));
    {
        QSettings store(settings, QSettings::IniFormat);
        store.setValue(QStringLiteral("packetTable/columnLayout"),
                       QStringLiteral("{\"version\":1,\"columns\":\"not-an-array\"}"));
        store.sync();
    }

    PacketColumnLayout layout(nullptr, settings);
    QCOMPARE(layout.visibleCount(), 10);
    QVERIFY(layout.customColumns().isEmpty());
}

void PacketColumnLayoutTest::reordersVisibleColumnsAndPersistsOrder()
{
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const QString settings = directory.filePath(QStringLiteral("settings.ini"));

    {
        PacketColumnLayout layout(nullptr, settings);
        QCOMPARE(columnIDs(layout).first(), QStringLiteral("number"));
        QCOMPARE(columnIDs(layout).last(), QStringLiteral("comment"));

        // Drag Summary to the front (upstream NSTableView column drag).
        QVERIFY(layout.moveColumn(QStringLiteral("summary"), 0));
        QCOMPARE(columnIDs(layout).first(), QStringLiteral("summary"));
        QCOMPARE(layout.visibleCount(), 10);

        // Moving into the same boundary is a no-op.
        QVERIFY(!layout.moveColumn(QStringLiteral("summary"), 0));
        QCOMPARE(columnIDs(layout).first(), QStringLiteral("summary"));

        // Out-of-range boundary and unknown identifiers are rejected.
        QVERIFY(!layout.moveColumn(QStringLiteral("summary"), 12));
        QVERIFY(!layout.moveColumn(QStringLiteral("missing"), 0));
        // Hidden columns cannot be dragged.
        QVERIFY(!layout.moveColumn(QStringLiteral("sourcePort"), 0));

        // Enable Source Port (lands at its catalog slot among visible
        // columns), drag it to the end — right before Comment.
        QVERIFY(layout.toggleColumn(QStringLiteral("sourcePort")));
        QCOMPARE(columnIDs(layout).indexOf(QStringLiteral("sourcePort")), 4);
        QCOMPARE(columnIDs(layout).last(), QStringLiteral("comment"));
        QVERIFY(layout.moveColumn(QStringLiteral("sourcePort"), 9));
        QCOMPARE(columnIDs(layout).last(), QStringLiteral("comment"));
        QCOMPARE(columnIDs(layout).at(columnIDs(layout).size() - 2),
                 QStringLiteral("sourcePort"));
    }

    // The order itself persists across restarts (upstream saves the table's
    // column order in the layout store).
    PacketColumnLayout restored(nullptr, settings);
    QCOMPARE(columnIDs(restored).first(), QStringLiteral("summary"));
    QCOMPARE(columnIDs(restored).last(), QStringLiteral("comment"));
    QCOMPARE(restored.columnWidth(QStringLiteral("summary")), 320);

    // Reset restores the catalog order.
    restored.resetColumns();
    QCOMPARE(columnIDs(restored).first(), QStringLiteral("number"));
}

void PacketColumnLayoutTest::keepsCommentPinnedLast()
{
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    PacketColumnLayout layout(nullptr, settingsWithReorderedComment(directory));

    // A saved layout that tries to move Comment elsewhere is corrected.
    QCOMPARE(columnIDs(layout).last(), QStringLiteral("comment"));
    // Comment cannot be dragged and nothing drops behind it.
    QVERIFY(!layout.moveColumn(QStringLiteral("comment"), 0));
    QVERIFY(!layout.moveColumn(QStringLiteral("number"), 12));
    QCOMPARE(columnIDs(layout).last(), QStringLiteral("comment"));

    // Custom columns are created before the trailing Comment column
    // (upstream setCustomColumns).
    const QString custom = layout.createCustomColumn(
        QStringLiteral("tcp.flag.syn"), QStringLiteral("SYN"));
    QVERIFY(!custom.isEmpty());
    QCOMPARE(columnIDs(layout).last(), QStringLiteral("comment"));
    QCOMPARE(columnIDs(layout).at(columnIDs(layout).size() - 2), custom);
    QVERIFY(layout.removeCustomColumn(custom));
    const QStringList identifiers = columnIDs(layout);
    QVERIFY(!identifiers.contains(custom));
    QCOMPARE(identifiers.last(), QStringLiteral("comment"));
}

QTEST_GUILESS_MAIN(PacketColumnLayoutTest)
#include "packetcolumnlayout_test.moc"