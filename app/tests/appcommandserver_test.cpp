// AppCommandServer tests: the app's local command bridge answers JSON-line
// requests for workspace tabs, panes, Overview, endpoint statistics, and
// packet reveal, against a seeded WorkspaceTabsController.
#include "appcommandserver.h"
#include "sessioncontroller.h"

#include <QDir>
#include <QEventLoop>
#include <QFile>
#include <QJsonArray>
#include <QLocalSocket>
#include <QSignalSpy>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTest>
#include <QTimer>

class AppCommandServerTest : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void appStatus();
    void tabsListAndLifecycle();
    void tabFilterAndPane();
    void overviewAndStatistics();
    void packetsReveal();
    void closeFlavorsDefaultToActiveTab();
    void unknownCommandAndLastTabClose();
    // MCP cases last: a successful mcp.hello marks the shared connection,
    // which would leak the MCP gate into the other cases.
    void mcpHandshakeAndRedaction();
    void mcpWorkspaceCommands();

private:
    void request(const QJsonObject &json, QJsonObject *out);
    QJsonObject send(const QJsonObject &request);
    QJsonObject send(const QString &cmd, const QJsonObject &args = {});

    SessionController *m_session = nullptr;
    QLocalSocket *m_socket = nullptr;
    QString m_path;
};

void AppCommandServerTest::initTestCase()
{
    m_session = new SessionController(this);
    // Seed the workspace without start(): no daemon traffic, no capture.
    m_session->tabs()->seed(2, false, QStringLiteral("packets"), QString(), -1);

    m_path = QDir::temp().filePath(QStringLiteral("tcpviewer-apptest-%1.sock")
                                       .arg(QCoreApplication::applicationPid()));
    QFile::remove(m_path);
    m_session->appCommands()->setSocketPath(m_path);
    QVERIFY(m_session->appCommands()->listen());

    m_socket = new QLocalSocket(this);
    m_socket->connectToServer(m_path);
    QVERIFY(m_socket->waitForConnected(2000));
}

void AppCommandServerTest::request(const QJsonObject &json, QJsonObject *out)
{
    m_socket->write(QJsonDocument(json).toJson(QJsonDocument::Compact) + '\n');
    m_socket->flush();
    QByteArray buffer;
    QEventLoop loop;
    QTimer timeout;
    timeout.setSingleShot(true);
    timeout.start(2000);
    connect(&timeout, &QTimer::timeout, &loop, &QEventLoop::quit);
    connect(m_socket, &QLocalSocket::readyRead, &loop, &QEventLoop::quit);
    while (!buffer.contains('\n') && timeout.isActive()) {
        buffer += m_socket->readAll();
        if (buffer.contains('\n'))
            break;
        loop.exec();
    }
    buffer += m_socket->readAll();
    const int end = buffer.indexOf('\n');
    QVERIFY(end >= 0);
    *out = QJsonDocument::fromJson(buffer.left(end)).object();
}

QJsonObject AppCommandServerTest::send(const QJsonObject &request)
{
    QJsonObject out;
    this->request(request, &out);
    return out;
}

QJsonObject AppCommandServerTest::send(const QString &cmd, const QJsonObject &args)
{
    // The bridge speaks the daemon's schema_version 1 envelope.
    QJsonObject request{
        {QStringLiteral("schema_version"), 1},
        {QStringLiteral("request_id"), QStringLiteral("r1")},
        {QStringLiteral("command"), cmd},
        {QStringLiteral("params"), args},
    };
    return send(request);
}

void AppCommandServerTest::appStatus()
{
    const QJsonObject response = send(QStringLiteral("app.status"));
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), true);
    const QJsonObject result = response.value(QStringLiteral("data")).toObject();
    QCOMPARE(result.value(QStringLiteral("app")).toString(), QStringLiteral("omarchy-tcpviewer"));
    QCOMPARE(result.value(QStringLiteral("tabs")).toInt(), 2);
    QCOMPARE(result.value(QStringLiteral("active_tab")).toString(), QStringLiteral("tab-1"));
    QCOMPARE(result.value(QStringLiteral("mode")).toString(), QStringLiteral("packets"));
}

void AppCommandServerTest::tabsListAndLifecycle()
{
    QJsonObject response = send(QStringLiteral("tabs.list"));
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), true);
    const QJsonArray tabs = response.value(QStringLiteral("data")).toObject()
                                .value(QStringLiteral("tabs")).toArray();
    QCOMPARE(tabs.size(), 2);
    QCOMPARE(tabs.at(0).toObject().value(QStringLiteral("id")).toString(), QStringLiteral("tab-1"));
    QCOMPARE(tabs.at(1).toObject().value(QStringLiteral("label")).toString(), QStringLiteral("Capture 2"));

    // Create with a label override (file-import naming).
    response = send(QStringLiteral("tabs.create"),
                    {{QStringLiteral("label"), QStringLiteral("imported.pcap")}});
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), true);
    QCOMPARE(response.value(QStringLiteral("data")).toObject()
                 .value(QStringLiteral("id")).toString(), QStringLiteral("tab-3"));
    QCOMPARE(response.value(QStringLiteral("data")).toObject()
                 .value(QStringLiteral("label")).toString(), QStringLiteral("imported.pcap"));

    // Select, move, close.
    response = send(QStringLiteral("tabs.select"), {{QStringLiteral("tab_id"), QStringLiteral("tab-2")}});
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), true);
    QCOMPARE(m_session->tabs()->activeTab(), 1);
    // Selecting the already-active tab is a no-op success.
    response = send(QStringLiteral("tabs.select"), {{QStringLiteral("tab_id"), QStringLiteral("tab-2")}});
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), true);
    QCOMPARE(m_session->tabs()->activeTab(), 1);

    response = send(QStringLiteral("tabs.move"),
                    {{QStringLiteral("tab_id"), QStringLiteral("tab-1")}, {QStringLiteral("to"), 2}});
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), true);
    QCOMPARE(m_session->tabs()->tabID(2), QStringLiteral("tab-1"));

    response = send(QStringLiteral("tabs.close"), {{QStringLiteral("tab_id"), QStringLiteral("tab-3")}});
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), true);
    QCOMPARE(response.value(QStringLiteral("data")).toObject()
                 .value(QStringLiteral("window_closed")).toBool(), false);
    QCOMPARE(m_session->tabs()->count(), 2);

    // Unknown tabs are refused.
    response = send(QStringLiteral("tabs.select"), {{QStringLiteral("tab_id"), QStringLiteral("tab-99")}});
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), false);
}

void AppCommandServerTest::tabFilterAndPane()
{
    m_session->tabs()->selectTab(0);
    QJsonObject response = send(QStringLiteral("tab.set_filter"),
                                {{QStringLiteral("filter"), QStringLiteral("tcp")}});
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), true);
    QCOMPARE(m_session->filterText(), QStringLiteral("tcp"));
    // The filter is stored on the active tab, so the state survives switches.
    QCOMPARE(m_session->tabs()
                 ->data(m_session->tabs()->index(0),
                        WorkspaceTabsController::FilterTextRole)
                 .toString(), QStringLiteral("tcp"));

    response = send(QStringLiteral("pane.get"), {{QStringLiteral("pane"), 1}});
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), true);
    QCOMPARE(response.value(QStringLiteral("data")).toObject()
                 .value(QStringLiteral("pane")).toInt(), 1);
}

void AppCommandServerTest::overviewAndStatistics()
{
    QJsonObject response = send(QStringLiteral("overview.get"));
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), true);
    QVERIFY(response.value(QStringLiteral("data")).isObject());

    response = send(QStringLiteral("statistics.endpoints"),
                    {{QStringLiteral("group"), QStringLiteral("apps")},
                     {QStringLiteral("limit"), 10}});
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), true);
    const QJsonObject result = response.value(QStringLiteral("data")).toObject();
    QCOMPARE(result.value(QStringLiteral("group")).toString(), QStringLiteral("apps"));
    QVERIFY(result.value(QStringLiteral("rows")).isArray());

    response = send(QStringLiteral("statistics.endpoints"),
                    {{QStringLiteral("group"), QStringLiteral("bogus")}});
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), false);
    QCOMPARE(response.value(QStringLiteral("error")).toObject()
                 .value(QStringLiteral("code")).toString(), QStringLiteral("invalid_params"));
}

void AppCommandServerTest::packetsReveal()
{
    QSignalSpy spy(m_session->appCommands(), &AppCommandServer::revealRequested);
    QJsonObject response = send(QStringLiteral("packets.reveal"),
                                {{QStringLiteral("packet_id"), QStringLiteral("pkt-5")}});
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), true);
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.first().first().toString(), QStringLiteral("pkt-5"));

    response = send(QStringLiteral("packets.reveal"));
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), false);
}

void AppCommandServerTest::unknownCommandAndLastTabClose()
{
    QJsonObject response = send(QStringLiteral("nope.nothing"));
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), false);
    QCOMPARE(response.value(QStringLiteral("error")).toObject()
                 .value(QStringLiteral("code")).toString(), QStringLiteral("unknown_command"));

    // Close down to one tab, then the last close reports window_closed
    // (upstream: closing the last tab closes the window).
    while (m_session->tabs()->count() > 1)
        m_session->tabs()->closeTab(0);
    response = send(QStringLiteral("tabs.close"));
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), true);
    QCOMPARE(response.value(QStringLiteral("data")).toObject()
                 .value(QStringLiteral("window_closed")).toBool(), true);
    // The workspace keeps the tab; the caller owns the window close.
    QCOMPARE(m_session->tabs()->count(), 1);
}

void AppCommandServerTest::closeFlavorsDefaultToActiveTab()
{
    // Upstream's Close Other Tabs / Close Tabs to the Right menu items
    // target the current tab: an absent tab_id keeps the active one.
    // Seed first: earlier lifecycle tests leave the workspace reordered.
    m_session->tabs()->seed(2, false, QStringLiteral("packets"), QString(), -1);
    m_session->tabs()->selectTab(1);
    QJsonObject response = send(QStringLiteral("tabs.close_others"));
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), true);
    QCOMPARE(m_session->tabs()->count(), 1);
    QCOMPARE(m_session->tabs()->tabID(0), QStringLiteral("tab-2"));
    QCOMPARE(response.value(QStringLiteral("data")).toObject()
                 .value(QStringLiteral("remaining")).toInt(), 1);

    // Rebuild a workspace; close_right from the first tab drops the rest.
    m_session->tabs()->seed(3, false, QStringLiteral("packets"), QString(), -1);
    m_session->tabs()->selectTab(0);
    response = send(QStringLiteral("tabs.close_right"));
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), true);
    QCOMPARE(m_session->tabs()->count(), 1);
    QCOMPARE(m_session->tabs()->tabID(0), QStringLiteral("tab-1"));
}

void AppCommandServerTest::mcpHandshakeAndRedaction()
{
    // Default is off (upstream ships MCP disabled): the announce refuses.
    qputenv("TCPVIEWER_MCP_ENABLED", "0");
    qputenv("TCPVIEWER_MCP_REDACTION", "1");
    QJsonObject response = send(QStringLiteral("mcp.hello"));
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), false);
    QCOMPARE(response.value(QStringLiteral("error")).toObject()
                 .value(QStringLiteral("code")).toString(), QStringLiteral("not_enabled"));

    // Enabled: the announce marks the connection and reports the redaction
    // setting; the app setting is upstream's Settings → MCP switch.
    qputenv("TCPVIEWER_MCP_ENABLED", "1");
    response = send(QStringLiteral("mcp.hello"));
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), true);
    QCOMPARE(response.value(QStringLiteral("data")).toObject()
                 .value(QStringLiteral("app")).toString(), QStringLiteral("omarchy-tcpviewer"));
    QCOMPARE(response.value(QStringLiteral("data")).toObject()
                 .value(QStringLiteral("redaction")).toBool(), true);
    // A disabled switch mid-connection refuses MCP requests (the announce
    // reads the setting on every call).
    qputenv("TCPVIEWER_MCP_ENABLED", "0");
    response = send(QStringLiteral("tabs.list"));
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), false);
    QCOMPARE(response.value(QStringLiteral("error")).toObject()
                 .value(QStringLiteral("code")).toString(), QStringLiteral("not_enabled"));
    qputenv("TCPVIEWER_MCP_ENABLED", "1");

    // The redaction scrubber (upstream "Redact Sensitive Data Before
    // Sending to AI"): sensitive keys are masked, keys that differ only by
    // separators match, and everything else survives.
    QVariant scrubbed = QVariantMap{
        {QStringLiteral("authorization"), QStringLiteral("Bearer xyz")},
        {QStringLiteral("Set-Cookie"), QStringLiteral("session=abc")},
        {QStringLiteral("api_key"), QStringLiteral("k-123")},
        {QStringLiteral("nested"), QVariantList{
            QVariantMap{{QStringLiteral("password"), QStringLiteral("hunter2")},
                {QStringLiteral("summary"), QStringLiteral("keep me")}}},
        },
        {QStringLiteral("label"), QStringLiteral("keep me")},
    };
    AppCommandServer::redactValue(scrubbed);
    const QVariantMap map = scrubbed.toMap();
    QCOMPARE(map.value(QStringLiteral("authorization")).toString(), QStringLiteral("[redacted]"));
    QCOMPARE(map.value(QStringLiteral("Set-Cookie")).toString(), QStringLiteral("[redacted]"));
    QCOMPARE(map.value(QStringLiteral("api_key")).toString(), QStringLiteral("[redacted]"));
    QCOMPARE(map.value(QStringLiteral("label")).toString(), QStringLiteral("keep me"));
    const QVariantList nested = map.value(QStringLiteral("nested")).toList();
    QCOMPARE(nested.first().toMap().value(QStringLiteral("password")).toString(),
             QStringLiteral("[redacted]"));
    QCOMPARE(nested.first().toMap().value(QStringLiteral("summary")).toString(),
             QStringLiteral("keep me"));

    qunsetenv("TCPVIEWER_MCP_ENABLED");
    qunsetenv("TCPVIEWER_MCP_REDACTION");
}

void AppCommandServerTest::mcpWorkspaceCommands()
{
    // A marked connection (from the handshake case) needs the setting on.
    qputenv("TCPVIEWER_MCP_ENABLED", "1");
    qputenv("TCPVIEWER_MCP_REDACTION", "1");
    m_session->tabs()->seed(2, false, QStringLiteral("packets"), QString(), -1);
    m_session->tabs()->selectTab(0);

    // create_tab's select=false leaves the current tab selected.
    QJsonObject response = send(QStringLiteral("tabs.create"),
                                {{QStringLiteral("label"), QStringLiteral("bg.pcap")},
                                 {QStringLiteral("select"), false}});
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), true);
    QCOMPARE(m_session->tabs()->count(), 3);
    QCOMPARE(m_session->tabs()->tabID(m_session->tabs()->activeTab()), QStringLiteral("tab-1"));
    QCOMPARE(m_session->tabs()->tabID(2), QStringLiteral("tab-3"));

    // set_split_view writes the active tab's split state.
    response = send(QStringLiteral("tabs.set_split"), {{QStringLiteral("enabled"), true}});
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), true);
    QCOMPARE(response.value(QStringLiteral("data")).toObject()
                 .value(QStringLiteral("split_visible")).toBool(), true);
    response = send(QStringLiteral("tabs.set_split"), {{QStringLiteral("enabled"), false}});
    QCOMPARE(response.value(QStringLiteral("data")).toObject()
                 .value(QStringLiteral("split_visible")).toBool(), false);

    // packets.query: the loaded-page window (empty without a daemon source).
    response = send(QStringLiteral("packets.query"), {{QStringLiteral("limit"), 10}});
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), true);
    const QJsonObject query = response.value(QStringLiteral("data")).toObject();
    QCOMPARE(query.value(QStringLiteral("count")).toInt(), 0);
    QCOMPARE(query.value(QStringLiteral("next_offset")).toInt(), -1);
    QVERIFY(query.value(QStringLiteral("packets")).toArray().isEmpty());

    // statistics.endpoints: the documented six groups (apps, domains, ipv4,
    // ipv6, tcp, udp) with sorting, pagination, and endpoint objects.
    response = send(QStringLiteral("statistics.endpoints"),
                    {{QStringLiteral("group"), QStringLiteral("udp")}});
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), true);
    QCOMPARE(response.value(QStringLiteral("data")).toObject()
                 .value(QStringLiteral("group")).toString(), QStringLiteral("udp"));
    QCOMPARE(response.value(QStringLiteral("data")).toObject()
                 .value(QStringLiteral("next_offset")).toInt(), -1);
    response = send(QStringLiteral("statistics.endpoints"),
                    {{QStringLiteral("group"), QStringLiteral("ipv4")},
                     {QStringLiteral("sort"), QStringLiteral("address")},
                     {QStringLiteral("order"), QStringLiteral("asc")}});
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), true);
    // The F2 names are gone: upstream documents ipv4/ipv6/tcp/udp.
    response = send(QStringLiteral("statistics.endpoints"),
                    {{QStringLiteral("group"), QStringLiteral("ips")}});
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), false);
    response = send(QStringLiteral("statistics.endpoints"),
                    {{QStringLiteral("group"), QStringLiteral("apps")},
                     {QStringLiteral("sort"), QStringLiteral("bogus")}});
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), false);
    QCOMPARE(response.value(QStringLiteral("error")).toObject()
                 .value(QStringLiteral("code")).toString(), QStringLiteral("invalid_params"));
    response = send(QStringLiteral("statistics.endpoints"),
                    {{QStringLiteral("group"), QStringLiteral("apps")},
                     {QStringLiteral("order"), QStringLiteral("sideways")}});
    QCOMPARE(response.value(QStringLiteral("ok")).toBool(), false);

    qunsetenv("TCPVIEWER_MCP_ENABLED");
    qunsetenv("TCPVIEWER_MCP_REDACTION");
}

QTEST_MAIN(AppCommandServerTest)
#include "appcommandserver_test.moc"
