#include "packetmodel.h"
#include "pinstore.h"
#include "savedpacketstore.h"

#include <QtTest>

// C2 pinned sources + saved packets: store rules (upsert dedupe, remove,
// annotation mirroring with backing scope) plus the PacketRow persistence
// round-trip and the packetmodel APIs the Saved workspace rides on.

namespace {

PacketRow sampleRow(quint64 number, const QString &domain)
{
    PacketRow row;
    row.number = number;
    row.packetId = QString::number(number);
    row.timeText = "0.000000";
    row.source = "10.0.0.2";
    row.sourcePort = "44044";
    row.destination = "10.0.0.1";
    row.destinationPort = "80";
    row.protocol = "TCP";
    row.client = "demo";
    row.clientKey = "/usr/bin/demo";
    row.domain = domain;
    row.summary = "HTTP GET /";
    row.length = 74;
    row.originalLength = 74;
    row.timestampMs = 1700000000 + qint64(number);
    return row;
}

} // namespace

class AnnotationStoresTest : public QObject
{
    Q_OBJECT

private slots:
    void pinsUpsertDedupeAndRemove();
    void pinSerializationRoundTrip();
    void savedRecordsDedupeByBackingPair();
    void savedAnnotationMirroring();
    void savedRowPersistenceRoundTrip();
    void packetModelCountForPinScopes();
};

void AnnotationStoresTest::pinsUpsertDedupeAndRemove()
{
    PinStore store;

    PinRecord domain;
    domain.kind = QStringLiteral("domain");
    domain.title = QStringLiteral("example.com");
    domain.domain = QStringLiteral("example.com");
    const PinRecord stored = store.upsert(domain);
    QVERIFY(stored.isValid());
    QCOMPARE(stored.id, QStringLiteral("domain:example.com"));
    QVERIFY(stored.createdAtMs > 0);

    // Upstream PinnedPackets semantics: an identical re-pin is a no-op that
    // keeps the original record.
    PinRecord again = domain;
    again.createdAtMs = 42;
    QCOMPARE(store.upsert(again).createdAtMs, stored.createdAtMs);
    QCOMPARE(store.count(), 1);

    PinRecord ip;
    ip.kind = QStringLiteral("ip");
    ip.title = QStringLiteral("10.0.0.1");
    ip.ip = QStringLiteral("10.0.0.1");
    QVERIFY(store.upsert(ip).isValid());
    QCOMPARE(store.count(), 2);

    // Invalid pins never enter the store.
    PinRecord broken;
    broken.kind = QStringLiteral("domain");
    QCOMPARE(store.upsert(broken).isValid(), false);
    QCOMPARE(store.count(), 2);

    QVERIFY(store.remove(QStringLiteral("domain:example.com")));
    QCOMPARE(store.count(), 1);
    QVERIFY(!store.remove(QStringLiteral("domain:example.com")));
    QCOMPARE(store.find(QStringLiteral("ip:10.0.0.1")).ip, QStringLiteral("10.0.0.1"));
    QCOMPARE(store.find(QStringLiteral("none")).isValid(), false);
}

void AnnotationStoresTest::pinSerializationRoundTrip()
{
    PinStore store;
    PinRecord client;
    client.kind = QStringLiteral("client");
    client.clientKey = QStringLiteral("/usr/bin/curl");
    client.clientDisplay = QStringLiteral("curl");
    client.title = QStringLiteral("curl");
    client.createdAtMs = 123;
    client.id = PinStore::idFor(client.kind, client.clientKey);
    store.upsert(client);

    PinStore reloaded;
    reloaded.loadFromVariantList(store.toVariantList());
    QCOMPARE(reloaded.count(), 1);
    const PinRecord record = reloaded.find(client.id);
    QCOMPARE(record.kind, client.kind);
    QCOMPARE(record.clientKey, client.clientKey);
    QCOMPARE(record.clientDisplay, QStringLiteral("curl"));
    QCOMPARE(record.createdAtMs, 123);

    // Session-document pins decode the daemon wire fields.
    const PinRecord sessionPin = PinStore::fromSessionPin(QVariantMap{
        {QStringLiteral("id"), QStringLiteral("ip:10.0.0.1")},
        {QStringLiteral("kind"), QStringLiteral("ip")},
        {QStringLiteral("title"), QStringLiteral("10.0.0.1")},
        {QStringLiteral("ip"), QStringLiteral("10.0.0.1")},
        {QStringLiteral("created_at"), 1.5},
    });
    QVERIFY(sessionPin.isValid());
    QCOMPARE(sessionPin.ip, QStringLiteral("10.0.0.1"));
    QCOMPARE(sessionPin.createdAtMs, 1500);

    // Document overlay swap replaces the whole list (upstream
    // documentRecords rule while a session source stays open).
    PinRecord swap;
    swap.kind = QStringLiteral("domain");
    swap.domain = QStringLiteral("swapped.example");
    swap.title = swap.domain;
    swap.id = PinStore::idFor(swap.kind, swap.domain);
    store.replaceAll({swap});
    QCOMPARE(store.count(), 1);
    QCOMPARE(store.find(swap.id).domain, QStringLiteral("swapped.example"));
}

void AnnotationStoresTest::savedRecordsDedupeByBackingPair()
{
    SavedPacketStore store;
    QCOMPARE(store.add({sampleRow(1, "example.com")}, QStringLiteral("src-a")), 1);
    // Same id from a different source is a distinct record.
    QCOMPARE(store.add({sampleRow(1, "example.com")}, QStringLiteral("src-b")), 1);
    // Re-saving the same pair keeps one record.
    QCOMPARE(store.add({sampleRow(1, "example.com")}, QStringLiteral("src-a")), 0);
    QCOMPARE(store.count(), 2);

    // Removal targets the first ordered matching id.
    QVERIFY(store.remove(QStringLiteral("1")));
    QCOMPARE(store.count(), 1);
    QVERIFY(store.remove(QStringLiteral("1")));
    QCOMPARE(store.count(), 0);
    QVERIFY(!store.remove(QStringLiteral("1")));
}

void AnnotationStoresTest::savedAnnotationMirroring()
{
    SavedPacketStore store;
    PacketRow row = sampleRow(7, "a.example");
    row.highlightColor = QStringLiteral("orange");
    store.add({row}, QStringLiteral("live-source"));
    store.add({sampleRow(9, "b.example")}, QStringLiteral("other-source"));

    PacketListModel::AnnotationChange strike;
    strike.strikeToggle = true;
    // Backing-scoped mirror: only the active source's copy flips.
    QCOMPARE(store.applyAnnotation({7}, strike, QStringLiteral("live-source")), 1);
    QCOMPARE(store.applyAnnotation({9}, strike, QStringLiteral("live-source")), 0);
    QCOMPARE(store.records().at(0).row.strikethrough, true);
    QCOMPARE(store.records().at(1).row.strikethrough, false);

    // Same ids with no backing scope: everything matching flips.
    PacketListModel::AnnotationChange highlight;
    highlight.hasHighlightChange = true;
    highlight.highlightColorChange = QStringLiteral("blue");
    QCOMPARE(store.applyAnnotation({7, 9}, highlight), 2);

    PacketListModel::AnnotationChange comment;
    comment.hasCommentChange = true;
    comment.commentChange = QStringLiteral("hi");
    QCOMPARE(store.applyAnnotation({7}, comment, QStringLiteral("live-source")), 1);
    QCOMPARE(store.records().at(0).row.comment, QStringLiteral("hi"));
    QCOMPARE(store.records().at(1).row.comment, QString());

    PacketListModel::AnnotationChange reset;
    reset.styleReset = true;
    QCOMPARE(store.applyAnnotation({7, 9}, reset), 2);
    for (const SavedPacketRecord &record : store.records()) {
        QVERIFY(!record.row.strikethrough);
        QVERIFY(record.row.highlightColor.isEmpty());
    }
}

void AnnotationStoresTest::savedRowPersistenceRoundTrip()
{
    PacketRow row = sampleRow(3, "example.com");
    row.comment = QStringLiteral("kept");
    row.highlightColor = QStringLiteral("red");
    row.strikethrough = true;

    const PacketRow restored = packetRowFromMap(packetRowToMap(row));
    QCOMPARE(restored.number, row.number);
    QCOMPARE(restored.packetId, row.packetId);
    QCOMPARE(restored.domain, row.domain);
    QCOMPARE(restored.comment, QStringLiteral("kept"));
    QCOMPARE(restored.highlightColor, QStringLiteral("red"));
    QCOMPARE(restored.strikethrough, true);
    QCOMPARE(restored.timestampMs, row.timestampMs);
    QCOMPARE(restored.length, 74);

    SavedPacketStore store;
    store.add({row}, QStringLiteral("src-1"));
    SavedPacketStore reloaded;
    reloaded.loadFromVariantList(store.toVariantList());
    QCOMPARE(reloaded.count(), 1);
    QCOMPARE(reloaded.records().at(0).packetId, QStringLiteral("3"));
    QCOMPARE(reloaded.records().at(0).backing, QStringLiteral("src-1"));
    QCOMPARE(reloaded.records().at(0).row.comment, QStringLiteral("kept"));
    QCOMPARE(reloaded.records().at(0).row.strikethrough, true);
}

void AnnotationStoresTest::packetModelCountForPinScopes()
{
    // Pin counts mirror the tree bucket scope: every domain packet counts,
    // an IP bucket only takes no-domain packets, and the client scope keys
    // on clientKey. Normalization matches the tree (case/trailing dots).
    PacketListModel model;
    model.loadRows(QVariantList{
        packetRowToMap(sampleRow(1, "a.example")),
        packetRowToMap(sampleRow(2, "A.EXAMPLE.")),
    });

    PacketRow noDomain = sampleRow(3, QString());
    noDomain.source = "10.0.0.4";
    noDomain.destination = "10.0.0.1";
    noDomain.clientKey = "/usr/bin/other";
    noDomain.client = QStringLiteral("");

    model.appendRows({noDomain});

    QCOMPARE(model.countForPin(QStringLiteral("domain"), QStringLiteral("a.example")), 2);
    QCOMPARE(model.countForPin(QStringLiteral("ip"), QStringLiteral("10.0.0.1")), 1);
    QCOMPARE(model.countForPin(QStringLiteral("ip"), QStringLiteral("10.0.0.4")), 1);
    QCOMPARE(model.countForPin(QStringLiteral("ip"), QStringLiteral("10.0.0.2")), 0);
    QCOMPARE(model.countForPin(QStringLiteral("client"), QStringLiteral("/usr/bin/demo")), 2);
    QCOMPARE(model.countForPin(QStringLiteral("client"), QStringLiteral("/usr/bin/other")), 1);
    QCOMPARE(model.countForPin(QStringLiteral("nosuch"), QStringLiteral("x")), 0);
    QCOMPARE(model.countForPin(QStringLiteral("ip"), QString()), 0);

    // loadRows replaces rather than appends (Saved workspace behavior).
    model.loadRows(QVariantList{packetRowToMap(sampleRow(9, "c.example"))});
    QCOMPARE(model.totalCount(), 1);
    QCOMPARE(model.countForPin(QStringLiteral("domain"), QStringLiteral("c.example")), 1);
    QVERIFY(model.revision() > 0);
}

QTEST_MAIN(AnnotationStoresTest)
#include "annotationsstores_test.moc"
