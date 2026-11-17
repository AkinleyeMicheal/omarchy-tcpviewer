// AppSettings tests: the six documented keys round-trip through
// setSettingValue/settingValue with the CLI's text spellings, invalid values
// are rejected with user-facing messages, reset restores defaults, and the
// MCP env overrides keep winning over the stored values.
#include "appsettings.h"

#include <QDir>
#include <QSettings>
#include <QSignalSpy>
#include <QTest>

class AppSettingsTest : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void init();
    void defaultsAndKeys();
    void boolSpellings();
    void themeValidation();
    void fontSizeRange();
    void unknownKeyRejected();
    void persistenceAndReset();
    void mcpEnvOverrides();

private:
    AppSettings *m_settings = nullptr;
};

void AppSettingsTest::initTestCase()
{
    // Keep every write inside a throwaway config location; the developer's
    // real omarchy-tcpviewer config must never be touched by tests.
    QCoreApplication::setOrganizationName(QStringLiteral("tcpviewer-appsettings-test"));
    QCoreApplication::setApplicationName(QStringLiteral("omarchy-tcpviewer"));
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope,
                       QDir::temp().filePath(QStringLiteral("tcpviewer-appsettings-test-%1")
                                                 .arg(QCoreApplication::applicationPid())));
    m_settings = AppSettings::instance();
}

void AppSettingsTest::init()
{
    // Fresh defaults for every case so state cannot leak between tests.
    m_settings->resetAll();
    qunsetenv("TCPVIEWER_MCP_ENABLED");
    qunsetenv("TCPVIEWER_MCP_REDACTION");
}

void AppSettingsTest::defaultsAndKeys()
{
    const QStringList keys = AppSettings::settingKeys();
    QCOMPARE(keys.count(), 6);
    const QStringList expected{
        QStringLiteral("theme"),
        QStringLiteral("packet_font_size"),
        QStringLiteral("monospaced_font"),
        QStringLiteral("quit_confirmation"),
        QStringLiteral("mcp_enabled"),
        QStringLiteral("mcp_redaction"),
    };
    QCOMPARE(keys, expected);
    QCOMPARE(m_settings->theme(), QStringLiteral("system"));
    QCOMPARE(m_settings->packetFontSize(), 12);
    QCOMPARE(m_settings->monospacedFont(), true);
    QCOMPARE(m_settings->quitConfirmation(), false);
    QCOMPARE(m_settings->mcpEnabled(), false);
    QCOMPARE(m_settings->mcpRedaction(), true);
    QCOMPARE(m_settings->settingValue(QStringLiteral("packet_font_size")).toInt(), 12);
}

void AppSettingsTest::boolSpellings()
{
    // The documented boolean forms: true/false, yes/no, on/off, 1/0.
    const QPair<QString, bool> forms[] = {
        {QStringLiteral("true"), true}, {QStringLiteral("false"), false},
        {QStringLiteral("yes"), true}, {QStringLiteral("no"), false},
        {QStringLiteral("on"), true}, {QStringLiteral("off"), false},
        {QStringLiteral("1"), true}, {QStringLiteral("0"), false},
        {QStringLiteral(" ON "), true}, {QStringLiteral("No"), false},
    };
    for (const auto &form : forms) {
        QString error;
        QVERIFY2(m_settings->setSettingValue(QStringLiteral("quit_confirmation"),
                                             form.first, &error),
                 qPrintable(form.first));
        QCOMPARE(m_settings->quitConfirmation(), form.second);
        QVERIFY(error.isEmpty());
    }
    QString error;
    QVERIFY(!m_settings->setSettingValue(QStringLiteral("quit_confirmation"),
                                         QStringLiteral("maybe"), &error));
    QVERIFY(error.contains(QStringLiteral("boolean value")));
    QCOMPARE(m_settings->quitConfirmation(), false);
}

void AppSettingsTest::themeValidation()
{
    QSignalSpy spy(m_settings, &AppSettings::themeChanged);
    for (const QString &valid : {QStringLiteral("light"), QStringLiteral("DARK"),
                                 QStringLiteral(" system ")}) {
        QString error;
        QVERIFY2(m_settings->setSettingValue(QStringLiteral("theme"), valid, &error),
                 qPrintable(valid));
    }
    // Normalized spellings collapse to the stored lowercase set.
    QCOMPARE(m_settings->theme(), QStringLiteral("system"));
    QCOMPARE(spy.count(), 3);

    QString error;
    QVERIFY(!m_settings->setSettingValue(QStringLiteral("theme"),
                                         QStringLiteral("midnight"), &error));
    QCOMPARE(error, QStringLiteral("theme must be system, light, or dark"));
    QCOMPARE(m_settings->theme(), QStringLiteral("system"));
    QCOMPARE(spy.count(), 3); // the failing set does not notify
}

void AppSettingsTest::fontSizeRange()
{
    for (const QVariant &edge : {QVariant(10), QVariant(24), QVariant(QStringLiteral("17"))}) {
        QString error;
        QVERIFY2(m_settings->setSettingValue(QStringLiteral("packet_font_size"), edge, &error),
                 qPrintable(edge.toString()));
    }
    QCOMPARE(m_settings->packetFontSize(), 17);

    for (const QVariant &bad : {QVariant(9), QVariant(25), QVariant(QStringLiteral("big"))}) {
        QString error;
        QVERIFY(!m_settings->setSettingValue(QStringLiteral("packet_font_size"), bad, &error));
        QCOMPARE(error, QStringLiteral("packet_font_size must be 10 through 24"));
    }
    QCOMPARE(m_settings->packetFontSize(), 17);
}

void AppSettingsTest::unknownKeyRejected()
{
    QCOMPARE(m_settings->settingValue(QStringLiteral("analytics")), QVariant());

    QString error;
    QVERIFY(!m_settings->setSettingValue(QStringLiteral("analytics"), true, &error));
    QCOMPARE(error, QStringLiteral("unknown setting: analytics"));
    QVERIFY(!m_settings->resetSettingValue(QStringLiteral("crash_reports"), &error));
    QCOMPARE(error, QStringLiteral("unknown setting: crash_reports"));
}

void AppSettingsTest::persistenceAndReset()
{
    m_settings->setSettingValue(QStringLiteral("theme"), QStringLiteral("dark"), nullptr);
    m_settings->setSettingValue(QStringLiteral("mcp_enabled"), true, nullptr);

    // The documented QSettings keys carry the stored values.
    QSettings stored;
    QCOMPARE(stored.value(QStringLiteral("settings/theme")).toString(),
             QStringLiteral("dark"));
    QCOMPARE(stored.value(QStringLiteral("mcp/enabled")).toBool(), true);

    // Reset restores defaults and clears the stored keys.
    QString error;
    QVERIFY(m_settings->resetSettingValue(QStringLiteral("theme"), &error));
    QCOMPARE(m_settings->theme(), QStringLiteral("system"));
    QCOMPARE(stored.value(QStringLiteral("settings/theme")).toString(), QString());
    QVERIFY(m_settings->resetSettingValue(QStringLiteral("mcp_enabled"), &error));
    QCOMPARE(m_settings->mcpEnabled(), false);

    // The bulk form resets everything back to the documented defaults.
    m_settings->setSettingValue(QStringLiteral("monospaced_font"), false, nullptr);
    m_settings->resetAll();
    QCOMPARE(m_settings->monospacedFont(), true);
    QCOMPARE(m_settings->settingValue(QStringLiteral("quit_confirmation")).toBool(), false);
    QCOMPARE(m_settings->settingValue(QStringLiteral("mcp_redaction")).toBool(), true);
}

void AppSettingsTest::mcpEnvOverrides()
{
    // Stored values drive the effective values without env overrides.
    m_settings->setSettingValue(QStringLiteral("mcp_enabled"), true, nullptr);
    QCOMPARE(m_settings->mcpEnabled(), true);

    // The CI env overrides win over both the stored value and the default.
    qputenv("TCPVIEWER_MCP_ENABLED", "0");
    QCOMPARE(m_settings->mcpEnabled(), false);
    qputenv("TCPVIEWER_MCP_ENABLED", "1");
    m_settings->setSettingValue(QStringLiteral("mcp_enabled"), false, nullptr);
    QCOMPARE(m_settings->mcpEnabled(), true);
    qunsetenv("TCPVIEWER_MCP_ENABLED");

    qputenv("TCPVIEWER_MCP_REDACTION", "off");
    QCOMPARE(m_settings->mcpRedaction(), false);
    qunsetenv("TCPVIEWER_MCP_REDACTION");
    QCOMPARE(m_settings->mcpRedaction(), true);
}

QTEST_MAIN(AppSettingsTest)
#include "appsettings_test.moc"
