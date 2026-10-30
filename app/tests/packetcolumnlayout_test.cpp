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

QTEST_GUILESS_MAIN(PacketColumnLayoutTest)
#include "packetcolumnlayout_test.moc"
