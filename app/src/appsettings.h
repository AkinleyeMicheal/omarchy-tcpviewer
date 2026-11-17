#pragma once

#include <QObject>
#include <QVariant>
#include <QString>
#include <QtQml/qqmlregistration.h>

class QQmlEngine;
class QJSEngine;

// User-facing app settings (upstream Settings window): theme, packet font,
// quit confirmation, and the MCP toggles. All values live in QSettings under
// their documented keys and every change notifies QML so the UI updates live.
// The bridge's settings.* commands, the settings window, and Theme.qml all go
// through this one C++-owned QML singleton, so there is a single source of
// truth for the six keys.
//
// The MCP keys keep their F3 QSettings names (mcp/enabled, mcp/redaction);
// TCPVIEWER_MCP_ENABLED / TCPVIEWER_MCP_REDACTION still win over the stored
// values so CI/smokes can force a state without touching the user config.
class AppSettings : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    // system | light | dark (QStyleHints::setColorScheme; light/dark force the
    // palette, system follows the desktop).
    Q_PROPERTY(QString theme READ theme WRITE setTheme NOTIFY themeChanged)
    // Packet table / inspector text size, upstream's 10-24 range.
    Q_PROPERTY(int packetFontSize READ packetFontSize WRITE setPacketFontSize
                   NOTIFY packetFontSizeChanged)
    // Packet table and inspector text use the monospaced family when true,
    // the proportional UI font when false (upstream monospaced_font).
    Q_PROPERTY(bool monospacedFont READ monospacedFont WRITE setMonospacedFont
                   NOTIFY monospacedFontChanged)
    // Ask before quitting (upstream quit_confirmation).
    Q_PROPERTY(bool quitConfirmation READ quitConfirmation WRITE setQuitConfirmation
                   NOTIFY quitConfirmationChanged)
    // Upstream Settings -> MCP: the bridge refuses mcp.hello when disabled.
    Q_PROPERTY(bool mcpEnabled READ mcpEnabled WRITE setMcpEnabled NOTIFY mcpEnabledChanged)
    // Scrub sensitive keys from MCP connection results (default on).
    Q_PROPERTY(bool mcpRedaction READ mcpRedaction WRITE setMcpRedaction NOTIFY mcpRedactionChanged)

public:
    // The QML engine and the C++ side (SessionController, bridge, tests) share
    // this instance; CppOwned keeps the engine from collecting it.
    static AppSettings *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);
    static AppSettings *instance();

    // Documented setting keys (upstream command-line contract). analytics and
    // crash_reports are upstream-only; this port ships no telemetry.
    static QStringList settingKeys();
    // The documented boolean forms: true/false, yes/no, on/off, 1/0.
    static bool parseBoolText(const QString &text, bool *ok);

    QString theme() const { return m_theme; }
    void setTheme(const QString &theme);
    int packetFontSize() const { return m_packetFontSize; }
    void setPacketFontSize(int size);
    bool monospacedFont() const { return m_monospacedFont; }
    void setMonospacedFont(bool monospaced);
    bool quitConfirmation() const { return m_quitConfirmation; }
    void setQuitConfirmation(bool confirm);
    // Effective values: the CI env overrides win over the stored settings.
    bool mcpEnabled() const;
    bool mcpRedaction() const;
    void setMcpEnabled(bool enabled);
    void setMcpRedaction(bool redaction);

    // Current value for one documented key; a null QVariant for unknown keys
    // (the bridge reports that as invalid_setting).
    Q_INVOKABLE QVariant settingValue(const QString &key) const;
    // Validate and store; on failure sets a user-facing error message and
    // returns false. Values arrive as text from the CLI/MCP and as typed
    // variants from QML, so both spellings are accepted.
    Q_INVOKABLE bool setSettingValue(const QString &key, const QVariant &value, QString *error);
    // Back to defaults; resetAll() covers every key (the bridge asks for
    // confirm=true before honoring the bulk form).
    Q_INVOKABLE bool resetSettingValue(const QString &key, QString *error);
    Q_INVOKABLE QVariantList resetAll();

signals:
    void themeChanged();
    void packetFontSizeChanged();
    void monospacedFontChanged();
    void quitConfirmationChanged();
    void mcpEnabledChanged();
    void mcpRedactionChanged();

private:
    explicit AppSettings(QObject *parent = nullptr);

    void applyColorScheme();

    static AppSettings *s_instance;

    QString m_theme;
    int m_packetFontSize;
    bool m_monospacedFont;
    bool m_quitConfirmation;
};
