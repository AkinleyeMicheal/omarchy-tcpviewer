#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QImage>
#include <QTimer>
#include <QFile>
#include <cstdio>

// Qt's default sinks are unreliable under some tooling, so always write to
// stderr and optionally mirror to a log file for headless debugging.
static void viewerMessageHandler(QtMsgType type, const QMessageLogContext &, const QString &message)
{
    Q_UNUSED(type)
    QByteArray line = message.toUtf8();
    line.append('\n');
    std::fputs(line.constData(), stderr);
    std::fflush(stderr);

    const QString logPath = qEnvironmentVariable("TCPVIEWER_LOG");
    if (!logPath.isEmpty()) {
        QFile log(logPath);
        if (log.open(QIODevice::WriteOnly | QIODevice::Append))
            log.write(line);
    }
}

int main(int argc, char *argv[])
{
    qInstallMessageHandler(viewerMessageHandler);

    QGuiApplication app(argc, argv);
    QGuiApplication::setApplicationName(QStringLiteral("Omarchy TCPViewer"));
    QGuiApplication::setOrganizationName(QStringLiteral("omarchy-tcpviewer"));
    QGuiApplication::setApplicationVersion(QStringLiteral("0.1.0"));

    // The viewer draws every control itself; don't inherit a platform style.
    QQuickStyle::setStyle(QStringLiteral("Basic"));

    QQmlApplicationEngine engine;
    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app,
        []() { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.loadFromModule("Omarchy.TCPViewer", "Main");

    // Deterministic screenshots for headless GUI verification and CI.
    const QString screenshotPath = qEnvironmentVariable("TCPVIEWER_SCREENSHOT");
    const QString placementOverride = qEnvironmentVariable("TCPVIEWER_INSPECTOR_PLACEMENT");
    if (!screenshotPath.isEmpty()) {
        bool delayOK = false;
        const int delayMs = qEnvironmentVariableIntValue("TCPVIEWER_SCREENSHOT_DELAY_MS", &delayOK);
        QTimer::singleShot(delayOK && delayMs > 0 ? delayMs : 1500, &app, [&engine, screenshotPath, placementOverride]() {
            if (!engine.rootObjects().isEmpty()) {
                if (auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().constFirst())) {
                    if (!placementOverride.isEmpty())
                        window->setProperty("inspectorPlacement", placementOverride);
                    const QImage image = window->grabWindow();
                    if (!image.save(screenshotPath))
                        qWarning("Failed to write screenshot to %s", qPrintable(screenshotPath));
                }
            }
            if (qEnvironmentVariableIsSet("TCPVIEWER_SCREENSHOT_EXIT"))
                QCoreApplication::quit();
        });
    }

    return app.exec();
}
