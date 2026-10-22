#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickStyle>

int main(int argc, char *argv[])
{
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

    return app.exec();
}
