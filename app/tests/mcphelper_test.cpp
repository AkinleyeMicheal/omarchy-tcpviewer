// MCP helper integration tests: omarchy-tcpviewer-mcp is driven over stdio
// against a live test bridge (the same pattern the AI clients use). Covers
// protocol negotiation, the tool list, bridge forwarding, the confirm gate,
// and the disabled-server path.
#include "appcommandserver.h"
#include "sessioncontroller.h"

#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QTest>

class McpHelperTest : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void protocolAndTools();
    void toolCallsForwardToBridge();
    void confirmAndDisabledPaths();
    void cleanupTestCase();

private:
    // QVERIFY expands to a bare return, so the waiting lives in a void
    // helper and the thin wrapper returns the stored reply.
    void writeAndRead(const QJsonObject &message)
    {
        m_helper.write(QJsonDocument(message).toJson(QJsonDocument::Compact) + '\n');
        QByteArray line;
        const QDeadlineTimer deadline(15000);
        while (line.isEmpty() && !deadline.hasExpired()) {
            // Pump the test's own event loop: the bridge's QLocalServer
            // accepts and dispatches here, and the helper's reply follows.
            QTest::qWait(50);
            line = m_helper.readLine();
        }
        QVERIFY2(!line.isEmpty(), "helper produced no reply in time");
        m_lastReply = line;
    }

    QByteArray rpc(const QJsonObject &message);
    QJsonObject rpcObject(const QJsonObject &message);

    SessionController *m_session = nullptr;
    QProcess m_helper;
    QString m_socket;
    QByteArray m_lastReply;
};

void McpHelperTest::initTestCase()
{
    const QString helper = qEnvironmentVariable("MCP_HELPER");
    if (helper.isEmpty())
        QSKIP("MCP_HELPER not set (built helper binary path)");

    m_session = new SessionController(this);
    // Seed the workspace without start(): no daemon traffic, no capture.
    m_session->tabs()->seed(2, false, QStringLiteral("packets"), QString(), -1);
    m_socket = QDir::temp().filePath(QStringLiteral("tcpviewer-mcptest-%1.sock")
                                         .arg(QCoreApplication::applicationPid()));
    QFile::remove(m_socket);
    m_session->appCommands()->setSocketPath(m_socket);
    QVERIFY(m_session->appCommands()->listen());

    // One helper process for the whole suite: it forwards to the bridge per
    // call (fresh connection each time), so per-case setting changes apply.
    m_helper.setProgram(helper);
    m_helper.setProcessChannelMode(QProcess::ForwardedErrorChannel);
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("TCPVIEWER_APP_SOCKET"), m_socket);
    m_helper.setProcessEnvironment(env);
    m_helper.start();
    QVERIFY(m_helper.waitForStarted(3000));
}

QJsonObject McpHelperTest::rpcObject(const QJsonObject &message)
{
    return QJsonDocument::fromJson(rpc(message)).object();
}

QByteArray McpHelperTest::rpc(const QJsonObject &message)
{
    writeAndRead(message);
    return m_lastReply;
}

void McpHelperTest::protocolAndTools()
{
    // initialize: the client's protocol version comes back when supported.
    const QJsonObject init = rpcObject(QJsonObject{
        {QStringLiteral("jsonrpc"), QStringLiteral("2.0")},
        {QStringLiteral("id"), 1},
        {QStringLiteral("method"), QStringLiteral("initialize")},
        {QStringLiteral("params"), QJsonObject{
            {QStringLiteral("protocolVersion"), QStringLiteral("2025-06-18")}}}});
    QCOMPARE(init.value(QStringLiteral("id")).toInt(), 1);
    QCOMPARE(init.value(QStringLiteral("result")).toObject()
                 .value(QStringLiteral("protocolVersion")).toString(),
             QStringLiteral("2025-06-18"));
    QCOMPARE(init.value(QStringLiteral("result")).toObject()
                 .value(QStringLiteral("serverInfo")).toObject()
                 .value(QStringLiteral("name")).toString(), QStringLiteral("tcpviewer"));

    // notifications/initialized produces no reply; a ping answers {}.
    m_helper.write(QJsonDocument(QJsonObject{
        {QStringLiteral("jsonrpc"), QStringLiteral("2.0")},
        {QStringLiteral("method"), QStringLiteral("notifications/initialized")}})
                       .toJson(QJsonDocument::Compact) + '\n');
    const QJsonObject ping = rpcObject(QJsonObject{
        {QStringLiteral("jsonrpc"), QStringLiteral("2.0")},
        {QStringLiteral("id"), 2},
        {QStringLiteral("method"), QStringLiteral("ping")}});
    QCOMPARE(ping.value(QStringLiteral("id")).toInt(), 2);
    QVERIFY(ping.value(QStringLiteral("result")).toObject().isEmpty());

    // tools/list: the documented tools, each with a schema.
    const QJsonObject tools = rpcObject(QJsonObject{
        {QStringLiteral("jsonrpc"), QStringLiteral("2.0")},
        {QStringLiteral("id"), 3},
        {QStringLiteral("method"), QStringLiteral("tools/list")}});
    const QJsonArray list = tools.value(QStringLiteral("result")).toObject()
                                .value(QStringLiteral("tools")).toArray();
    QVERIFY(list.size() >= 13);
    for (const QJsonValue &entry : list) {
        QVERIFY(!entry.toObject().value(QStringLiteral("name")).toString().isEmpty());
        QVERIFY(entry.toObject().value(QStringLiteral("inputSchema")).isObject());
    }

    // Unknown method.
    const QJsonObject unknown = rpcObject(QJsonObject{
        {QStringLiteral("jsonrpc"), QStringLiteral("2.0")},
        {QStringLiteral("id"), 4},
        {QStringLiteral("method"), QStringLiteral("resources/list")}});
    QCOMPARE(unknown.value(QStringLiteral("error")).toObject()
                 .value(QStringLiteral("code")).toInt(), -32601);
}

void McpHelperTest::toolCallsForwardToBridge()
{
    // The app setting gates MCP: on for this case (upstream Settings → MCP).
    qputenv("TCPVIEWER_MCP_ENABLED", "1");

    const QJsonObject result = rpcObject(QJsonObject{
        {QStringLiteral("jsonrpc"), QStringLiteral("2.0")},
        {QStringLiteral("id"), 10},
        {QStringLiteral("method"), QStringLiteral("tools/call")},
        {QStringLiteral("params"), QJsonObject{
            {QStringLiteral("name"), QStringLiteral("list_tabs")},
            {QStringLiteral("arguments"), QJsonObject{}}}}});
    const QJsonObject content = result.value(QStringLiteral("result")).toObject()
                                    .value(QStringLiteral("content")).toArray()
                                    .first().toObject();
    QCOMPARE(content.value(QStringLiteral("type")).toString(), QStringLiteral("text"));
    const QJsonDocument payload = QJsonDocument::fromJson(
        content.value(QStringLiteral("text")).toString().toUtf8());
    QCOMPARE(payload.object().value(QStringLiteral("active_tab")).toString(),
             QStringLiteral("tab-1"));
    QCOMPARE(payload.object().value(QStringLiteral("tabs")).toArray().size(), 2);

    // Workspace write through the helper: select_tab.
    const QJsonObject select = rpcObject(QJsonObject{
        {QStringLiteral("jsonrpc"), QStringLiteral("2.0")},
        {QStringLiteral("id"), 11},
        {QStringLiteral("method"), QStringLiteral("tools/call")},
        {QStringLiteral("params"), QJsonObject{
            {QStringLiteral("name"), QStringLiteral("select_tab")},
            {QStringLiteral("arguments"), QJsonObject{
                {QStringLiteral("tab_id"), QStringLiteral("tab-2")}}}}}});
    const QJsonDocument selectPayload = QJsonDocument::fromJson(
        select.value(QStringLiteral("result")).toObject()
            .value(QStringLiteral("content")).toArray().first().toObject()
            .value(QStringLiteral("text")).toString().toUtf8());
    QCOMPARE(selectPayload.object().value(QStringLiteral("id")).toString(),
             QStringLiteral("tab-2"));
    QCOMPARE(m_session->tabs()->tabID(m_session->tabs()->activeTab()),
             QStringLiteral("tab-2"));

    qunsetenv("TCPVIEWER_MCP_ENABLED");
}

void McpHelperTest::confirmAndDisabledPaths()
{
    // close_tab requires confirm=true (upstream's destructive-action gate).
    qputenv("TCPVIEWER_MCP_ENABLED", "1");
    QJsonObject response = rpcObject(QJsonObject{
        {QStringLiteral("jsonrpc"), QStringLiteral("2.0")},
        {QStringLiteral("id"), 20},
        {QStringLiteral("method"), QStringLiteral("tools/call")},
        {QStringLiteral("params"), QJsonObject{
            {QStringLiteral("name"), QStringLiteral("close_tab")},
            {QStringLiteral("arguments"), QJsonObject{
                {QStringLiteral("tab_id"), QStringLiteral("tab-1")}}}}}});
    QCOMPARE(response.value(QStringLiteral("result")).toObject()
                 .value(QStringLiteral("isError")).toBool(), true);
    QVERIFY(response.value(QStringLiteral("result")).toObject()
                .value(QStringLiteral("content")).toArray().first().toObject()
                .value(QStringLiteral("text")).toString()
                .contains(QStringLiteral("confirm=true")));
    QCOMPARE(m_session->tabs()->count(), 2);

    // With the switch off, every tool call reports the settings error.
    qputenv("TCPVIEWER_MCP_ENABLED", "0");
    response = rpcObject(QJsonObject{
        {QStringLiteral("jsonrpc"), QStringLiteral("2.0")},
        {QStringLiteral("id"), 21},
        {QStringLiteral("method"), QStringLiteral("tools/call")},
        {QStringLiteral("params"), QJsonObject{
            {QStringLiteral("name"), QStringLiteral("list_tabs")},
            {QStringLiteral("arguments"), QJsonObject{}}}}});
    QCOMPARE(response.value(QStringLiteral("result")).toObject()
                 .value(QStringLiteral("isError")).toBool(), true);
    QVERIFY(response.value(QStringLiteral("result")).toObject()
                .value(QStringLiteral("content")).toArray().first().toObject()
                .value(QStringLiteral("text")).toString()
                .contains(QStringLiteral("disabled in omarchy-tcpviewer settings")));

    // Unknown tool: a protocol-level invalid params error.
    qputenv("TCPVIEWER_MCP_ENABLED", "1");
    response = rpcObject(QJsonObject{
        {QStringLiteral("jsonrpc"), QStringLiteral("2.0")},
        {QStringLiteral("id"), 22},
        {QStringLiteral("method"), QStringLiteral("tools/call")},
        {QStringLiteral("params"), QJsonObject{
            {QStringLiteral("name"), QStringLiteral("make_coffee")}}}});
    QCOMPARE(response.value(QStringLiteral("error")).toObject()
                 .value(QStringLiteral("code")).toInt(), -32602);

    qunsetenv("TCPVIEWER_MCP_ENABLED");
    qunsetenv("TCPVIEWER_MCP_REDACTION");
}

void McpHelperTest::cleanupTestCase()
{
    m_helper.kill();
    m_helper.waitForFinished(3000);
    QFile::remove(m_socket);
}

QTEST_MAIN(McpHelperTest)
#include "mcphelper_test.moc"
