#include <QApplication>
#include <QCommandLineParser>
#include <QCoreApplication>
#include <QFile>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>

#include "DesktopBackend.h"
#include "SlowrollBackend.h"

int main(int argc, char *argv[])
{
    if (qEnvironmentVariableIsEmpty("QT_QUICK_CONTROLS_STYLE")) {
        QQuickStyle::setStyle(QStringLiteral("org.kde.desktop"));
    }

    QApplication app(argc, argv);

    // Set styling and organization
    QApplication::setOrganizationName(QStringLiteral("mySlowrollOS"));
    QApplication::setOrganizationDomain(QStringLiteral("myslowrollos.org"));
    QApplication::setApplicationName(QStringLiteral("myslowroll-cc"));
    QGuiApplication::setDesktopFileName(QStringLiteral("myslowroll-cc"));
    QApplication::setApplicationDisplayName(QStringLiteral("mySlowrollOS Control Center"));
    QApplication::setApplicationVersion(QStringLiteral(MYSLOWROLL_CC_VERSION));
    QApplication::setWindowIcon(QIcon::fromTheme(QStringLiteral("myslowroll-cc"), QIcon::fromTheme(QStringLiteral("preferences-system"))));

    QCommandLineParser parser;
    parser.setApplicationDescription(QStringLiteral("Centro di Controllo per openSUSE Slowroll / mySlowrollOS"));
    parser.addHelpOption();
    parser.addVersionOption();
    parser.process(app);

    DesktopBackend desktopBackend;
    SlowrollBackend slowrollBackend;
    desktopBackend.initialize();
    slowrollBackend.initialize();

    QQmlApplicationEngine engine;
    engine.addImportPath(QStringLiteral("qrc:/qt/qml"));
    engine.rootContext()->setContextProperty(QStringLiteral("DesktopBackend"), &desktopBackend);
    engine.rootContext()->setContextProperty(QStringLiteral("SlowrollBackend"), &slowrollBackend);

    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed,
                     &app, [] { QCoreApplication::exit(-1); }, Qt::QueuedConnection);

    engine.loadFromModule("org.myslowrollos.controlcenter", "Main");

    if (engine.rootObjects().isEmpty()) {
        qCritical("Impossibile caricare l'interfaccia utente QML da org.myslowrollos.controlcenter.");
        return -1;
    }

    return app.exec();
}
