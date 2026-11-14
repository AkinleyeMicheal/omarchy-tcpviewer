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

QTEST_MAIN(AppCommandServerTest)
#include "appcommandserver_test.moc"
