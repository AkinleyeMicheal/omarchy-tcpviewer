#include "packetcopyformatter.h"

#include <QtTest>

namespace {

QVariantMap sampleRow()
{
    return QVariantMap{
        {QStringLiteral("number"), QVariant::fromValue<qulonglong>(7)},
        {QStringLiteral("packetId"), QStringLiteral("p7")},
        {QStringLiteral("timeText"), QStringLiteral("10:04:05.123456")},
        {QStringLiteral("source"), QStringLiteral("127.0.0.1")},
        {QStringLiteral("sourcePort"), QStringLiteral("45012")},
        {QStringLiteral("destination"), QStringLiteral("127.0.0.1")},
        {QStringLiteral("destinationPort"), QStringLiteral("8080")},
        {QStringLiteral("protocol"), QStringLiteral("TCP")},
        {QStringLiteral("client"), QStringLiteral("curl")},
        {QStringLiteral("domain"), QStringLiteral("example.test")},
        {QStringLiteral("length"), 74},
        {QStringLiteral("summary"), QStringLiteral("GET / HTTP/1.1")},
    };
}

} // namespace

class PacketCopyFormatterTest : public QObject
{
    Q_OBJECT

private slots:
    void plainTextFlattensControlCharacters();
    void csvQuotesSpecials();
    void jsonUsesStringFieldsWithUpstreamNames();
    void markdownTableEscapesPipes();
    void csvWithHeaderPrependsTitles();
    void cellsJoinNewlineSeparated();
    void cellForResolvesRolesAndCustomColumns();
};

void PacketCopyFormatterTest::plainTextFlattensControlCharacters()
{
    PacketCopyFormatter formatter;
    QVariantMap row = sampleRow();
    row.insert(QStringLiteral("summary"), QStringLiteral("GET /\tspaced\nline\r\nbreak"));

    QCOMPARE(formatter.rows({row}, QStringLiteral("plainText")),
             QStringLiteral("7\t10:04:05.123456\t127.0.0.1\t127.0.0.1\t"
                            "example.test\tcurl\tTCP\t74\tGET / spaced line break\t"));
}

void PacketCopyFormatterTest::csvQuotesSpecials()
{
    PacketCopyFormatter formatter;
    QVariantMap row = sampleRow();
    row.insert(QStringLiteral("summary"), QStringLiteral("say \"hi\", ok\nnewline"));

    QCOMPARE(formatter.rows({row}, QStringLiteral("csv")),
             QStringLiteral("7,10:04:05.123456,127.0.0.1,127.0.0.1,"
                            "example.test,curl,TCP,74,\"say \"\"hi\"\", ok\nnewline\","));
}

void PacketCopyFormatterTest::jsonUsesStringFieldsWithUpstreamNames()
{
    PacketCopyFormatter formatter;
    const QString json = formatter.rows({sampleRow()}, QStringLiteral("json"));
    const QJsonDocument document = QJsonDocument::fromJson(json.toUtf8());
    QVERIFY(document.isArray());
    QCOMPARE(document.array().size(), 1);
    const QJsonObject object = document.array().first().toObject();
    QCOMPARE(object.value(QStringLiteral("number")).toString(), QStringLiteral("7"));
    QCOMPARE(object.value(QStringLiteral("time")).toString(), QStringLiteral("10:04:05.123456"));
    QCOMPARE(object.value(QStringLiteral("source")).toString(), QStringLiteral("127.0.0.1"));
    QCOMPARE(object.value(QStringLiteral("destination")).toString(), QStringLiteral("127.0.0.1"));
    QCOMPARE(object.value(QStringLiteral("domain")).toString(), QStringLiteral("example.test"));
    QCOMPARE(object.value(QStringLiteral("client")).toString(), QStringLiteral("curl"));
    QCOMPARE(object.value(QStringLiteral("protocol")).toString(), QStringLiteral("TCP"));
    QCOMPARE(object.value(QStringLiteral("length")).toString(), QStringLiteral("74"));
    QCOMPARE(object.value(QStringLiteral("summary")).toString(), QStringLiteral("GET / HTTP/1.1"));
    // Tags are not tracked by the port yet; the copied field stays empty.
    QCOMPARE(object.value(QStringLiteral("tags")).toString(), QString());
    QCOMPARE(object.size(), 10);
}

void PacketCopyFormatterTest::markdownTableEscapesPipes()
{
    PacketCopyFormatter formatter;
    QVariantMap row = sampleRow();
    row.insert(QStringLiteral("summary"), QStringLiteral("a|b \\ c"));

    const QString markdown = formatter.rows({row}, QStringLiteral("markdownTable"));
    const QStringList lines = markdown.split(QLatin1Char('\n'));
    QCOMPARE(lines.size(), 3);
    QVERIFY(lines.at(0).startsWith(QStringLiteral("| # | Time | Source |")));
    QCOMPARE(lines.at(1), QStringLiteral("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"));
    QVERIFY(lines.at(2).contains(QStringLiteral("a\\|b \\\\ c")));
}

void PacketCopyFormatterTest::csvWithHeaderPrependsTitles()
{
    PacketCopyFormatter formatter;
    const QString csv = formatter.rows({sampleRow()}, QStringLiteral("csvWithHeader"));
    const QStringList lines = csv.split(QLatin1Char('\n'));
    QCOMPARE(lines.size(), 2);
    QCOMPARE(lines.first(),
             QStringLiteral("#,Time,Source,Destination,Domain,Client,Protocol,Length,Summary,Tags"));
    QVERIFY(lines.last().startsWith(QStringLiteral("7,10:04:05.123456,")));
}

void PacketCopyFormatterTest::cellsJoinNewlineSeparated()
{
    PacketCopyFormatter formatter;
    QCOMPARE(formatter.cells({QStringLiteral("plain"), QStringLiteral("a,b"), QStringLiteral("c\"d")}),
             QStringLiteral("plain\n\"a,b\"\n\"c\"\"d\""));
}

void PacketCopyFormatterTest::cellForResolvesRolesAndCustomColumns()
{
    PacketCopyFormatter formatter;
    const QVariantMap row = sampleRow();

    QCOMPARE(formatter.cellFor(row,
                 QVariantMap{{QStringLiteral("role"), QStringLiteral("time")}}, {}), QStringLiteral("10:04:05.123456"));
    QCOMPARE(formatter.cellFor(row,
                 QVariantMap{{QStringLiteral("role"), QStringLiteral("number")}}, {}), QStringLiteral("7"));
    QCOMPARE(formatter.cellFor(row,
                 QVariantMap{{QStringLiteral("role"), QStringLiteral("length")}}, {}), QStringLiteral("74"));
    QCOMPARE(formatter.cellFor(
                 QVariantMap{{QStringLiteral("clientPid"), 2468}},
                 QVariantMap{{QStringLiteral("role"), QStringLiteral("clientPid")}}, {}),
             QStringLiteral("2468"));
    QCOMPARE(formatter.cellFor(
                 QVariantMap{{QStringLiteral("clientPid"), 0}},
                 QVariantMap{{QStringLiteral("role"), QStringLiteral("clientPid")}}, {}),
             QString());
    QCOMPARE(formatter.cellFor(row,
                 QVariantMap{{QStringLiteral("role"), QStringLiteral("interface")}}, {}),
             QString());

    // Custom protocol-field columns come through the resolved value.
    QCOMPARE(formatter.cellFor(row,
                 QVariantMap{{QStringLiteral("role"), QStringLiteral("custom")},
                             {QStringLiteral("custom"), true}},
                 QStringLiteral("1 (syn)")),
             QStringLiteral("1 (syn)"));
}

QTEST_GUILESS_MAIN(PacketCopyFormatterTest)
#include "packetcopyformatter_test.moc"
