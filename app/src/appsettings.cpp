#include "appsettings.h"

#include <QGuiApplication>
#include <QJSEngine>
#include <QQmlEngine>
#include <QSettings>
#include <QStyleHints>

namespace {

// QSettings keys: the MCP toggles keep their F3 names; the rest live under
// settings/ so one namespace covers the window.
const char kThemeKey[] = "settings/theme";
const char kFontSizeKey[] = "settings/packet_font_size";
const char kMonoKey[] = "settings/monospaced_font";
const char kQuitKey[] = "settings/quit_confirmation";
const char kMcpEnabledKey[] = "mcp/enabled";
const char kMcpRedactionKey[] = "mcp/redaction";

QStringList keys()
{
    return {
        QStringLiteral("theme"),
        QStringLiteral("packet_font_size"),
        QStringLiteral("monospaced_font"),
        QStringLiteral("quit_confirmation"),
        QStringLiteral("mcp_enabled"),
        QStringLiteral("mcp_redaction"),
    };
}

// Normalized spelling for comparisons: separators dropped, lowercase.
QString normalized(const QString &key)
{
    QString out;
    out.reserve(key.size());
    for (const QChar &character : key) {
        const char16_t code = character.toLower().unicode();
        if (code == '-' || code == '_' || code == ' ')
            continue;
        out.append(QChar(code));
    }
    return out;
}

} // namespace

AppSettings *AppSettings::s_instance = nullptr;

AppSettings *AppSettings::create(QQmlEngine *qmlEngine, QJSEngine *jsEngine)
{
    Q_UNUSED(qmlEngine)
    if (!s_instance)
        s_instance = new AppSettings();
    if (jsEngine)
        jsEngine->setObjectOwnership(s_instance, QJSEngine::CppOwnership);
    return s_instance;
}

AppSettings *AppSettings::instance()
{
    return create(nullptr, nullptr);
}

AppSettings::AppSettings(QObject *parent)
    : QObject(parent)
{
    QSettings settings;
    m_theme = settings.value(QLatin1String(kThemeKey), QStringLiteral("system")).toString();
    if (m_theme != QLatin1String("light") && m_theme != QLatin1String("dark"))
        m_theme = QStringLiteral("system");
    m_packetFontSize = settings.value(QLatin1String(kFontSizeKey), 12).toInt();
    if (m_packetFontSize < 10 || m_packetFontSize > 24)
        m_packetFontSize = 12;
    m_monospacedFont = settings.value(QLatin1String(kMonoKey), true).toBool();
    m_quitConfirmation = settings.value(QLatin1String(kQuitKey), false).toBool();
    // The MCP values are read fresh (with the env override folded in) so a
    // CLI write takes effect without re-launching.
    applyColorScheme();
}

QStringList AppSettings::settingKeys()
{
    return keys();
}

bool AppSettings::parseBoolText(const QString &text, bool *ok)
{
    const QString value = text.trimmed().toLower();
    *ok = value == QLatin1String("1") || value == QLatin1String("true")
        || value == QLatin1String("yes") || value == QLatin1String("on")
        || value == QLatin1String("0") || value == QLatin1String("false")
        || value == QLatin1String("no") || value == QLatin1String("off");
    if (!*ok)
        return false;
    return value == QLatin1String("1") || value == QLatin1String("true")
        || value == QLatin1String("yes") || value == QLatin1String("on");
}

void AppSettings::setTheme(const QString &theme)
{
    QString error;
    if (!setSettingValue(QStringLiteral("theme"), theme, &error))
        qWarning("omarchy-tcpviewer: %s", qUtf8Printable(error));
}

void AppSettings::setPacketFontSize(int size)
{
    QString error;
    if (!setSettingValue(QStringLiteral("packet_font_size"), size, &error))
        qWarning("omarchy-tcpviewer: %s", qUtf8Printable(error));
}

void AppSettings::setMonospacedFont(bool monospaced)
{
    setSettingValue(QStringLiteral("monospaced_font"), monospaced, nullptr);
}

void AppSettings::setQuitConfirmation(bool confirm)
{
    setSettingValue(QStringLiteral("quit_confirmation"), confirm, nullptr);
}

void AppSettings::setMcpEnabled(bool enabled)
{
    setSettingValue(QStringLiteral("mcp_enabled"), enabled, nullptr);
}

void AppSettings::setMcpRedaction(bool redaction)
{
    setSettingValue(QStringLiteral("mcp_redaction"), redaction, nullptr);
}

// Env overrides (CI/smoke) win over the stored settings, mirroring the F3
// bridge behavior so a forced state cannot silently flip from the UI. A
// well-formed "0" must override too, so parse first and branch on validity.
bool AppSettings::mcpEnabled() const
{
    bool ok = false;
    const QString env = qEnvironmentVariable("TCPVIEWER_MCP_ENABLED");
    bool parsed = false;
    if (!env.isEmpty())
        parsed = parseBoolText(env, &ok);
    if (ok)
        return parsed;
    return QSettings().value(QLatin1String(kMcpEnabledKey), false).toBool();
}

bool AppSettings::mcpRedaction() const
{
    bool ok = false;
    const QString env = qEnvironmentVariable("TCPVIEWER_MCP_REDACTION");
    bool parsed = false;
    if (!env.isEmpty())
        parsed = parseBoolText(env, &ok);
    if (ok)
        return parsed;
    // Upstream default: keep redaction enabled unless there is a clear reason.
    return QSettings().value(QLatin1String(kMcpRedactionKey), true).toBool();
}

QVariant AppSettings::settingValue(const QString &key) const
{
    switch (keys().indexOf(key)) {
    case 0:
        return m_theme;
    case 1:
        return m_packetFontSize;
    case 2:
        return m_monospacedFont;
    case 3:
        return m_quitConfirmation;
    case 4:
        return mcpEnabled();
    case 5:
        return mcpRedaction();
    default:
        return {};
    }
}

bool AppSettings::setSettingValue(const QString &key, const QVariant &value, QString *error)
{
    const auto fail = [error](const QString &message) {
        if (error)
            *error = message;
        return false;
    };
    const bool typedBool = value.typeId() == QMetaType::Bool;
    switch (keys().indexOf(key)) {
    case 0: {
        const QString text = normalized(value.toString());
        if (text != QLatin1String("system") && text != QLatin1String("light")
            && text != QLatin1String("dark"))
            return fail(QStringLiteral("theme must be system, light, or dark"));
        if (text == m_theme)
            return true;
        m_theme = text;
        QSettings settings;
        settings.setValue(QLatin1String(kThemeKey), text);
        applyColorScheme();
        emit themeChanged();
        return true;
    }
    case 1: {
        bool ok = false;
        const int size = value.toInt(&ok);
        if (!ok || size < 10 || size > 24)
            return fail(QStringLiteral("packet_font_size must be 10 through 24"));
        if (size == m_packetFontSize)
            return true;
        m_packetFontSize = size;
        QSettings settings;
        settings.setValue(QLatin1String(kFontSizeKey), size);
        emit packetFontSizeChanged();
        return true;
    }
    case 2: {
        bool monospaced = false;
        if (typedBool) {
            monospaced = value.toBool();
        } else {
            bool ok = false;
            monospaced = parseBoolText(value.toString(), &ok);
            if (!ok)
                return fail(QStringLiteral("monospaced_font needs a boolean value "
                                           "(true/false, yes/no, on/off, 1/0)"));
        }
        if (monospaced == m_monospacedFont)
            return true;
        m_monospacedFont = monospaced;
        QSettings settings;
        settings.setValue(QLatin1String(kMonoKey), monospaced);
        emit monospacedFontChanged();
        return true;
    }
    case 3: {
        bool confirm = false;
        if (typedBool) {
            confirm = value.toBool();
        } else {
            bool ok = false;
            confirm = parseBoolText(value.toString(), &ok);
            if (!ok)
                return fail(QStringLiteral("quit_confirmation needs a boolean value "
                                           "(true/false, yes/no, on/off, 1/0)"));
        }
        if (confirm == m_quitConfirmation)
            return true;
        m_quitConfirmation = confirm;
        QSettings settings;
        settings.setValue(QLatin1String(kQuitKey), confirm);
        emit quitConfirmationChanged();
        return true;
    }
    case 4: {
        bool enabled = false;
        if (typedBool) {
            enabled = value.toBool();
        } else {
            bool ok = false;
            enabled = parseBoolText(value.toString(), &ok);
            if (!ok)
                return fail(QStringLiteral("mcp_enabled needs a boolean value "
                                           "(true/false, yes/no, on/off, 1/0)"));
        }
        QSettings settings;
        settings.setValue(QLatin1String(kMcpEnabledKey), enabled);
        emit mcpEnabledChanged();
        return true;
    }
    case 5: {
        bool redaction = false;
        if (typedBool) {
            redaction = value.toBool();
        } else {
            bool ok = false;
            redaction = parseBoolText(value.toString(), &ok);
            if (!ok)
                return fail(QStringLiteral("mcp_redaction needs a boolean value "
                                           "(true/false, yes/no, on/off, 1/0)"));
        }
        QSettings settings;
        settings.setValue(QLatin1String(kMcpRedactionKey), redaction);
        emit mcpRedactionChanged();
        return true;
    }
    default:
        return fail(QStringLiteral("unknown setting: ") + key);
    }
}

bool AppSettings::resetSettingValue(const QString &key, QString *error)
{
    switch (keys().indexOf(key)) {
    case 0:
        QSettings().remove(QLatin1String(kThemeKey));
        m_theme = QStringLiteral("system");
        applyColorScheme();
        emit themeChanged();
        return true;
    case 1:
        QSettings().remove(QLatin1String(kFontSizeKey));
        m_packetFontSize = 12;
        emit packetFontSizeChanged();
        return true;
    case 2:
        QSettings().remove(QLatin1String(kMonoKey));
        m_monospacedFont = true;
        emit monospacedFontChanged();
        return true;
    case 3:
        QSettings().remove(QLatin1String(kQuitKey));
        m_quitConfirmation = false;
        emit quitConfirmationChanged();
        return true;
    case 4:
        QSettings().remove(QLatin1String(kMcpEnabledKey));
        emit mcpEnabledChanged();
        return true;
    case 5:
        QSettings().remove(QLatin1String(kMcpRedactionKey));
        emit mcpRedactionChanged();
        return true;
    default:
        if (error)
            *error = QStringLiteral("unknown setting: ") + key;
        return false;
    }
}

QVariantList AppSettings::resetAll()
{
    QVariantList reset;
    for (const QString &key : keys()) {
        QString error;
        if (resetSettingValue(key, &error))
            reset.append(key);
    }
    return reset;
}

void AppSettings::applyColorScheme()
{
    // Forced schemes stick for the whole run; system restores follow-mode.
    if (auto *hints = QGuiApplication::styleHints())
        hints->setColorScheme(m_theme == QLatin1String("light")  ? Qt::ColorScheme::Light
                              : m_theme == QLatin1String("dark") ? Qt::ColorScheme::Dark
                                                                 : Qt::ColorScheme::Unknown);
}
