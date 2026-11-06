#include "endpointstatsmodel.h"
#include "packetmodel.h"

#include <QtTest>

namespace {

QVariantMap packetRow(quint64 number, const QString &source, const QString &sourcePort,
                      const QString &destination, const QString &destinationPort,
                      const QString &protocol, qint64 length, const QString &direction,
                      const QString &client, const QString &clientKey, const QString &domain)
{
    QVariantMap map;
    map.insert(QStringLiteral("number"), number);
    map.insert(QStringLiteral("packetId"), QStringLiteral("p%1").arg(number));
    map.insert(QStringLiteral("source"), source);
    map.insert(QStringLiteral("sourcePort"), sourcePort);
    map.insert(QStringLiteral("destination"), destination);
    map.insert(QStringLiteral("destinationPort"), destinationPort);
    map.insert(QStringLiteral("protocol"), protocol);
    map.insert(QStringLiteral("originalLength"), length);
    map.insert(QStringLiteral("length"), length);
    map.insert(QStringLiteral("direction"), direction);
    map.insert(QStringLiteral("client"), client);
    map.insert(QStringLiteral("clientKey"), clientKey);
    map.insert(QStringLiteral("domain"), domain);
    return map;
}

// Three packets: two outbound TCP handshakes from one process to one server
// plus one inbound DNS reply.
QVariantList basicRows()
{
    return {
        packetRow(1, QStringLiteral("10.0.0.1"), QStringLiteral("52000"),
                  QStringLiteral("10.9.0.1"), QStringLiteral("443"),
                  QStringLiteral("TCP"), 100, QStringLiteral("outbound"),
                  QStringLiteral("Web"), QStringLiteral("/usr/bin/web"),
                  QStringLiteral("Example.com")),
        packetRow(2, QStringLiteral("10.0.0.1"), QStringLiteral("52001"),
                  QStringLiteral("10.9.0.1"), QStringLiteral("443"),
                  QStringLiteral("TCP"), 50, QStringLiteral("outbound"),
                  QStringLiteral("Web"), QStringLiteral("/usr/bin/web"),
                  QStringLiteral("example.com")),
        packetRow(3, QStringLiteral("10.9.0.2"), QStringLiteral("53"),
                  QStringLiteral("10.0.0.1"), QStringLiteral("5300"),
                  QStringLiteral("DNS"), 200, QStringLiteral("inbound"),
                  QString(), QString(), QString()),
    };
}

void load(PacketListModel &model, const QVariantList &rows)
{
    model.loadRows(rows);
}

} // namespace

class EndpointStatisticsModelTest : public QObject
{
    Q_OBJECT

private slots:
    void rebuildBucketsDirectionally();
    void appsGroupByKeyNotDisplayName();
    void searchFiltersAllGroups();
    void defaultSortIsBusiestFirst();
    void clickSortTogglesAndMatchesAppKitPrototype();
    void portSortIsNumeric();
    void csvExportProtectsFormulasAndUsesCrlf();
    void jsonExportUsesSnakeCaseKeys();
    void joinedValuesDeduplicateAndSkipPlaceholders();
    void relatedScopeMapsSidebarNodesAndFilters();
    void columnDefaultsMatchUpstream();

private:
    static QString text(const EndpointStatisticsModel &stats, int row, int column);
};

QString EndpointStatisticsModelTest::text(const EndpointStatisticsModel &stats, int row,
                                          int column)
{
    const QModelIndex index = stats.index(row, column);
    return stats.data(index, Qt::UserRole + 1 + column).toString();
}

void EndpointStatisticsModelTest::rebuildBucketsDirectionally()
{
    PacketListModel model;
    load(model, basicRows());

    EndpointStatisticsModel stats;
    stats.setGroup(EndpointStatisticsModel::Ipv4);
    stats.rebuild(&model);

    QCOMPARE(stats.count(), 3);
    QCOMPARE(stats.groupCounts().at(EndpointStatisticsModel::Ipv4).toInt(), 3);

    // Each side of a packet counts once (2 sides of 3 packets = 6, minus the
    // loopback-free fixture where no packet repeats an address = 6). The
    // footer sums one packet per side appearance: 88 was the fixture number;
    // here 3 + 2 + 1 = 6 packets and 700 bytes.
    QCOMPARE(text(stats, 0, 0), QStringLiteral("10.0.0.1")); // busiest first
    QCOMPARE(text(stats, 0, 5), QStringLiteral("3"));
    QCOMPARE(text(stats, 0, 6), QStringLiteral("350"));
    QCOMPARE(text(stats, 0, 7), QStringLiteral("2")); // tx packets
    QCOMPARE(text(stats, 0, 8), QStringLiteral("150"));
    QCOMPARE(text(stats, 0, 9), QStringLiteral("1")); // rx packets
    QCOMPARE(text(stats, 0, 10), QStringLiteral("200"));
    // 150/350 -> 43%, 200/350 -> 57% (upstream rounding).
    QCOMPARE(text(stats, 0, 11), QStringLiteral("Tx 43% · Rx 57%"));

    // TCP group keys are address:port pairs. The DNS reply is UDP, so the
    // TCP group holds three buckets; the 150 B server bucket leads.
    stats.setGroup(EndpointStatisticsModel::Tcp);
    QCOMPARE(stats.count(), 3);
    QCOMPARE(stats.keyAt(0), QStringLiteral("10.9.0.1:443"));
    QCOMPARE(stats.keyAt(1), QStringLiteral("10.0.0.1:52000"));
    QCOMPARE(stats.keyAt(2), QStringLiteral("10.0.0.1:52001"));
}

void EndpointStatisticsModelTest::appsGroupByKeyNotDisplayName()
{
    QVariantList rows = basicRows();
    // Same display name as /usr/bin/web but a different executable identity:
    // upstream splits the row by PacketSourceClientKey.
    rows << packetRow(4, QStringLiteral("10.0.0.1"), QStringLiteral("52002"),
                      QStringLiteral("10.9.0.1"), QStringLiteral("443"),
                      QStringLiteral("TCP"), 10, QStringLiteral("outbound"),
                      QStringLiteral("Web"), QStringLiteral("/opt/web"),
                      QStringLiteral("example.com"));

    PacketListModel model;
    load(model, rows);

    EndpointStatisticsModel stats;
    stats.setGroup(EndpointStatisticsModel::Apps);
    stats.rebuild(&model);

    QCOMPARE(stats.count(), 2);
    // Busiest first: /usr/bin/web (150 B) before /opt/web (10 B).
    QCOMPARE(stats.keyAt(0), QStringLiteral("/usr/bin/web"));
    QCOMPARE(stats.keyAt(1), QStringLiteral("/opt/web"));
    // The Client column keeps the display name.
    QCOMPARE(text(stats, 0, 3), QStringLiteral("Web"));
}

void EndpointStatisticsModelTest::searchFiltersAllGroups()
{
    PacketListModel model;
    load(model, basicRows());

    EndpointStatisticsModel stats;
    stats.setGroup(EndpointStatisticsModel::Tcp);
    stats.rebuild(&model);
    QCOMPARE(stats.count(), 3);

    // Ports search as text.
    stats.setSearchText(QStringLiteral("443"));
    QCOMPARE(stats.count(), 1);
    QCOMPARE(stats.keyAt(0), QStringLiteral("10.9.0.1:443"));

    // Multiple terms are AND-ed over key + address + port + protocol +
    // client + domain.
    stats.setSearchText(QStringLiteral("10.0 52000"));
    QCOMPARE(stats.count(), 1);
    QCOMPARE(stats.keyAt(0), QStringLiteral("10.0.0.1:52000"));

    // No match empties the view; the footer shrinks with it.
    stats.setSearchText(QStringLiteral("nosuchendpoint"));
    QCOMPARE(stats.count(), 0);
    QCOMPARE(stats.footerText(), QStringLiteral("0 endpoints · 0 packets"));

    // Clearing restores the full set (explicit empty string).
    stats.setSearchText(QString());
    QCOMPARE(stats.count(), 3);

    // The search spans the app identity key (executable path).
    stats.setGroup(EndpointStatisticsModel::Apps);
    stats.setSearchText(QStringLiteral("/usr/bin"));
    QCOMPARE(stats.count(), 1);
    QCOMPARE(stats.keyAt(0), QStringLiteral("/usr/bin/web"));
}

void EndpointStatisticsModelTest::defaultSortIsBusiestFirst()
{
    PacketListModel model;
    load(model, basicRows());

    EndpointStatisticsModel stats;
    stats.setGroup(EndpointStatisticsModel::Ipv4);
    stats.rebuild(&model);

    QCOMPARE(stats.sortColumn(), EndpointStatisticsModel::Bytes);
    QVERIFY(!stats.sortAscending());
    QCOMPARE(text(stats, 0, 6), QStringLiteral("350"));
    QCOMPARE(text(stats, 1, 6), QStringLiteral("200"));
    QCOMPARE(text(stats, 2, 6), QStringLiteral("150"));
}

void EndpointStatisticsModelTest::clickSortTogglesAndMatchesAppKitPrototype()
{
    PacketListModel model;
    load(model, basicRows());

    EndpointStatisticsModel stats;
    stats.setGroup(EndpointStatisticsModel::Ipv4);
    stats.rebuild(&model);

    // Text columns start ascending (AppKit sortDescriptorPrototype).
    stats.clickSort(EndpointStatisticsModel::Address);
    QVERIFY(stats.sortAscending());
    QCOMPARE(text(stats, 0, 0), QStringLiteral("10.0.0.1"));
    QCOMPARE(text(stats, 1, 0), QStringLiteral("10.9.0.1"));
    QCOMPARE(text(stats, 2, 0), QStringLiteral("10.9.0.2"));

    // Same column toggles direction.
    stats.clickSort(EndpointStatisticsModel::Address);
    QVERIFY(!stats.sortAscending());
    QCOMPARE(text(stats, 0, 0), QStringLiteral("10.9.0.2"));

    // Numeric columns start descending.
    stats.clickSort(EndpointStatisticsModel::Packets);
    QVERIFY(!stats.sortAscending());
    QCOMPARE(text(stats, 0, 5), QStringLiteral("3"));

    // Sort state is per group: IPv4 keeps Packets desc, TCP still defaults.
    stats.setGroup(EndpointStatisticsModel::Tcp);
    QCOMPARE(stats.sortColumn(), EndpointStatisticsModel::Bytes);
    QVERIFY(!stats.sortAscending());
}

void EndpointStatisticsModelTest::portSortIsNumeric()
{
    QVariantList rows;
    rows << packetRow(1, QStringLiteral("10.0.0.1"), QStringLiteral("52000"),
                      QStringLiteral("10.9.0.1"), QStringLiteral("9"),
                      QStringLiteral("TCP"), 10, QStringLiteral("outbound"),
                      QString(), QString(), QString());
    rows << packetRow(2, QStringLiteral("10.0.0.1"), QStringLiteral("52001"),
                      QStringLiteral("10.9.0.2"), QStringLiteral("80"),
                      QStringLiteral("TCP"), 20, QStringLiteral("outbound"),
                      QString(), QString(), QString());
    rows << packetRow(3, QStringLiteral("10.0.0.1"), QStringLiteral("52002"),
                      QStringLiteral("10.9.0.3"), QStringLiteral("443"),
                      QStringLiteral("TCP"), 30, QStringLiteral("outbound"),
                      QString(), QString(), QString());

    PacketListModel model;
    load(model, rows);

    EndpointStatisticsModel stats;
    stats.setGroup(EndpointStatisticsModel::Tcp);
    stats.rebuild(&model);

    // First click on Port: ascending, numerically (a string sort would put
    // "443" before "80" and "9" — the numeric branch wins).
    stats.clickSort(EndpointStatisticsModel::Port);
    QVERIFY(stats.sortAscending());
    QCOMPARE(stats.keyAt(0), QStringLiteral("10.9.0.1:9"));
    QCOMPARE(stats.keyAt(1), QStringLiteral("10.9.0.2:80"));
    QCOMPARE(stats.keyAt(2), QStringLiteral("10.9.0.3:443"));
}

void EndpointStatisticsModelTest::csvExportProtectsFormulasAndUsesCrlf()
{
    QVariantList rows;
    rows << packetRow(1, QStringLiteral("10.0.0.1"), QStringLiteral("52000"),
                      QStringLiteral("10.9.0.1"), QStringLiteral("443"),
                      QStringLiteral("TCP"), 100, QStringLiteral("outbound"),
                      QString(), QString(), QStringLiteral("=SUM(A1)"));
    rows << packetRow(2, QStringLiteral("10.0.0.1"), QStringLiteral("52000"),
                      QStringLiteral("10.9.0.2"), QStringLiteral("80"),
                      QStringLiteral("TCP"), 50, QStringLiteral("outbound"),
                      QString(), QString(), QStringLiteral("a,b"));

    PacketListModel model;
    load(model, rows);

    EndpointStatisticsModel stats;
    stats.setGroup(EndpointStatisticsModel::Ipv4);
    stats.rebuild(&model);

    // One packet per server bucket (10.9.0.1 with 100 B, 10.9.0.2 with
    // 50 B), busiest first after the 150 B client aggregate. Non-numeric
    // fields get formula protection: a leading "=" gets an apostrophe, a
    // comma gets quoting. CRLF row joins.
    const QStringList keys {stats.keyAt(1), stats.keyAt(2)};
    QCOMPARE(stats.keyAt(0), QStringLiteral("10.0.0.1"));
    QCOMPARE(stats.keyAt(1), QStringLiteral("10.9.0.1"));
    QCOMPARE(stats.keyAt(2), QStringLiteral("10.9.0.2"));
    const QString csv = stats.rowsAsCsv(keys, {0, 4, 6});
    QCOMPARE(csv, QStringLiteral(
        "Address,Domain,Bytes\r\n"
        "10.9.0.1,'=SUM(A1),100\r\n"
        "10.9.0.2,\"a,b\",50"));
}

void EndpointStatisticsModelTest::jsonExportUsesSnakeCaseKeys()
{
    PacketListModel model;
    load(model, basicRows());

    EndpointStatisticsModel stats;
    stats.setGroup(EndpointStatisticsModel::Ipv4);
    stats.rebuild(&model);

    const QString json = stats.rowsAsJson({stats.keyAt(1)}, {0, 5, 6, 11});
    QCOMPARE(json, QStringLiteral(
        "[\n  {\n    \"address\": \"10.9.0.2\",\n    \"packets\": 1,"
        "\n    \"bytes\": 200,\n    \"summary\": \"Tx 100%\"\n  }\n]"));
}

void EndpointStatisticsModelTest::joinedValuesDeduplicateAndSkipPlaceholders()
{
    QVariantList rows = basicRows();
    // A second client behind the same server endpoint turns the TCP bucket's
    // Client cell into "Multiple", which the semantic copy must skip.
    rows << packetRow(4, QStringLiteral("10.0.0.2"), QStringLiteral("52100"),
                      QStringLiteral("10.9.0.1"), QStringLiteral("443"),
                      QStringLiteral("TCP"), 10, QStringLiteral("outbound"),
                      QStringLiteral("Other"), QString(), QString());

    PacketListModel model;
    load(model, rows);

    EndpointStatisticsModel stats;
    stats.setGroup(EndpointStatisticsModel::Tcp);
    stats.rebuild(&model);

    // Client across the two 10.0.0.x client rows dedupes to one line; the
    // "Multiple" server bucket contributes nothing.
    const QStringList keys {QStringLiteral("10.0.0.1:52000"),
                            QStringLiteral("10.0.0.1:52001"),
                            QStringLiteral("10.9.0.1:443")};
    QCOMPARE(stats.joinedValues(keys, 2), QStringLiteral("Web"));
    // Addresses join one per line, in the requested order.
    QCOMPARE(stats.joinedValues({QStringLiteral("10.0.0.1:52000"),
                                 QStringLiteral("10.9.0.1:443")}, 0),
             QStringLiteral("10.0.0.1\n10.9.0.1"));
}

void EndpointStatisticsModelTest::relatedScopeMapsSidebarNodesAndFilters()
{
    PacketListModel model;
    load(model, basicRows());

    EndpointStatisticsModel stats;
    stats.rebuild(&model);

    stats.setGroup(EndpointStatisticsModel::Apps);
    QVariantMap scope = stats.relatedScope(QStringLiteral("/usr/bin/web"));
    QCOMPARE(scope.value(QStringLiteral("nodeId")).toString(),
             QStringLiteral("app:/usr/bin/web"));

    stats.setGroup(EndpointStatisticsModel::Domains);
    // Domain keys normalize (lowercase) to match the sidebar node ids.
    scope = stats.relatedScope(QStringLiteral("Example.com"));
    QCOMPARE(scope.value(QStringLiteral("nodeId")).toString(),
             QStringLiteral("domain:example.com"));

    stats.setGroup(EndpointStatisticsModel::Ipv4);
    scope = stats.relatedScope(QStringLiteral("10.9.0.1"));
    QCOMPARE(scope.value(QStringLiteral("nodeId")).toString(), QStringLiteral("ip:10.9.0.1"));
    QVERIFY(!scope.contains(QStringLiteral("filter")));

    // Transport rows scope All Packets plus an exact display filter.
    stats.setGroup(EndpointStatisticsModel::Tcp);
    scope = stats.relatedScope(QStringLiteral("10.9.0.1:443"));
    QCOMPARE(scope.value(QStringLiteral("nodeId")).toString(), QStringLiteral("all"));
    QCOMPARE(scope.value(QStringLiteral("filter")).toString(),
             QStringLiteral("ip.addr == 10.9.0.1 && tcp.port == 443"));

    stats.setGroup(EndpointStatisticsModel::Udp);
    scope = stats.relatedScope(QStringLiteral("10.9.0.2:53"));
    QCOMPARE(scope.value(QStringLiteral("filter")).toString(),
             QStringLiteral("ip.addr == 10.9.0.2 && udp.port == 53"));
}

void EndpointStatisticsModelTest::columnDefaultsMatchUpstream()
{
    // Address hides for Apps/Domains; Port only shows for TCP/UDP.
    QVERIFY(!EndpointStatisticsModel::columnDefaultVisible(
        EndpointStatisticsModel::Address, EndpointStatisticsModel::Apps));
    QVERIFY(!EndpointStatisticsModel::columnDefaultVisible(
        EndpointStatisticsModel::Address, EndpointStatisticsModel::Domains));
    QVERIFY(EndpointStatisticsModel::columnDefaultVisible(
        EndpointStatisticsModel::Address, EndpointStatisticsModel::Ipv4));
    QVERIFY(!EndpointStatisticsModel::columnDefaultVisible(
        EndpointStatisticsModel::Port, EndpointStatisticsModel::Ipv4));
    QVERIFY(EndpointStatisticsModel::columnDefaultVisible(
        EndpointStatisticsModel::Port, EndpointStatisticsModel::Udp));
    QVERIFY(EndpointStatisticsModel::columnDefaultVisible(
        EndpointStatisticsModel::Summary, EndpointStatisticsModel::Apps));
    QCOMPARE(EndpointStatisticsModel::columnTitle(EndpointStatisticsModel::TxBytes),
             QStringLiteral("Tx Bytes"));
    QCOMPARE(EndpointStatisticsModel::columnJsonKey(EndpointStatisticsModel::TxPackets),
             QStringLiteral("tx_packets"));
    QCOMPARE(EndpointStatisticsModel::columnDefaultWidth(EndpointStatisticsModel::Address), 190);
}

QTEST_MAIN(EndpointStatisticsModelTest)
#include "endpointstatsmodel_test.moc"
