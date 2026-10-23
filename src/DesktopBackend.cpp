#include "DesktopBackend.h"

#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QRegularExpression>
#include <QSaveFile>
#include <QStandardPaths>
#include <QStorageInfo>
#include <QHostAddress>
#include <QClipboard>
#include <QGuiApplication>
#include <QTimer>
#include <QUuid>
#include <QTextStream>
#include <QDateTime>
#include <QDesktopServices>
#include <QUrl>
#include <QSettings>
#include <QSet>
#include <algorithm>
#include <cerrno>
#include <memory>

#ifdef Q_OS_UNIX
#include <signal.h>
#include <sys/sysinfo.h>
#include <unistd.h>
#endif

namespace {
constexpr qsizetype kMaxCustomActions = 12;
constexpr qsizetype kMaxOutputBytes = 256 * 1024;

QString findTrustedSystemBinary(const QString &name)
{
    for (const QString &dir : {QStringLiteral("/usr/bin/"), QStringLiteral("/usr/sbin/"), QStringLiteral("/sbin/"), QStringLiteral("/bin/")}) {
        const QString p = dir + name;
        if (QFile::exists(p)) {
            const QFileInfo fi(p);
            if (fi.isExecutable())
                return p;
        }
    }
    return {};
}

QString findExecutableWithSbin(const QString &name)
{
    QString bin = QStandardPaths::findExecutable(name);
    if (!bin.isEmpty())
        return bin;

    const QStringList extraPaths = {
        QStringLiteral("/usr/sbin"),
        QStringLiteral("/sbin"),
        QStringLiteral("/usr/local/sbin")
    };
    for (const QString &dir : extraPaths) {
        const QString candidate = dir + QLatin1Char('/') + name;
        if (QFile::exists(candidate)) {
            const QFileInfo fi(candidate);
            if (fi.isExecutable())
                return candidate;
        }
    }
    return QString();
}

QString limitOutput(const QByteArray &data)
{
    return QString::fromUtf8(data).trimmed();
}

double readSysCpuTemp()
{
    // 1. Try hwmon (k10temp, coretemp, zenpower, etc.)
    const QDir hwmonDir(QStringLiteral("/sys/class/hwmon"));
    const QStringList hwmonEntries = hwmonDir.entryList({QStringLiteral("hwmon*")}, QDir::Dirs);
    for (const QString &entry : hwmonEntries) {
        QFile nameFile(hwmonDir.filePath(entry) + QStringLiteral("/name"));
        if (nameFile.open(QIODevice::ReadOnly | QIODevice::Text)) {
            const QString name = QString::fromUtf8(nameFile.readLine()).trimmed().toLower();
            if (name.contains(QStringLiteral("k10temp")) ||
                name.contains(QStringLiteral("coretemp")) ||
                name.contains(QStringLiteral("zenpower")) ||
                name.contains(QStringLiteral("cpu"))) {
                for (int t = 1; t <= 4; ++t) {
                    QFile tempFile(hwmonDir.filePath(entry) + QStringLiteral("/temp%1_input").arg(t));
                    if (tempFile.open(QIODevice::ReadOnly | QIODevice::Text)) {
                        bool ok = false;
                        const qint64 val = QString::fromUtf8(tempFile.readLine()).trimmed().toLongLong(&ok);
                        if (ok && val > 0)
                            return val > 1000 ? double(val) / 1000.0 : double(val);
                    }
                }
            }
        }
    }

    // 2. Try thermal zones with strict priority (x86_pkg_temp, coretemp, cpu-thermal FIRST)
    double acpitzFallback = 0.0;
    const QDir thermalDir(QStringLiteral("/sys/class/thermal"));
    const QStringList zoneEntries = thermalDir.entryList({QStringLiteral("thermal_zone*")}, QDir::Dirs, QDir::Name);
    for (const QString &zone : zoneEntries) {
        const QString basePath = thermalDir.filePath(zone);
        QFile typeFile(basePath + QStringLiteral("/type"));
        if (typeFile.open(QIODevice::ReadOnly | QIODevice::Text)) {
            const QString typeStr = QString::fromUtf8(typeFile.readLine()).trimmed().toLower();
            QFile tempFile(basePath + QStringLiteral("/temp"));
            if (tempFile.open(QIODevice::ReadOnly | QIODevice::Text)) {
                bool ok = false;
                const qint64 val = QString::fromUtf8(tempFile.readLine()).trimmed().toLongLong(&ok);
                if (ok && val > 0) {
                    const double tempC = val > 1000 ? double(val) / 1000.0 : double(val);
                    if (typeStr.contains(QStringLiteral("x86_pkg_temp")) ||
                        typeStr.contains(QStringLiteral("coretemp")) ||
                        typeStr.contains(QStringLiteral("cpu-thermal"))) {
                        return tempC;
                    }
                    if (typeStr.contains(QStringLiteral("acpitz")) && acpitzFallback == 0.0) {
                        acpitzFallback = tempC;
                    }
                }
            }
        }
    }

    if (acpitzFallback > 0.0)
        return acpitzFallback;

    // 3. Fallback to first zone
    QFile firstZone(QStringLiteral("/sys/class/thermal/thermal_zone0/temp"));
    if (firstZone.open(QIODevice::ReadOnly | QIODevice::Text)) {
        bool ok = false;
        const qint64 val = QString::fromUtf8(firstZone.readLine()).trimmed().toLongLong(&ok);
        if (ok && val > 0)
            return val > 1000 ? double(val) / 1000.0 : double(val);
    }
    return 0.0;
}
} // namespace

bool DesktopBackend::validateIpv4Cidr(const QString &ip, QString *outCleanCidr)
{
    QString ipOnly = ip.trimmed();
    QString prefix = QStringLiteral("24");
    const int slash = ipOnly.indexOf(QLatin1Char('/'));
    if (slash != -1) {
        prefix = ipOnly.mid(slash + 1).trimmed();
        ipOnly = ipOnly.left(slash).trimmed();
    }
    QHostAddress addr(ipOnly);
    if (addr.isNull() || addr.protocol() != QAbstractSocket::IPv4Protocol) {
        return false;
    }
    bool ok = false;
    int pfx = prefix.toInt(&ok);
    if (!ok || pfx < 1 || pfx > 32) {
        return false;
    }
    if (outCleanCidr) {
        *outCleanCidr = QStringLiteral("%1/%2").arg(ipOnly, QString::number(pfx));
    }
    return true;
}

bool DesktopBackend::validateGateway(const QString &gw)
{
    QHostAddress addr(gw.trimmed());
    return !addr.isNull() && addr.protocol() == QAbstractSocket::IPv4Protocol;
}

bool DesktopBackend::validateDns(const QString &dns, QStringList *outDnsServers)
{
    const QStringList servers = dns.split(QRegularExpression(QStringLiteral("[\\s,;]+")), Qt::SkipEmptyParts);
    if (servers.isEmpty()) return false;
    QStringList cleanList;
    for (const QString &s : servers) {
        QHostAddress addr(s.trimmed());
        if (addr.isNull()) return false;
        cleanList.append(s.trimmed());
    }
    if (outDnsServers) {
        *outDnsServers = cleanList;
    }
    return true;
}

DesktopBackend::DesktopBackend(QObject *parent)
    : QObject(parent)
{
    reloadCustomActions();
    loadNetworkProfiles();
}

void DesktopBackend::initialize()
{
    refreshResources();
    refreshPowerProfile();
    refreshWifiStatus();
    refreshBluetoothStatus();
    QTimer::singleShot(0, this, [this] {
        refreshNetworkStatus();
    });
}

DesktopBackend::~DesktopBackend()
{
    if (m_activeProcess && m_activeProcess->state() != QProcess::NotRunning) {
        terminateProcessGroup(m_activeProcess.data(), true);
    }
    const auto childrenProcs = findChildren<QProcess *>();
    for (QProcess *proc : childrenProcs) {
        if (proc) {
            proc->disconnect(this);
            if (proc->state() != QProcess::NotRunning) {
                terminateProcessGroup(proc, true);
                proc->waitForFinished(100);
            }
        }
    }
}

int DesktopBackend::memoryPercent() const
{
    if (m_memoryTotalMiB <= 0)
        return 0;
    return qBound(0, int((m_memoryUsedMiB * 100) / m_memoryTotalMiB), 100);
}

int DesktopBackend::diskRootPercent() const
{
    if (m_diskRootTotalGiB <= 0)
        return 0;
    const qint64 used = m_diskRootTotalGiB - m_diskRootAvailableGiB;
    return qBound(0, int((used * 100) / m_diskRootTotalGiB), 100);
}

int DesktopBackend::diskHomePercent() const
{
    if (m_diskHomeTotalGiB <= 0)
        return 0;
    const qint64 used = m_diskHomeTotalGiB - m_diskHomeAvailableGiB;
    return qBound(0, int((used * 100) / m_diskHomeTotalGiB), 100);
}

bool DesktopBackend::busy() const
{
    QMutexLocker locker(&m_busyMutex);
    return m_busy;
}

void DesktopBackend::setBusy(bool busy)
{
    {
        QMutexLocker locker(&m_busyMutex);
        if (m_busy == busy)
            return;
        m_busy = busy;
    }
    emit stateChanged();
}

void DesktopBackend::setMessage(const QString &msg)
{
    m_lastMessage = msg;
    emit stateChanged();
}

void DesktopBackend::refreshResources()
{
    // 1. CPU Usage via /proc/stat
    QFile statFile(QStringLiteral("/proc/stat"));
    if (statFile.open(QIODevice::ReadOnly | QIODevice::Text)) {
        const QList<QByteArray> parts = statFile.readLine().simplified().split(' ');
        if (parts.size() >= 5 && parts.value(0) == "cpu") {
            bool ok = false;
            quint64 user = parts.value(1).toULongLong(&ok);
            if (ok) {
                quint64 nice = parts.value(2).toULongLong(&ok);
                quint64 sys = ok ? parts.value(3).toULongLong(&ok) : 0;
                quint64 idle = ok ? parts.value(4).toULongLong(&ok) : 0;
                quint64 iowait = (ok && parts.size() > 5) ? parts.value(5).toULongLong(&ok) : 0;
                quint64 irq = (ok && parts.size() > 6) ? parts.value(6).toULongLong(&ok) : 0;
                quint64 softirq = (ok && parts.size() > 7) ? parts.value(7).toULongLong(&ok) : 0;
                quint64 steal = (ok && parts.size() > 8) ? parts.value(8).toULongLong(&ok) : 0;

                if (ok) {
                    quint64 idleTime = idle + iowait;
                    quint64 totalTime = user + nice + sys + idle + iowait + irq + softirq + steal;

                    if (m_prevCpuTotal > 0 && totalTime > m_prevCpuTotal) {
                        quint64 totalDelta = totalTime - m_prevCpuTotal;
                        quint64 idleDelta = idleTime >= m_prevCpuIdle ? idleTime - m_prevCpuIdle : 0;
                        quint64 activeDelta = totalDelta > idleDelta ? totalDelta - idleDelta : 0;
                        m_cpuUsagePercent = qBound(0, int((activeDelta * 100) / totalDelta), 100);
                    }
                    m_prevCpuTotal = totalTime;
                    m_prevCpuIdle = idleTime;
                }
            }
        }
    }

    // 2. Memory via /proc/meminfo
    QFile meminfo(QStringLiteral("/proc/meminfo"));
    if (meminfo.open(QIODevice::ReadOnly | QIODevice::Text)) {
        qint64 totalKiB = 0;
        qint64 availKiB = 0;
        while (!meminfo.atEnd()) {
            const QString line = QString::fromUtf8(meminfo.readLine());
            if (line.startsWith(QStringLiteral("MemTotal:"))) {
                const auto parts = line.split(QLatin1Char(' '), Qt::SkipEmptyParts);
                if (parts.size() >= 2) totalKiB = parts.at(1).toLongLong();
            } else if (line.startsWith(QStringLiteral("MemAvailable:"))) {
                const auto parts = line.split(QLatin1Char(' '), Qt::SkipEmptyParts);
                if (parts.size() >= 2) availKiB = parts.at(1).toLongLong();
            }
        }
        if (totalKiB > 0) {
            m_memoryTotalMiB = totalKiB / 1024;
            m_memoryUsedMiB = (totalKiB - availKiB) / 1024;
        }
    }

#ifdef Q_OS_UNIX
    if (m_memoryTotalMiB <= 0) {
        struct sysinfo si;
        if (sysinfo(&si) == 0 && si.totalram > 0) {
            const qint64 memUnit = si.mem_unit > 0 ? si.mem_unit : 1;
            m_memoryTotalMiB = (si.totalram * memUnit) / (1024LL * 1024LL);
            m_memoryUsedMiB = ((si.totalram - si.freeram) * memUnit) / (1024LL * 1024LL);
        }
    }
#endif

    // 3. CPU Temperature
    m_cpuTemperatureC = readSysCpuTemp();

    // 4. Disk Storage
    const QStorageInfo rootInfo = QStorageInfo::root();
    if (rootInfo.isValid() && rootInfo.bytesTotal() > 0) {
        m_diskRootTotalGiB = rootInfo.bytesTotal() / (1024LL * 1024LL * 1024LL);
        m_diskRootAvailableGiB = rootInfo.bytesAvailable() / (1024LL * 1024LL * 1024LL);
    }

    const QStorageInfo homeInfo(QDir::homePath());
    if (homeInfo.isValid() && homeInfo.bytesTotal() > 0) {
        m_diskHomeTotalGiB = homeInfo.bytesTotal() / (1024LL * 1024LL * 1024LL);
        m_diskHomeAvailableGiB = homeInfo.bytesAvailable() / (1024LL * 1024LL * 1024LL);
    } else {
        m_diskHomeTotalGiB = m_diskRootTotalGiB;
        m_diskHomeAvailableGiB = m_diskRootAvailableGiB;
    }

    refreshMicStatus();
    refreshPrivacyStatus();
    refreshBluetoothStatus();
    emit resourcesChanged();
}

void DesktopBackend::refreshPowerProfile()
{
    const QString kread = findExecutableWithSbin(QStringLiteral("kreadconfig6"));
    if (!kread.isEmpty()) {
        auto *proc = new QProcess(this);
        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        env.insert(QStringLiteral("LC_ALL"), QStringLiteral("C.UTF-8"));
        env.insert(QStringLiteral("LANG"), QStringLiteral("C.UTF-8"));
        proc->setProcessEnvironment(env);

        connect(proc, &QProcess::finished, this, [this, proc](int exitCode, QProcess::ExitStatus) {
            if (exitCode == 0) {
                const QString val = QString::fromUtf8(proc->readAllStandardOutput()).trimmed();
                QString detected = QStringLiteral("standard");
                if (val == QStringLiteral("3600")) {
                    detected = QStringLiteral("60min");
                } else if (val == QStringLiteral("10800")) {
                    detected = QStringLiteral("180min");
                }
                if (m_powerProfile != detected) {
                    m_powerProfile = detected;
                    emit powerProfileChanged();
                }
            }
            proc->deleteLater();
        });
        connect(proc, &QProcess::errorOccurred, proc, &QProcess::deleteLater);
        QPointer<QProcess> guard = proc;
        QTimer::singleShot(3000, proc, [guard] {
            if (guard && guard->state() != QProcess::NotRunning) guard->kill();
        });
        proc->start(kread, {QStringLiteral("--file"), QStringLiteral("powerdevilrc"),
                            QStringLiteral("--group"), QStringLiteral("AC"),
                            QStringLiteral("--group"), QStringLiteral("SuspendAndShutdown"),
                            QStringLiteral("--key"), QStringLiteral("AutoSuspendIdleTimeoutSec")});
        return;
    }

    if (m_powerProfile.isEmpty()) {
        m_powerProfile = QStringLiteral("standard");
        emit powerProfileChanged();
    }
}

void DesktopBackend::setPowerProfile(const QString &profile)
{
    const QString kwrite = findExecutableWithSbin(QStringLiteral("kwriteconfig6"));
    if (kwrite.isEmpty()) {
        setMessage(tr("kwriteconfig6 non trovato. Impossibile applicare le impostazioni energetiche."));
        return;
    }

    QStringList commands;
    if (profile == QStringLiteral("60min")) {
        commands << QStringLiteral("\"$1\" --file powerdevilrc --group AC --group Display --key TurnOffDisplayWhenIdle --type bool true");
        commands << QStringLiteral("\"$1\" --file powerdevilrc --group AC --group Display --key TurnOffDisplayIdleTimeoutSec 240");
        commands << QStringLiteral("\"$1\" --file powerdevilrc --group AC --group Display --key TurnOffDisplayIdleTimeoutWhenLockedSec 240");
        commands << QStringLiteral("\"$1\" --file powerdevilrc --group AC --group SuspendAndShutdown --key AutoSuspendAction 1");
        commands << QStringLiteral("\"$1\" --file powerdevilrc --group AC --group SuspendAndShutdown --key AutoSuspendIdleTimeoutSec 3600");
    } else if (profile == QStringLiteral("180min")) {
        commands << QStringLiteral("\"$1\" --file powerdevilrc --group AC --group Display --key TurnOffDisplayWhenIdle --type bool true");
        commands << QStringLiteral("\"$1\" --file powerdevilrc --group AC --group Display --key TurnOffDisplayIdleTimeoutSec 180");
        commands << QStringLiteral("\"$1\" --file powerdevilrc --group AC --group Display --key TurnOffDisplayIdleTimeoutWhenLockedSec 180");
        commands << QStringLiteral("\"$1\" --file powerdevilrc --group AC --group SuspendAndShutdown --key AutoSuspendAction 1");
        commands << QStringLiteral("\"$1\" --file powerdevilrc --group AC --group SuspendAndShutdown --key AutoSuspendIdleTimeoutSec 10800");
    } else {
        // Standard: rimuove le personalizzazioni sia dal gruppo annidato [AC][Display] e [AC][SuspendAndShutdown]
        // sia da eventuali chiavi flat legacy [AC]
        commands << QStringLiteral("\"$1\" --file powerdevilrc --group AC --group SuspendAndShutdown --key AutoSuspendIdleTimeoutSec --delete");
        commands << QStringLiteral("\"$1\" --file powerdevilrc --group AC --group SuspendAndShutdown --key AutoSuspendAction --delete");
        commands << QStringLiteral("\"$1\" --file powerdevilrc --group AC --group Display --key TurnOffDisplayIdleTimeoutSec --delete");
        commands << QStringLiteral("\"$1\" --file powerdevilrc --group AC --group Display --key TurnOffDisplayIdleTimeoutWhenLockedSec --delete");
        commands << QStringLiteral("\"$1\" --file powerdevilrc --group AC --group Display --key TurnOffDisplayWhenIdle --delete");
        commands << QStringLiteral("\"$1\" --file powerdevilrc --group AC --key AutoSuspendAction --delete");
        commands << QStringLiteral("\"$1\" --file powerdevilrc --group AC --key AutoSuspendIdleTimeoutSec --delete");
        commands << QStringLiteral("\"$1\" --file powerdevilrc --group AC --key TurnOffDisplayIdleTimeoutSec --delete");
        commands << QStringLiteral("\"$1\" --file powerdevilrc --group AC --key TurnOffDisplayWhenIdle --delete");
    }

    QString script = commands.join(QStringLiteral(" && "));
    const QString qdbus = findExecutableWithSbin(QStringLiteral("qdbus6"));
    if (!qdbus.isEmpty()) {
        script += QStringLiteral(" && { \"$2\" org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement org.kde.Solid.PowerManagement.reparseConfiguration >/dev/null 2>&1 || true; }");
    }

    auto *proc = new QProcess(this);
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("LC_ALL"), QStringLiteral("C.UTF-8"));
    env.insert(QStringLiteral("LANG"), QStringLiteral("C.UTF-8"));
    proc->setProcessEnvironment(env);

    connect(proc, &QProcess::finished, this, [this, profile, proc](int exitCode, QProcess::ExitStatus status) {
        if (exitCode == 0 && status == QProcess::NormalExit) {
            m_powerProfile = (profile == QStringLiteral("60min") || profile == QStringLiteral("180min")) ? profile : QStringLiteral("standard");
            emit powerProfileChanged();
            if (m_powerProfile == QStringLiteral("60min")) {
                setMessage(tr("Profilo '60 min' applicato: monitor spento dopo 4m, sospensione PC dopo 60m."));
            } else if (m_powerProfile == QStringLiteral("180min")) {
                setMessage(tr("Profilo '180 min' applicato: monitor spento dopo 3m, sospensione PC dopo 180m."));
            } else {
                setMessage(tr("Profilo Standard applicato: impostazioni e sospensione predefinite ripristinate."));
            }
        } else {
            setMessage(tr("Impossibile applicare il profilo energetico."));
        }
        proc->deleteLater();
    });
    connect(proc, &QProcess::errorOccurred, proc, &QProcess::deleteLater);
    QPointer<QProcess> guard = proc;
    QTimer::singleShot(5000, proc, [guard] {
        if (guard && guard->state() != QProcess::NotRunning) guard->kill();
    });

    proc->start(QStringLiteral("bash"), {QStringLiteral("-c"), script, QStringLiteral("mscc-power"), kwrite, qdbus});
}

void DesktopBackend::restartAudio()
{
    const QString systemctl = QStandardPaths::findExecutable(QStringLiteral("systemctl"));
    if (systemctl.isEmpty()) {
        setMessage(tr("systemctl non disponibile."));
        return;
    }
    setMessage(tr("Riavvio dello stack audio PipeWire / WirePlumber in corso..."));
    startProcess(systemctl, {
        QStringLiteral("--user"),
        QStringLiteral("restart"),
        QStringLiteral("pipewire.service"),
        QStringLiteral("pipewire-pulse.service"),
        QStringLiteral("wireplumber.service")
    }, QStringLiteral("audio-restart"), false);
}

void DesktopBackend::refreshMicStatus()
{
    if (m_micProc && m_micProc->state() != QProcess::NotRunning)
        return;

    const QString wpctl = findExecutableWithSbin(QStringLiteral("wpctl"));
    if (wpctl.isEmpty())
        return;

    auto *proc = new QProcess(this);
    m_micProc = proc;

    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("LC_ALL"), QStringLiteral("C.UTF-8"));
    env.insert(QStringLiteral("LANG"), QStringLiteral("C.UTF-8"));
    proc->setProcessEnvironment(env);

    connect(proc, &QProcess::finished, this, [this, proc](int exitCode, QProcess::ExitStatus status) {
        if (m_micProc == proc)
            m_micProc = nullptr;
        if (status == QProcess::NormalExit && exitCode == 0) {
            const QString output = QString::fromUtf8(proc->readAllStandardOutput());
            const bool muted = output.contains(QStringLiteral("MUTED"));
            if (m_micMuted != muted) {
                m_micMuted = muted;
                emit micStatusChanged();
            }
        }
        proc->deleteLater();
    });

    connect(proc, &QProcess::errorOccurred, this, [this, proc](QProcess::ProcessError) {
        if (m_micProc == proc)
            m_micProc = nullptr;
        proc->deleteLater();
    });

    QPointer<QProcess> guard = proc;
    QTimer::singleShot(1500, proc, [guard] {
        if (guard && guard->state() != QProcess::NotRunning)
            guard->kill();
    });

    proc->start(wpctl, {QStringLiteral("get-volume"), QStringLiteral("@DEFAULT_AUDIO_SOURCE@")});
}

void DesktopBackend::toggleMic()
{
    const QString wpctl = findExecutableWithSbin(QStringLiteral("wpctl"));
    if (wpctl.isEmpty()) {
        setMessage(tr("wpctl non trovato."));
        return;
    }

    auto *proc = new QProcess(this);
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("LC_ALL"), QStringLiteral("C.UTF-8"));
    env.insert(QStringLiteral("LANG"), QStringLiteral("C.UTF-8"));
    proc->setProcessEnvironment(env);

    connect(proc, &QProcess::finished, this, [this, proc](int, QProcess::ExitStatus) {
        proc->deleteLater();
        refreshMicStatus();
    });
    connect(proc, &QProcess::errorOccurred, proc, &QProcess::deleteLater);

    QPointer<QProcess> guard = proc;
    QTimer::singleShot(1500, proc, [guard] {
        if (guard && guard->state() != QProcess::NotRunning)
            guard->kill();
    });

    proc->start(wpctl, {QStringLiteral("set-mute"), QStringLiteral("@DEFAULT_AUDIO_SOURCE@"), QStringLiteral("toggle")});
}

void DesktopBackend::refreshPrivacyStatus()
{
    const QString stateFilePath = QStringLiteral("/run/myslowroll-privacy/state");
    bool active = false;
    QFile file(stateFilePath);
    if (file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        const QString state = QString::fromUtf8(file.readLine()).trimmed();
        active = (state == QStringLiteral("on"));
        file.close();
    }
    if (m_privacyActive != active) {
        m_privacyActive = active;
        emit privacyStatusChanged();
    }
}

void DesktopBackend::togglePrivacy()
{
    launchCustomScript(QStringLiteral("Privacy"));
}

void DesktopBackend::flushDns()
{
    const QString resolvectl = findExecutableWithSbin(QStringLiteral("resolvectl"));
    if (!resolvectl.isEmpty()) {
        startProcess(resolvectl, {QStringLiteral("flush-caches")}, QStringLiteral("flush-dns"), false);
        return;
    }
    setMessage(tr("Nessun gestore di cache DNS locale attivo supportato (resolvectl non disponibile)."));
}

bool DesktopBackend::isToolAvailable(const QString &toolId) const
{
    if (toolId == QStringLiteral("yast") || toolId == QStringLiteral("yast-software") || toolId == QStringLiteral("yast-repos") || toolId == QStringLiteral("yast-snapper")) {
        return !findExecutableWithSbin(QStringLiteral("yast2")).isEmpty();
    } else if (toolId == QStringLiteral("discover")) {
        return !findExecutableWithSbin(QStringLiteral("plasma-discover")).isEmpty();
    } else if (toolId == QStringLiteral("systemmonitor")) {
        return !findExecutableWithSbin(QStringLiteral("plasma-systemmonitor")).isEmpty();
    } else if (toolId == QStringLiteral("kinfocenter")) {
        return !findExecutableWithSbin(QStringLiteral("kinfocenter")).isEmpty();
    } else if (toolId == QStringLiteral("ksystemlog")) {
        return !findExecutableWithSbin(QStringLiteral("ksystemlog")).isEmpty();
    } else if (toolId == QStringLiteral("backintime")) {
        return !findExecutableWithSbin(QStringLiteral("backintime-qt")).isEmpty() ||
               !findExecutableWithSbin(QStringLiteral("backintime")).isEmpty();
    } else if (toolId == QStringLiteral("qdirstat")) {
        return !findExecutableWithSbin(QStringLiteral("qdirstat")).isEmpty();
    } else if (toolId == QStringLiteral("konsole")) {
        return !findExecutableWithSbin(QStringLiteral("konsole")).isEmpty();
    } else if (toolId == QStringLiteral("settings")) {
        return !findExecutableWithSbin(QStringLiteral("systemsettings")).isEmpty();
    } else if (toolId == QStringLiteral("kdeconnect") || toolId == QStringLiteral("kdeconnect-app")) {
        return !findExecutableWithSbin(QStringLiteral("kdeconnect-app")).isEmpty() ||
               !findExecutableWithSbin(QStringLiteral("kdeconnect-settings")).isEmpty();
    } else if (toolId == QStringLiteral("mast-git") || toolId == QStringLiteral("git-config")) {
        for (const QString &base : {QStringLiteral("/usr/lib"), QStringLiteral("/usr/lib64")}) {
            const QDir dir(base);
            for (const QString &pyDir : dir.entryList({QStringLiteral("python3*")}, QDir::Dirs)) {
                if (QFile::exists(QStringLiteral("%1/%2/site-packages/mast/qt6/git").arg(base, pyDir)))
                    return true;
            }
        }
        return false;
    } else if (toolId == QStringLiteral("mast-android") || toolId == QStringLiteral("android-manager")) {
        for (const QString &base : {QStringLiteral("/usr/lib"), QStringLiteral("/usr/lib64")}) {
            const QDir dir(base);
            for (const QString &pyDir : dir.entryList({QStringLiteral("python3*")}, QDir::Dirs)) {
                if (QFile::exists(QStringLiteral("%1/%2/site-packages/mast/qt6/android").arg(base, pyDir)))
                    return true;
            }
        }
        return false;
    } else if (toolId == QStringLiteral("kontainer") || toolId == QStringLiteral("distrobox-gui") || toolId == QStringLiteral("boxbuddy")) {
        const QString homeFlatpak = QDir::homePath() + QStringLiteral("/.local/share/flatpak/app");
        return !findExecutableWithSbin(QStringLiteral("boxbuddy")).isEmpty() ||
               !findExecutableWithSbin(QStringLiteral("kontainer")).isEmpty() ||
               QFile::exists(QStringLiteral("/var/lib/flatpak/app/io.github.dvlv.boxbuddyrs")) ||
               QFile::exists(homeFlatpak + QStringLiteral("/io.github.dvlv.boxbuddyrs")) ||
               QFile::exists(QStringLiteral("/var/lib/flatpak/app/io.github.DenysMb.Kontainer")) ||
               QFile::exists(homeFlatpak + QStringLiteral("/io.github.DenysMb.Kontainer")) ||
               QFile::exists(QStringLiteral("/var/lib/flatpak/app/com.github.DenysMb.Kontainer")) ||
               QFile::exists(homeFlatpak + QStringLiteral("/com.github.DenysMb.Kontainer"));
    } else if (toolId == QStringLiteral("cockpit")) {
        return !findExecutableWithSbin(QStringLiteral("cockpit-client")).isEmpty() ||
               !findExecutableWithSbin(QStringLiteral("cockpit-client-launcher")).isEmpty() ||
               QFile::exists(QStringLiteral("/usr/lib/cockpit/cockpit-ws")) ||
               QFile::exists(QStringLiteral("/usr/libexec/cockpit-ws")) ||
               QFile::exists(QStringLiteral("/usr/lib/systemd/system/cockpit.socket"));
    } else if (toolId == QStringLiteral("plasma-firewall")) {
        return !findExecutableWithSbin(QStringLiteral("kcmshell6")).isEmpty() ||
               !findExecutableWithSbin(QStringLiteral("systemsettings")).isEmpty();
    } else if (toolId == QStringLiteral("partitionmanager")) {
        return !findExecutableWithSbin(QStringLiteral("partitionmanager")).isEmpty();
    }
    return !findExecutableWithSbin(toolId).isEmpty();
}

bool DesktopBackend::launchTool(const QString &toolId)
{
    if (toolId == QStringLiteral("mast-git") || toolId == QStringLiteral("git-config")) {
        const QString pyCode = QStringLiteral(
            "import sys; from PySide6.QtWidgets import QApplication; "
            "from mast.core.i18n import init_i18n; from mast.qt6.git.window import GitWindow; "
            "init_i18n(); app = QApplication.instance() or QApplication(sys.argv); "
            "w = GitWindow(); w.setWindowTitle('Configurazione Git'); w.show(); sys.exit(app.exec())"
        );
        return QProcess::startDetached(QStringLiteral("python3"), {QStringLiteral("-c"), pyCode});
    }

    if (toolId == QStringLiteral("mast-android") || toolId == QStringLiteral("android-manager")) {
        const QString pyCode = QStringLiteral(
            "import sys; from PySide6.QtWidgets import QApplication; "
            "from mast.core.i18n import init_i18n; from mast.qt6.android.window import AndroidWindow; "
            "init_i18n(); app = QApplication.instance() or QApplication(sys.argv); "
            "w = AndroidWindow(); w.setWindowTitle('Gestione Dispositivi Android (ADB)'); w.show(); sys.exit(app.exec())"
        );
        return QProcess::startDetached(QStringLiteral("python3"), {QStringLiteral("-c"), pyCode});
    }

    if (toolId == QStringLiteral("kdeconnect") || toolId == QStringLiteral("kdeconnect-app")) {
        if (!findExecutableWithSbin(QStringLiteral("kdeconnect-app")).isEmpty()) {
            return QProcess::startDetached(findExecutableWithSbin(QStringLiteral("kdeconnect-app")), {});
        }
        if (!findExecutableWithSbin(QStringLiteral("kdeconnect-settings")).isEmpty()) {
            return QProcess::startDetached(findExecutableWithSbin(QStringLiteral("kdeconnect-settings")), {});
        }
    }

    if (toolId == QStringLiteral("yast-software")) {
        return launchYastModule(QStringLiteral("sw_single"));
    }

    if (toolId == QStringLiteral("yast-repos")) {
        return launchYastModule(QStringLiteral("repositories"));
    }

    if (toolId == QStringLiteral("yast-snapper") || toolId == QStringLiteral("snapper-gui")) {
        return launchYastModule(QStringLiteral("snapper"));
    }

    if (toolId == QStringLiteral("kontainer") || toolId == QStringLiteral("distrobox-gui") || toolId == QStringLiteral("boxbuddy")) {
        const QString homeFlatpak = QDir::homePath() + QStringLiteral("/.local/share/flatpak/app");
        const QString kontainer = findExecutableWithSbin(QStringLiteral("kontainer"));
        if (!kontainer.isEmpty()) {
            return QProcess::startDetached(kontainer, {});
        }
        for (const QString &appId : {QStringLiteral("io.github.DenysMb.Kontainer"), QStringLiteral("com.github.DenysMb.Kontainer")}) {
            if (QFile::exists(QStringLiteral("/var/lib/flatpak/app/") + appId) ||
                QFile::exists(homeFlatpak + QLatin1Char('/') + appId)) {
                return QProcess::startDetached(QStringLiteral("flatpak"), {QStringLiteral("run"), appId});
            }
        }
        const QString boxbuddy = findExecutableWithSbin(QStringLiteral("boxbuddy"));
        if (!boxbuddy.isEmpty()) {
            return QProcess::startDetached(boxbuddy, {});
        }
        if (QFile::exists(QStringLiteral("/var/lib/flatpak/app/io.github.dvlv.boxbuddyrs")) ||
            QFile::exists(homeFlatpak + QStringLiteral("/io.github.dvlv.boxbuddyrs"))) {
            return QProcess::startDetached(QStringLiteral("flatpak"), {QStringLiteral("run"), QStringLiteral("io.github.dvlv.boxbuddyrs")});
        }
        const QString podman = findExecutableWithSbin(QStringLiteral("podman-desktop"));
        if (!podman.isEmpty()) {
            return QProcess::startDetached(podman, {});
        }
        if (QFile::exists(QStringLiteral("/var/lib/flatpak/app/io.podman_desktop.PodmanDesktop")) ||
            QFile::exists(homeFlatpak + QStringLiteral("/io.podman_desktop.PodmanDesktop"))) {
            return QProcess::startDetached(QStringLiteral("flatpak"), {QStringLiteral("run"), QStringLiteral("io.podman_desktop.PodmanDesktop")});
        }
        return QProcess::startDetached(QStringLiteral("plasma-discover"), {QStringLiteral("--search"), QStringLiteral("kontainer")});
    }

    if (toolId == QStringLiteral("podman-desktop")) {
        const QString homeFlatpak = QDir::homePath() + QStringLiteral("/.local/share/flatpak/app");
        const QString podman = findExecutableWithSbin(QStringLiteral("podman-desktop"));
        if (!podman.isEmpty()) {
            return QProcess::startDetached(podman, {});
        }
        if (QFile::exists(QStringLiteral("/var/lib/flatpak/app/io.podman_desktop.PodmanDesktop")) ||
            QFile::exists(homeFlatpak + QStringLiteral("/io.podman_desktop.PodmanDesktop"))) {
            return QProcess::startDetached(QStringLiteral("flatpak"), {QStringLiteral("run"), QStringLiteral("io.podman_desktop.PodmanDesktop")});
        }
        return QProcess::startDetached(QStringLiteral("plasma-discover"), {QStringLiteral("--search"), QStringLiteral("podman-desktop")});
    }

    if (toolId == QStringLiteral("cockpit")) {
        const QString launcher = findExecutableWithSbin(QStringLiteral("cockpit-client-launcher"));
        if (!launcher.isEmpty()) {
            return QProcess::startDetached(launcher, {});
        }
        const QString client = findExecutableWithSbin(QStringLiteral("cockpit-client"));
        if (!client.isEmpty()) {
            return QProcess::startDetached(client, {});
        }
        const QString systemctl = findExecutableWithSbin(QStringLiteral("systemctl"));
        if (!systemctl.isEmpty()) {
            QProcess::startDetached(systemctl, {QStringLiteral("start"), QStringLiteral("cockpit.socket")});
        }
        return QDesktopServices::openUrl(QUrl(QStringLiteral("https://localhost:9090")));
    }

    if (toolId == QStringLiteral("plasma-firewall")) {
        const QString kcmshell = findExecutableWithSbin(QStringLiteral("kcmshell6"));
        if (!kcmshell.isEmpty()) {
            return QProcess::startDetached(kcmshell, {QStringLiteral("kcm_firewall")});
        }
        const QString settings = findExecutableWithSbin(QStringLiteral("systemsettings"));
        if (!settings.isEmpty()) {
            return QProcess::startDetached(settings, {QStringLiteral("kcm_firewall")});
        }
        setMessage(tr("Modulo Firewall di Plasma non trovato."));
        return false;
    }

    if (toolId == QStringLiteral("partitionmanager")) {
        const QString pm = findExecutableWithSbin(QStringLiteral("partitionmanager"));
        if (!pm.isEmpty()) {
            return QProcess::startDetached(pm, {});
        }
        setMessage(tr("KDE Partition Manager non trovato su questo sistema."));
        return false;
    }

    QString program;
    QStringList args;

    if (toolId == QStringLiteral("yast")) {
        return launchYastModule(QString());
    } else if (toolId == QStringLiteral("discover")) {
        program = QStringLiteral("plasma-discover");
    } else if (toolId == QStringLiteral("systemmonitor")) {
        program = QStringLiteral("plasma-systemmonitor");
    } else if (toolId == QStringLiteral("kinfocenter")) {
        program = QStringLiteral("kinfocenter");
    } else if (toolId == QStringLiteral("ksystemlog")) {
        program = QStringLiteral("ksystemlog");
    } else if (toolId == QStringLiteral("backintime")) {
        program = findExecutableWithSbin(QStringLiteral("backintime-qt"));
        if (program.isEmpty()) program = QStringLiteral("backintime");
    } else if (toolId == QStringLiteral("qdirstat")) {
        program = QStringLiteral("qdirstat");
    } else if (toolId == QStringLiteral("konsole")) {
        program = QStringLiteral("konsole");
    } else if (toolId == QStringLiteral("settings")) {
        program = QStringLiteral("systemsettings");
    } else {
        program = toolId;
    }

    const QString bin = findExecutableWithSbin(program);
    if (bin.isEmpty()) {
        setMessage(tr("Strumento non trovato: %1").arg(toolId));
        return false;
    }
    return QProcess::startDetached(bin, args);
}

bool DesktopBackend::launchYastModule(const QString &moduleName)
{
    static const QRegularExpression modRx(QStringLiteral("^[A-Za-z0-9_-]*$"));
    if (!modRx.match(moduleName).hasMatch()) {
        setMessage(tr("Nome modulo YaST non valido."));
        return false;
    }
    const QString yast = findExecutableWithSbin(QStringLiteral("yast2"));
    if (yast.isEmpty()) {
        setMessage(tr("YaST2 non è presente su questo sistema."));
        return false;
    }
    // YaST richiede sempre privilegi di amministrazione (root)
    const QString xdgSu = findExecutableWithSbin(QStringLiteral("xdg-su"));
    if (!xdgSu.isEmpty()) {
        const QString cmd = moduleName.isEmpty() ? yast : QStringLiteral("%1 %2").arg(yast, moduleName);
        return QProcess::startDetached(xdgSu, {QStringLiteral("-c"), cmd});
    }
    const QString pkexec = findExecutableWithSbin(QStringLiteral("pkexec"));
    if (!pkexec.isEmpty()) {
        QStringList pkArgs = {yast};
        if (!moduleName.isEmpty()) pkArgs.append(moduleName);
        return QProcess::startDetached(pkexec, pkArgs);
    }
    return QProcess::startDetached(yast, moduleName.isEmpty() ? QStringList{} : QStringList{moduleName});
}

bool DesktopBackend::launchCustomScript(const QString &scriptName)
{
    const QString cleanName = scriptName.trimmed();
    if (cleanName.isEmpty())
        return false;

    static const QRegularExpression nameRx(QStringLiteral("^[A-Za-z0-9_-]+$"));
    if (!nameRx.match(cleanName).hasMatch()) {
        setMessage(tr("Nome script non valido."));
        return false;
    }

    // Gli script shipped (Privacy, Mic) vanno SEMPRE presi dal percorso di sistema:
    // le directory utente scrivibili non devono poter alterare il comportamento ufficiale.
    static const QSet<QString> shippedScripts = {
        QStringLiteral("privacy"),
        QStringLiteral("mic")
    };

    const QString configScriptsDir = QStandardPaths::writableLocation(QStandardPaths::ConfigLocation) + QStringLiteral("/myslowroll-cc/scripts");
    QDir().mkpath(configScriptsDir);
    const QString homeBin = QDir::homePath() + QStringLiteral("/.local/bin");
    const QString systemScriptsDir = QStringLiteral("/usr/share/myslowroll-cc/scripts");

    const QStringList names = { cleanName, cleanName.toLower(), cleanName.toUpper() };
    const bool isShipped = shippedScripts.contains(cleanName.toLower());

    QStringList candidates;
    for (const QString &n : names) {
        if (!isShipped) {
            candidates << configScriptsDir + QLatin1Char('/') + n
                       << configScriptsDir + QLatin1Char('/') + n + QStringLiteral(".sh")
                       << homeBin + QLatin1Char('/') + n
                       << homeBin + QLatin1Char('/') + n + QStringLiteral(".sh");
        }
        candidates << systemScriptsDir + QLatin1Char('/') + n
                   << systemScriptsDir + QLatin1Char('/') + n + QStringLiteral(".sh");
    }

    QString foundPath;
    for (const QString &p : candidates) {
        if (QFile::exists(p)) {
            foundPath = p;
            break;
        }
    }

    if (!foundPath.isEmpty()) {
        const bool isMic = (cleanName.compare(QStringLiteral("mic"), Qt::CaseInsensitive) == 0);
        const bool isPrivacy = (cleanName.compare(QStringLiteral("privacy"), Qt::CaseInsensitive) == 0);

        if (!isMic && busy()) {
            setMessage(tr("Un'altra operazione è già in esecuzione."));
            return false;
        }

        auto *proc = new QProcess(this);
#ifdef Q_OS_UNIX
        proc->setChildProcessModifier([] { ::setpgid(0, 0); });
#endif
        if (!isMic) {
            setBusy(true);
        }

        connect(proc, &QProcess::finished, this, [this, proc, cleanName, isMic, isPrivacy](int exitCode, QProcess::ExitStatus) {
            if (!isMic) {
                setBusy(false);
            }
            if (isMic) {
                refreshMicStatus();
            } else if (isPrivacy) {
                refreshPrivacyStatus();
                refreshMicStatus();
                refreshNetworkStatus();
                refreshBluetoothStatus();
                if (exitCode == 0) {
                    setMessage(m_privacyActive
                               ? tr("Modalità Privacy ATTIVATA.")
                               : tr("Modalità Privacy DISATTIVATA (stato base ripristinato)."));
                } else if (exitCode == 126 || exitCode == 127) {
                    setMessage(tr("Autenticazione PolKit annullata."));
                } else {
                    setMessage(tr("Operazione Privacy terminata con avvisi/errori (codice %1).").arg(exitCode));
                }
            }
            proc->deleteLater();
        });
        connect(proc, &QProcess::errorOccurred, this, [this, proc, foundPath, isMic](QProcess::ProcessError err) {
            if (err == QProcess::FailedToStart) {
                if (!isMic) {
                    setBusy(false);
                }
                setMessage(tr("Impossibile avviare lo script: %1").arg(foundPath));
                proc->deleteLater();
            }
        });

        if (!isPrivacy) {
            QPointer<QProcess> guard = proc;
            QTimer::singleShot(60000, proc, [this, guard] {
                if (guard && guard->state() != QProcess::NotRunning)
                    terminateProcessGroup(guard.data(), true);
            });
        }

        proc->start(QStringLiteral("bash"), {foundPath});
        if (!isMic) {
            setMessage(tr("Esecuzione script '%1' in corso...").arg(cleanName));
        }
        return true;
    }

    if (isShipped) {
        const QString sysPath = systemScriptsDir + QLatin1Char('/') + cleanName.toLower() + QStringLiteral(".sh");
        setMessage(tr("Script di sistema '%1' non trovato in: %2").arg(cleanName, sysPath));
    } else {
        const QString defaultPath = configScriptsDir + QLatin1Char('/') + cleanName + QStringLiteral(".sh");
        setMessage(tr("Script '%1' non trovato. Creare il file in: %2").arg(cleanName, defaultPath));
    }
    return false;
}

void DesktopBackend::runCommand(const QString &commandLine, const QString &title)
{
    const QString cmd = commandLine.trimmed();
    if (cmd.isEmpty())
        return;

    // Sanificazione per prevenire command injection, subshell, wildcard e concatenazioni arbitrarie
    if (cmd.contains(QLatin1Char(';')) || cmd.contains(QStringLiteral("&&")) ||
        cmd.contains(QStringLiteral("||")) || cmd.contains(QLatin1Char('>')) ||
        cmd.contains(QLatin1Char('<')) || cmd.contains(QLatin1Char('$')) ||
        cmd.contains(QLatin1Char('`')) || cmd.contains(QLatin1Char('&')) ||
        cmd.contains(QLatin1Char('\n')) || cmd.contains(QLatin1Char('\r')) ||
        cmd.contains(QLatin1Char('(')) || cmd.contains(QLatin1Char(')')) ||
        cmd.contains(QLatin1Char('{')) || cmd.contains(QLatin1Char('}')) ||
        cmd.contains(QLatin1Char('*')) || cmd.contains(QLatin1Char('\'')) ||
        cmd.contains(QLatin1Char('"')) || cmd.contains(QLatin1Char('\\'))) {
        setMessage(tr("Comando non valido: caratteri speciali, apici o subshell non consentiti."));
        return;
    }

    static const QSet<QString> allowedDiagnosticBinaries = {
        QStringLiteral("glxinfo"), QStringLiteral("vulkaninfo"), QStringLiteral("systemctl"),
        QStringLiteral("journalctl"), QStringLiteral("uptime"), QStringLiteral("systemd-analyze"),
        QStringLiteral("ss"), QStringLiteral("ip"), QStringLiteral("resolvectl"),
        QStringLiteral("lsblk"), QStringLiteral("df"), QStringLiteral("loginctl"),
        QStringLiteral("printenv")
    };
    static const QSet<QString> allowedFilters = {
        QStringLiteral("head"), QStringLiteral("tail"), QStringLiteral("grep"), QStringLiteral("wc")
    };

    QString leftPart = cmd;
    if (cmd.contains(QLatin1Char('|'))) {
        const QStringList pipeParts = cmd.split(QLatin1Char('|'));
        if (pipeParts.size() != 2) {
            setMessage(tr("Comando non valido: pipeline multiple non consentite."));
            return;
        }
        leftPart = pipeParts.at(0).trimmed();
        const QString right = pipeParts.at(1).trimmed();
        const QString filterBin = right.section(QRegularExpression(QStringLiteral("\\s+")), 0, 0);
        if (!allowedFilters.contains(filterBin)) {
            setMessage(tr("Comando non valido: pipe consentita solo verso comandi di filtro (head, tail, grep, wc)."));
            return;
        }
    }

    const QString mainBin = leftPart.section(QRegularExpression(QStringLiteral("\\s+")), 0, 0);
    if (!allowedDiagnosticBinaries.contains(mainBin)) {
        setMessage(tr("Comando non valido: binario diagnostico non autorizzato (%1).").arg(mainBin));
        return;
    }

    if (m_busy) {
        setMessage(tr("Un'altra operazione è già in esecuzione."));
        return;
    }

#ifdef Q_OS_UNIX
    if (::geteuid() == 0) {
        m_diagnosticTitle = tr("Accesso negato");
        m_diagnosticOutput = tr("I comandi shell non possono essere eseguiti con privilegi root diretti.");
        emit diagnosticChanged();
        return;
    }
#endif

    m_diagnosticTitle = title.isEmpty() ? cmd : title;
    m_diagnosticOutput = tr("Esecuzione del comando in corso: %1...").arg(cmd);
    emit diagnosticChanged();

    startProcess(QStringLiteral("bash"), {QStringLiteral("-c"), cmd}, QStringLiteral("diagnostic"), true, 60000);
}

void DesktopBackend::clearDiagnostic()
{
    m_diagnosticTitle.clear();
    m_diagnosticOutput.clear();
    emit diagnosticChanged();
}

void DesktopBackend::clearMessage()
{
    m_lastMessage.clear();
    emit stateChanged();
}

void DesktopBackend::copyToClipboard(const QString &text)
{
    QGuiApplication::clipboard()->setText(text);
    setMessage(tr("Comando copiato negli appunti."));
}

QString DesktopBackend::customActionsFilePath() const
{
    const QString configDir = QStandardPaths::writableLocation(QStandardPaths::ConfigLocation);
    return QDir(configDir).filePath(QStringLiteral("myslowroll-cc/custom-actions.json"));
}

int DesktopBackend::customActionIndex(const QString &id) const
{
    for (int i = 0; i < m_customActions.size(); ++i) {
        if (m_customActions.at(i).toMap().value(QStringLiteral("id")).toString() == id)
            return i;
    }
    return -1;
}

void DesktopBackend::reloadCustomActions()
{
    m_customActions.clear();
    const QString path = customActionsFilePath();
    QFile file(path);
    if (!file.exists()) {
        m_customActionsLoaded = true;
        emit customActionsChanged();
        return;
    }
    if (!file.open(QIODevice::ReadOnly)) {
        m_customActionsLoaded = false;
        m_actionError = tr("Impossibile aprire il file delle azioni personali. Salvataggio disabilitato per proteggere i dati.");
        emit customActionsChanged();
        emit actionStateChanged();
        return;
    }

    QJsonParseError parseError;
    const QByteArray fileData = file.readAll();
    file.close();
    const QJsonDocument doc = QJsonDocument::fromJson(fileData, &parseError);
    if (parseError.error != QJsonParseError::NoError || !doc.isObject()) {
        m_customActionsLoaded = false;
        const QString bakPath = path + QStringLiteral(".bak");
        if (!QFile::exists(bakPath) && !QFile::copy(path, bakPath)) {
            m_actionError = tr("File delle azioni personali danneggiato e impossibile creare copia .bak. Salvataggio sospeso.");
        } else {
            m_actionError = tr("File delle azioni personali non valido o danneggiato. Salvataggio sospeso per proteggere i dati.");
        }
        emit customActionsChanged();
        emit actionStateChanged();
        return;
    }
    m_customActionsLoaded = true;
    const QJsonArray arr = doc.object().value(QStringLiteral("actions")).toArray();

    for (const QJsonValue &val : arr) {
        if (!val.isObject()) continue;
        const QJsonObject obj = val.toObject();
        QVariantMap map;
        map.insert(QStringLiteral("id"), obj.value(QStringLiteral("id")).toString());
        map.insert(QStringLiteral("name"), obj.value(QStringLiteral("name")).toString());
        map.insert(QStringLiteral("script"), obj.value(QStringLiteral("script")).toString());
        map.insert(QStringLiteral("confirm"), obj.value(QStringLiteral("confirm")).toBool(true));
        map.insert(QStringLiteral("icon"), obj.value(QStringLiteral("icon")).toString(QStringLiteral("utilities-terminal")));
        m_customActions.append(map);
    }
    emit customActionsChanged();
}

bool DesktopBackend::resetCustomActionsToDefault()
{
    const QString path = customActionsFilePath();
    QString archivedPath;
    if (QFile::exists(path)) {
        const QString timestamp = QDateTime::currentDateTime().toString(QStringLiteral("yyyyMMdd_hhmmss_zzz"));
        const QString corruptArchive = path + QStringLiteral(".corrupt-") + timestamp;
        if (!QFile::rename(path, corruptArchive)) {
            m_actionError = tr("Impossibile archiviare il file precedente delle azioni personali.");
            emit actionStateChanged();
            return false;
        }
        archivedPath = corruptArchive;
    }
    m_customActions.clear();
    m_customActionsLoaded = true;
    m_actionError.clear();
    const bool ok = persistCustomActions();
    if (ok) {
        setMessage(tr("Azioni personali ripristinate (file precedente archiviato)."));
    } else if (m_actionError.isEmpty()) {
        m_actionError = archivedPath.isEmpty()
            ? tr("Impossibile ricreare il file delle azioni personali.")
            : tr("Impossibile ricreare il file delle azioni personali. Il contenuto precedente è in %1.").arg(archivedPath);
    }
    emit customActionsChanged();
    emit actionStateChanged();
    return ok;
}

bool DesktopBackend::persistCustomActions()
{
    if (!m_customActionsLoaded) {
        m_actionError = tr("Salvataggio impedito: il file delle azioni personali non è stato caricato correttamente.");
        emit actionStateChanged();
        return false;
    }
    const QString path = customActionsFilePath();
    QFileInfo info(path);
    if (!QDir().mkpath(info.absolutePath()))
        return false;

    QJsonArray arr;
    for (const QVariant &var : m_customActions) {
        const QVariantMap map = var.toMap();
        QJsonObject obj;
        obj.insert(QStringLiteral("id"), map.value(QStringLiteral("id")).toString());
        obj.insert(QStringLiteral("name"), map.value(QStringLiteral("name")).toString());
        obj.insert(QStringLiteral("script"), map.value(QStringLiteral("script")).toString());
        obj.insert(QStringLiteral("confirm"), map.value(QStringLiteral("confirm")).toBool());
        obj.insert(QStringLiteral("icon"), map.value(QStringLiteral("icon")).toString());
        arr.append(obj);
    }

    QJsonObject root;
    root.insert(QStringLiteral("schema"), 1);
    root.insert(QStringLiteral("actions"), arr);

    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly) ||
        file.write(QJsonDocument(root).toJson(QJsonDocument::Indented)) < 0 ||
        !file.commit()) {
        return false;
    }
    return true;
}

bool DesktopBackend::saveCustomAction(const QString &id, const QString &name,
                                      const QString &script, bool confirmBeforeRun,
                                      const QString &icon)
{
    if (name.trimmed().isEmpty() || script.trimmed().isEmpty()) {
        m_actionError = tr("Nome e script non possono essere vuoti.");
        emit actionStateChanged();
        return false;
    }

    if (script.length() > 8192) {
        m_actionError = tr("Lo script supera la lunghezza massima consentita (8 KB).");
        emit actionStateChanged();
        return false;
    }

    const QString actionId = id.trimmed().isEmpty() ? QUuid::createUuid().toString(QUuid::WithoutBraces) : id.trimmed();
    int idx = customActionIndex(actionId);

    if (idx < 0 && m_customActions.size() >= kMaxCustomActions) {
        m_actionError = tr("Limite massimo di %1 azioni personali raggiunto.").arg(kMaxCustomActions);
        emit actionStateChanged();
        return false;
    }

    QVariantMap map;
    map.insert(QStringLiteral("id"), actionId);
    map.insert(QStringLiteral("name"), name.trimmed());
    map.insert(QStringLiteral("script"), script);
    map.insert(QStringLiteral("confirm"), confirmBeforeRun);
    QString resolvedIcon = icon.trimmed();
    if (resolvedIcon.isEmpty()) {
        if (idx >= 0) {
            resolvedIcon = m_customActions[idx].toMap().value(QStringLiteral("icon")).toString();
        }
        if (resolvedIcon.isEmpty()) {
            resolvedIcon = QStringLiteral("utilities-terminal");
        }
    }
    map.insert(QStringLiteral("icon"), resolvedIcon);

    if (idx >= 0) {
        m_customActions[idx] = map;
    } else {
        m_customActions.append(map);
    }

    if (!persistCustomActions()) {
        const QString specificError = m_actionError.isEmpty() ? tr("Errore durante il salvataggio su disco.") : m_actionError;
        reloadCustomActions();
        m_actionError = specificError;
        emit actionStateChanged();
        return false;
    }

    m_actionError.clear();
    emit customActionsChanged();
    emit actionStateChanged();
    return true;
}

bool DesktopBackend::removeCustomAction(const QString &id)
{
    int idx = customActionIndex(id);
    if (idx < 0) return false;

    m_customActions.removeAt(idx);
    if (!persistCustomActions()) {
        const QString specificError = m_actionError.isEmpty() ? tr("Errore durante l'eliminazione su disco.") : m_actionError;
        reloadCustomActions();
        m_actionError = specificError;
        emit actionStateChanged();
        return false;
    }

    emit customActionsChanged();
    return true;
}

bool DesktopBackend::runCustomAction(const QString &id)
{
#ifdef Q_OS_UNIX
    if (::geteuid() == 0) {
        m_actionError = tr("I comandi personali sono disabilitati quando il processo gira come root.");
        emit actionStateChanged();
        return false;
    }
#endif
    int idx = customActionIndex(id);
    if (idx < 0) return false;

    const QVariantMap map = m_customActions.at(idx).toMap();
    const QString script = map.value(QStringLiteral("script")).toString();

    const QString bash = QStandardPaths::findExecutable(QStringLiteral("bash"));
    if (bash.isEmpty()) {
        m_actionError = tr("Bash non trovato sul sistema.");
        emit actionStateChanged();
        return false;
    }

    if (m_busy) {
        m_actionError = tr("Un'altra operazione è già in esecuzione.");
        emit actionStateChanged();
        return false;
    }

    m_actionOutput.clear();
    m_actionError.clear();
    m_actionRunning = true;
    emit actionStateChanged();

    QProcess *proc = startProcess(bash, {QStringLiteral("-c"), script}, QStringLiteral("custom-action"), true, 600000, QDir::homePath());
    if (!proc || proc->state() == QProcess::NotRunning) {
        m_actionRunning = false;
        if (m_actionError.isEmpty()) {
            m_actionError = tr("Impossibile avviare il processo per l'azione personale.");
        }
        emit actionStateChanged();
        return false;
    }

    return true;
}

void DesktopBackend::clearActionOutput()
{
    m_actionOutput.clear();
    m_actionError.clear();
    emit actionStateChanged();
}

void DesktopBackend::cleanTrash(const QString &)
{
    const QString dataDir = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation);
    if (dataDir.isEmpty() || dataDir == QStringLiteral("/")) {
        setMessage(tr("Percorso dati utente non valido."));
        return;
    }
    const QString trashPath = dataDir + QStringLiteral("/Trash");
    setMessage(tr("Svuotamento del cestino utente in corso..."));
    startProcess(QStringLiteral("rm"), {
        QStringLiteral("-rf"),
        QStringLiteral("--"),
        trashPath + QStringLiteral("/files"),
        trashPath + QStringLiteral("/info"),
        trashPath + QStringLiteral("/directorysizes")
    }, QStringLiteral("clean-trash-user"), false, 30000);
}

void DesktopBackend::cleanJournal(int keepMb)
{
    const QString journalctl = findTrustedSystemBinary(QStringLiteral("journalctl"));
    if (journalctl.isEmpty()) {
        setMessage(tr("journalctl non trovato sul sistema."));
        return;
    }
    const QString arg = QStringLiteral("--vacuum-size=%1M").arg(qMax(8, keepMb));
    setMessage(tr("Pulizia dei registri Journal in corso..."));
    startProcess(QStringLiteral("pkexec"), {journalctl, arg}, QStringLiteral("journal-vacuum"), false, 60000);
}

void DesktopBackend::cleanFlatpakUnused()
{
    const QString flatpak = findExecutableWithSbin(QStringLiteral("flatpak"));
    if (flatpak.isEmpty()) {
        setMessage(tr("Flatpak non è installato sul sistema."));
        return;
    }
    setMessage(tr("Rimozione dei runtime Flatpak inutilizzati in corso..."));
    startProcess(flatpak, {QStringLiteral("uninstall"), QStringLiteral("--unused"), QStringLiteral("-y")},
                 QStringLiteral("flatpak-unused"), true, 180000);
}

void DesktopBackend::cleanZypperCache()
{
    const QString zypper = findTrustedSystemBinary(QStringLiteral("zypper"));
    if (zypper.isEmpty()) {
        setMessage(tr("zypper non trovato sul sistema."));
        return;
    }
    setMessage(tr("Pulizia della cache Zypper e dei metadati in corso..."));
    startProcess(QStringLiteral("pkexec"), {zypper, QStringLiteral("clean"), QStringLiteral("--all")},
                 QStringLiteral("zypper-clean"), false, 60000);
}

void DesktopBackend::cleanThumbnailCache()
{
    const QString thumbDir = QDir::homePath() + QStringLiteral("/.cache/thumbnails");
    if (!QDir(thumbDir).exists()) {
        setMessage(tr("Nessuna miniatura in cache trovata."));
        return;
    }
    setMessage(tr("Pulizia della cache delle miniature in corso..."));
    startProcess(QStringLiteral("find"), {
        thumbDir,
        QStringLiteral("-mindepth"),
        QStringLiteral("1"),
        QStringLiteral("-delete")
    }, QStringLiteral("clean-thumbnails"), true, 120000);
}

void DesktopBackend::rebuildDesktopCache()
{
    startProcess(QStringLiteral("bash"), {QStringLiteral("-c"), QStringLiteral("kbuildsycoca6 2>/dev/null || true ; fc-cache -f 2>/dev/null || true")},
                 QStringLiteral("desktop-cache"), false, 60000);
}

void DesktopBackend::rebootToFirmware()
{
    setMessage(tr("Riavvio verso le impostazioni UEFI in corso..."));
    startProcess(QStringLiteral("systemctl"), {QStringLiteral("reboot"), QStringLiteral("--firmware-setup")},
                 QStringLiteral("firmware-reboot"), false);
}

void DesktopBackend::rebootSystem()
{
    setMessage(tr("Riavvio del sistema in corso..."));
    startProcess(QStringLiteral("systemctl"), {QStringLiteral("reboot")},
                 QStringLiteral("system-reboot"), false);
}

QString DesktopBackend::bashPromptStatus() const
{
    const QString bashrc = QDir::homePath() + QStringLiteral("/.bashrc");
    QFile f(bashrc);
    if (f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        const QString content = QString::fromUtf8(f.readAll());
        if (content.contains(QStringLiteral("myslowroll-prompt-readable")))
            return QStringLiteral("readable");
        if (content.contains(QStringLiteral("myslowroll-prompt-compact")))
            return QStringLiteral("compact");
        if (content.contains(QStringLiteral("myslowroll-prompt-minimal")))
            return QStringLiteral("minimal");
    }
    return QStringLiteral("predefinito");
}

bool DesktopBackend::applyBashPromptPreset(const QString &presetId)
{
    const QString rawBashrc = QDir::homePath() + QStringLiteral("/.bashrc");
    const QFileInfo fi(rawBashrc);
    const QString bashrc = fi.isSymLink() ? fi.symLinkTarget() : rawBashrc;

    QFile f(bashrc);
    QString content;
    if (f.exists()) {
        const QString bakPath = rawBashrc + QStringLiteral(".bak");
        if (!QFile::exists(bakPath) && !QFile::copy(bashrc, bakPath)) {
            setMessage(tr("Impossibile creare il file di backup ~/.bashrc.bak. Operazione annullata."));
            return false;
        }
        if (!f.open(QIODevice::ReadOnly)) {
            setMessage(tr("Impossibile leggere il file ~/.bashrc per applicare le modifiche."));
            return false;
        }
        content = QString::fromUtf8(f.readAll());
        f.close();
    }

    // Strip previous markers
    const QRegularExpression rx(QStringLiteral("\n?# myslowroll-prompt-begin[\\s\\S]*?# myslowroll-prompt-end\n?"));
    content.remove(rx);

    QString snippet;
    if (presetId == QStringLiteral("readable")) {
        snippet = QStringLiteral("\n# myslowroll-prompt-begin (myslowroll-prompt-readable)\n"
                                 "PS1='\\n\\[\\033[01;32m\\]\\u@\\h\\[\\033[00m\\]:\\[\\033[01;34m\\]\\w\\[\\033[00m\\]\\n\\$ '\n"
                                 "# myslowroll-prompt-end\n");
    } else if (presetId == QStringLiteral("compact")) {
        snippet = QStringLiteral("\n# myslowroll-prompt-begin (myslowroll-prompt-compact)\n"
                                 "PS1='\\[\\033[01;32m\\]\\u@\\h\\[\\033[00m\\]:\\[\\033[01;34m\\]\\w\\[\\033[00m\\]\\$ '\n"
                                 "# myslowroll-prompt-end\n");
    } else if (presetId == QStringLiteral("minimal")) {
        snippet = QStringLiteral("\n# myslowroll-prompt-begin (myslowroll-prompt-minimal)\n"
                                 "PS1='\\n\\[\\033[01;34m\\]\\w\\[\\033[00m\\]\\n\\$ '\n"
                                 "# myslowroll-prompt-end\n");
    } else if (presetId == QStringLiteral("predefinito") || presetId == QStringLiteral("default")) {
        snippet = QString();
    } else {
        setMessage(tr("Preset prompt sconosciuto: %1").arg(presetId));
        return false;
    }

    content += snippet;

    QSaveFile save(bashrc);
    if (save.open(QIODevice::WriteOnly | QIODevice::Text)) {
        save.write(content.toUtf8());
        if (!save.commit()) {
            setMessage(tr("Impossibile salvare le modifiche in ~/.bashrc"));
            return false;
        }
        emit promptStatusChanged();
        if (presetId == QStringLiteral("predefinito") || presetId == QStringLiteral("default")) {
            setMessage(tr("Prompt bash ripristinato alla configurazione predefinita di sistema."));
        } else {
            setMessage(tr("Preset prompt bash '%1' applicato. Riavvia la shell per attivarlo.").arg(presetId));
        }
        return true;
    }
    setMessage(tr("Impossibile aprire ~/.bashrc in scrittura (permessi insufficienti)."));
    return false;
}

QProcess *DesktopBackend::startProcess(const QString &program, const QStringList &arguments,
                                       const QString &operationName, bool cancellable,
                                       int timeoutMs, const QString &workingDir)
{
    if (m_busy) {
        setMessage(tr("Un'altra operazione è già in esecuzione."));
        return nullptr;
    }

    auto *proc = new QProcess(this);
    proc->setProperty("opName", operationName);
    proc->setProperty("opCancellable", cancellable);
    proc->setProcessChannelMode(QProcess::MergedChannels);

    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("LC_ALL"), QStringLiteral("C.UTF-8"));
    env.insert(QStringLiteral("LANG"), QStringLiteral("C.UTF-8"));
    proc->setProcessEnvironment(env);

    if (!workingDir.isEmpty())
        proc->setWorkingDirectory(workingDir);

#ifdef Q_OS_UNIX
    proc->setChildProcessModifier([] { ::setpgid(0, 0); });
#endif

    auto outputBuffer = std::make_shared<QByteArray>();
    auto isTruncated = std::make_shared<bool>(false);

    connect(proc, &QProcess::readyRead, proc, [proc, outputBuffer, isTruncated] {
        outputBuffer->append(proc->readAll());
        if (outputBuffer->size() > kMaxOutputBytes) {
            qsizetype excess = outputBuffer->size() - kMaxOutputBytes;
            while (excess < outputBuffer->size() && (static_cast<unsigned char>(outputBuffer->at(excess)) & 0xC0) == 0x80) {
                ++excess;
            }
            outputBuffer->remove(0, excess);
            *isTruncated = true;
        }
    });

    m_activeProcess = proc;
    setBusy(true);

    connect(proc, &QProcess::finished, this, [this, proc, operationName, outputBuffer, isTruncated](int code, QProcess::ExitStatus) {
        outputBuffer->append(proc->readAll());
        if (outputBuffer->size() > kMaxOutputBytes) {
            qsizetype excess = outputBuffer->size() - kMaxOutputBytes;
            while (excess < outputBuffer->size() && (static_cast<unsigned char>(outputBuffer->at(excess)) & 0xC0) == 0x80) {
                ++excess;
            }
            outputBuffer->remove(0, excess);
            *isTruncated = true;
        }
        QByteArray out = *outputBuffer;
        if (*isTruncated) {
            out.prepend("[... Output troncato ai byte più recenti ...]\n");
        }
        if (m_activeProcess == proc)
            m_activeProcess = nullptr;
        setBusy(false);
        handleProcessFinished(proc, operationName, code, out);
        proc->deleteLater();
    });

    connect(proc, &QProcess::errorOccurred, this, [this, proc, operationName](QProcess::ProcessError err) {
        if (err == QProcess::FailedToStart) {
            if (m_activeProcess == proc)
                m_activeProcess = nullptr;
            setBusy(false);
            if (operationName == QStringLiteral("custom-action")) {
                m_actionRunning = false;
                m_actionError = tr("Impossibile avviare il processo: eseguibile non trovato.");
                emit actionStateChanged();
            } else if (operationName == QStringLiteral("diagnostic")) {
                m_diagnosticOutput = tr("Impossibile avviare il comando: eseguibile non trovato.");
                emit diagnosticChanged();
            } else {
                setMessage(tr("Impossibile avviare l'operazione '%1': programma non trovato.").arg(operationName));
            }
            proc->deleteLater();
        }
    });

    proc->start(program, arguments);

    if (timeoutMs > 0) {
        QPointer<QProcess> guard = proc;
        QTimer::singleShot(timeoutMs, proc, [this, guard] {
            if (guard && guard->state() != QProcess::NotRunning) {
                terminateProcessGroup(guard.data(), true);
                if (!guard->property("opPermissionDeniedOnCancel").toBool()) {
                    guard->setProperty("opTimedOut", true);
                }
            }
        });
    }

    return proc;
}

void DesktopBackend::terminateProcessGroup(QProcess *proc, bool force)
{
    if (!proc || proc->state() == QProcess::NotRunning)
        return;
#ifdef Q_OS_UNIX
    const qint64 pid = proc->processId();
    if (pid > 0) {
        const int res = ::kill(-static_cast<pid_t>(pid), force ? SIGKILL : SIGTERM);
        if (res == 0) {
            return;
        }
        if (errno == EPERM) {
            proc->setProperty("opPermissionDeniedOnCancel", true);
            return;
        }
    }
#endif
    force ? proc->kill() : proc->terminate();
}

void DesktopBackend::cancelCurrentOperation()
{
    if (!m_activeProcess) return;
    if (!m_activeProcess->property("opCancellable").toBool()) {
        setMessage(tr("L'operazione in corso non supporta l'annullamento."));
        return;
    }
    m_activeProcess->setProperty("opUserCancelled", true);
    terminateProcessGroup(m_activeProcess.data(), false);
    if (m_activeProcess->property("opPermissionDeniedOnCancel").toBool()) {
        m_activeProcess->setProperty("opUserCancelled", false);
        setMessage(tr("Impossibile annullare l'operazione: richiede privilegi di root (EPERM)."));
        return;
    }
    setMessage(tr("Annullamento dell'operazione richiesto..."));
    QPointer<QProcess> guard = m_activeProcess.data();
    QTimer::singleShot(3000, guard.data(), [this, guard] {
        if (guard && guard->state() != QProcess::NotRunning && guard->property("opUserCancelled").toBool()) {
            terminateProcessGroup(guard.data(), true);
        }
    });
}

void DesktopBackend::handleProcessFinished(QProcess *proc, const QString &operation,
                                           int exitCode, const QByteArray &output)
{
    const QString text = limitOutput(output);
    const bool timedOut = proc ? proc->property("opTimedOut").toBool() : false;
    const bool userCancelled = proc ? proc->property("opUserCancelled").toBool() : false;
    const bool crashed = proc ? (proc->exitStatus() == QProcess::CrashExit) : false;
    const bool permDenied = proc ? proc->property("opPermissionDeniedOnCancel").toBool() : false;
    const bool effectiveUserCancelled = userCancelled && !permDenied;

    if (operation == QStringLiteral("diagnostic")) {
        if (effectiveUserCancelled)
            m_diagnosticOutput = tr("Operazione diagnostica annullata dall'utente.");
        else if (timedOut)
            m_diagnosticOutput = tr("Operazione terminata per timeout.");
        else if (crashed)
            m_diagnosticOutput = tr("Operazione diagnostica interrotta o terminata in modo anomalo.");
        else
            m_diagnosticOutput = text;
        emit diagnosticChanged();
        return;
    }

    if (operation == QStringLiteral("custom-action")) {
        m_actionRunning = false;
        m_actionOutput = text;
        if (userCancelled)
            m_actionError = tr("Azione annullata dall'utente.");
        else if (timedOut)
            m_actionError = tr("Azione interrotta per timeout.");
        else if (crashed)
            m_actionError = tr("Azione annullata o terminata in modo anomalo.");
        else
            m_actionError = exitCode == 0 ? QString() : tr("Terminato con codice di uscita %1").arg(exitCode);
        emit actionStateChanged();
        return;
    }

    if (operation == QStringLiteral("clean-trash-user")) {
        const QString trashPath = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/Trash");
        QDir().mkpath(trashPath + QStringLiteral("/files"));
        QDir().mkpath(trashPath + QStringLiteral("/info"));
        setMessage(exitCode == 0 ? tr("Cestino utente svuotato con successo.") : tr("Svuotamento cestino utente non riuscito (codice %1).").arg(exitCode));
        return;
    }

    if (operation == QStringLiteral("clean-thumbnails")) {
        setMessage(exitCode == 0 ? tr("Cache delle miniature ripulita.")
                                 : tr("Impossibile rimuovere alcuni file dalla cache delle miniature."));
        return;
    }

    if (operation == QStringLiteral("audio-restart")) {
        setMessage(exitCode == 0 ? tr("Stack audio riavviato correttamente.") : tr("Riavvio audio fallito."));
        return;
    }

    if (operation == QStringLiteral("flush-dns")) {
        setMessage(exitCode == 0 ? tr("Cache DNS svuotata.") : tr("Operazione DNS non riuscita."));
        return;
    }

    if (operation == QStringLiteral("journal-vacuum")) {
        setMessage(exitCode == 0 ? tr("Journal ripulito alle dimensioni impostate.") : tr("Pulizia journal fallita."));
        return;
    }

    if (operation == QStringLiteral("flatpak-unused")) {
        setMessage(exitCode == 0 ? tr("Runtime Flatpak inutilizzati rimossi.") : tr("Pulizia Flatpak terminata."));
        return;
    }

    if (operation == QStringLiteral("zypper-clean")) {
        setMessage(exitCode == 0 ? tr("Cache pacchetti Zypper ripulita con successo.") : tr("Pulizia cache Zypper fallita."));
        return;
    }

    if (operation == QStringLiteral("desktop-cache")) {
        setMessage(exitCode == 0 ? tr("Cache delle applicazioni e dei font ricostruita.") : tr("Ricostruzione cache completata con avvisi."));
        return;
    }

    if (operation.startsWith(QStringLiteral("network-apply-"))) {
        const QString conn = operation.mid(14);
        if (exitCode == 0) {
            startProcess(QStringLiteral("nmcli"), {
                QStringLiteral("connection"),
                QStringLiteral("up"),
                conn
            }, QStringLiteral("network-up"), false, 15000);
        } else {
            setMessage(tr("Errore configurazione rete (codice %1): %2").arg(exitCode).arg(text));
        }
        return;
    }

    if (operation == QStringLiteral("network-up")) {
        refreshNetworkStatus();
        setMessage(exitCode == 0 ? tr("Profilo di rete applicato e connessione riattivata con successo.")
                                 : tr("Rete configurata ma riattivazione fallita (%1): %2").arg(exitCode).arg(text));
        return;
    }

    setMessage(exitCode == 0 ? tr("Operazione completata con successo.") : tr("Operazione terminata con errore (%1).").arg(exitCode));
}

QString DesktopBackend::networkProfilesFilePath() const
{
    const QString configDir = QStandardPaths::writableLocation(QStandardPaths::ConfigLocation);
    return QDir(configDir).filePath(QStringLiteral("myslowroll-cc/network-profiles.json"));
}

void DesktopBackend::loadNetworkProfiles()
{
    m_ipPresets.clear();
    m_dnsPresets.clear();

    const QString path = networkProfilesFilePath();
    QFile file(path);
    bool loaded = false;
    if (file.exists()) {
        if (file.open(QIODevice::ReadOnly)) {
            QJsonParseError parseErr;
            const QByteArray data = file.readAll();
            file.close();
            const QJsonDocument doc = QJsonDocument::fromJson(data, &parseErr);
            if (parseErr.error != QJsonParseError::NoError || !doc.isObject()) {
                QFile::remove(path + QStringLiteral(".bak"));
                QFile::copy(path, path + QStringLiteral(".bak"));
            } else {
                const QJsonObject root = doc.object();
                m_selectedIpPreset = root.value(QStringLiteral("selectedIpIndex")).toInt(0);
                m_selectedDnsPreset = root.value(QStringLiteral("selectedDnsIndex")).toInt(0);
                m_httpsAddress = root.value(QStringLiteral("httpsAddress")).toString();

                const QJsonArray ipArr = root.value(QStringLiteral("ipPresets")).toArray();
                for (const QJsonValue &v : ipArr) {
                    m_ipPresets.append(v.toObject().toVariantMap());
                }

                const QJsonArray dnsArr = root.value(QStringLiteral("dnsPresets")).toArray();
                for (const QJsonValue &v : dnsArr) {
                    m_dnsPresets.append(v.toObject().toVariantMap());
                }

                if (!m_ipPresets.isEmpty() || !m_dnsPresets.isEmpty())
                    loaded = true;
            }
        }
    }

    if (m_ipPresets.isEmpty()) {
        QVariantMap ipDhcp;
        ipDhcp.insert(QStringLiteral("name"), tr("Automatico (DHCP)"));
        ipDhcp.insert(QStringLiteral("address"), QString());
        ipDhcp.insert(QStringLiteral("gateway"), QString());
        m_ipPresets.append(ipDhcp);

        QVariantMap ip1;
        ip1.insert(QStringLiteral("name"), tr("IP Statico 1"));
        ip1.insert(QStringLiteral("address"), QStringLiteral("192.168.11.50/24"));
        ip1.insert(QStringLiteral("gateway"), QStringLiteral("192.168.11.1"));
        m_ipPresets.append(ip1);

        QVariantMap ip2;
        ip2.insert(QStringLiteral("name"), tr("IP Statico 2"));
        ip2.insert(QStringLiteral("address"), QStringLiteral("192.168.11.60/24"));
        ip2.insert(QStringLiteral("gateway"), QStringLiteral("192.168.11.1"));
        m_ipPresets.append(ip2);

        QVariantMap ip3;
        ip3.insert(QStringLiteral("name"), tr("Personalizzato"));
        ip3.insert(QStringLiteral("address"), QString());
        ip3.insert(QStringLiteral("gateway"), QString());
        m_ipPresets.append(ip3);
    } else if (m_ipPresets.size() < 4) {
        while (m_ipPresets.size() < 4) {
            QVariantMap ipExtra;
            ipExtra.insert(QStringLiteral("name"), tr("Personalizzato"));
            ipExtra.insert(QStringLiteral("address"), QString());
            ipExtra.insert(QStringLiteral("gateway"), QString());
            m_ipPresets.append(ipExtra);
        }
    }

    if (m_dnsPresets.isEmpty()) {
        QVariantMap d1;
        d1.insert(QStringLiteral("name"), tr("DNS Router / Locale"));
        d1.insert(QStringLiteral("dns"), QStringLiteral("192.168.11.1"));
        d1.insert(QStringLiteral("dohUrl"), QString());
        m_dnsPresets.append(d1);

        QVariantMap d2;
        d2.insert(QStringLiteral("name"), tr("DNS Cloudflare Sicuro"));
        d2.insert(QStringLiteral("dns"), QStringLiteral("1.1.1.1 1.0.0.1"));
        d2.insert(QStringLiteral("dohUrl"), QStringLiteral("https://cloudflare-dns.com/dns-query"));
        m_dnsPresets.append(d2);

        QVariantMap d3;
        d3.insert(QStringLiteral("name"), tr("DNS Quad9 Privacy"));
        d3.insert(QStringLiteral("dns"), QStringLiteral("9.9.9.9 149.112.112.112"));
        d3.insert(QStringLiteral("dohUrl"), QStringLiteral("https://dns.quad9.net/dns-query"));
        m_dnsPresets.append(d3);

        QVariantMap d4;
        d4.insert(QStringLiteral("name"), tr("Personalizzato"));
        d4.insert(QStringLiteral("dns"), QString());
        d4.insert(QStringLiteral("dohUrl"), QString());
        m_dnsPresets.append(d4);
    } else if (m_dnsPresets.size() < 4) {
        while (m_dnsPresets.size() < 4) {
            QVariantMap dExtra;
            dExtra.insert(QStringLiteral("name"), tr("Personalizzato"));
            dExtra.insert(QStringLiteral("dns"), QString());
            dExtra.insert(QStringLiteral("dohUrl"), QString());
            m_dnsPresets.append(dExtra);
        }
    }

    if (!loaded) {
        m_selectedIpPreset = 0;
        m_selectedDnsPreset = 0;
        m_httpsAddress = QString();
        persistNetworkProfiles();
    } else {
        if (m_selectedIpPreset < 0 || m_selectedIpPreset >= m_ipPresets.size())
            m_selectedIpPreset = 0;
        if (m_selectedDnsPreset < 0 || m_selectedDnsPreset >= m_dnsPresets.size())
            m_selectedDnsPreset = 0;
    }

    emit networkPresetsChanged();
}

bool DesktopBackend::persistNetworkProfiles()
{
    const QString path = networkProfilesFilePath();
    QFileInfo info(path);
    if (!QDir().mkpath(info.absolutePath()))
        return false;

    QJsonObject root;
    root.insert(QStringLiteral("selectedIpIndex"), m_selectedIpPreset);
    root.insert(QStringLiteral("selectedDnsIndex"), m_selectedDnsPreset);
    root.insert(QStringLiteral("httpsAddress"), m_httpsAddress);

    QJsonArray ipArr;
    for (const QVariant &v : m_ipPresets) {
        ipArr.append(QJsonObject::fromVariantMap(v.toMap()));
    }
    root.insert(QStringLiteral("ipPresets"), ipArr);

    QJsonArray dnsArr;
    for (const QVariant &v : m_dnsPresets) {
        dnsArr.append(QJsonObject::fromVariantMap(v.toMap()));
    }
    root.insert(QStringLiteral("dnsPresets"), dnsArr);

    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly) ||
        file.write(QJsonDocument(root).toJson(QJsonDocument::Indented)) < 0 ||
        !file.commit()) {
        return false;
    }
    return true;
}

void DesktopBackend::selectIpPreset(int index)
{
    if (index >= 0 && index < m_ipPresets.size() && m_selectedIpPreset != index) {
        m_selectedIpPreset = index;
        persistNetworkProfiles();
        emit networkPresetsChanged();
    }
}

void DesktopBackend::selectDnsPreset(int index)
{
    if (index >= 0 && index < m_dnsPresets.size() && m_selectedDnsPreset != index) {
        m_selectedDnsPreset = index;
        const auto map = m_dnsPresets.at(index).toMap();
        const QString doh = map.value(QStringLiteral("dohUrl")).toString();
        m_httpsAddress = doh;
        persistNetworkProfiles();
        emit networkPresetsChanged();
    }
}

void DesktopBackend::setHttpsAddress(const QString &url)
{
    const QString clean = url.trimmed();
    if (m_httpsAddress == clean) return;
    m_httpsAddress = clean;
    if (m_selectedDnsPreset >= 0 && m_selectedDnsPreset < m_dnsPresets.size()) {
        QVariantMap map = m_dnsPresets[m_selectedDnsPreset].toMap();
        map[QStringLiteral("dohUrl")] = m_httpsAddress;
        m_dnsPresets[m_selectedDnsPreset] = map;
    }
    persistNetworkProfiles();
    emit networkPresetsChanged();
}

bool DesktopBackend::saveIpPreset(int index, const QString &name, const QString &address, const QString &gateway)
{
    if (index < 0 || index >= m_ipPresets.size())
        return false;

    const QString cleanAddr = address.trimmed();
    const QString cleanGw = gateway.trimmed();
    QString formattedCidr;
    if (!cleanAddr.isEmpty() && !validateIpv4Cidr(cleanAddr, &formattedCidr)) {
        setMessage(tr("Indirizzo IP non valido. Inserire un formato CIDR valido (es. 192.168.11.50/24) o lasciare vuoto per DHCP."));
        return false;
    }
    if (!cleanGw.isEmpty() && !validateGateway(cleanGw)) {
        setMessage(tr("Indirizzo Gateway non valido. Inserire un indirizzo IPv4 valido o lasciare vuoto."));
        return false;
    }

    QVariantMap map;
    map.insert(QStringLiteral("name"), name.trimmed());
    map.insert(QStringLiteral("address"), cleanAddr.isEmpty() ? QString() : (formattedCidr.isEmpty() ? cleanAddr : formattedCidr));
    map.insert(QStringLiteral("gateway"), cleanGw);
    m_ipPresets[index] = map;
    persistNetworkProfiles();
    emit networkPresetsChanged();
    setMessage(tr("Profilo IP '%1' salvato.").arg(name.trimmed().isEmpty() ? QString::number(index + 1) : name.trimmed()));
    return true;
}

bool DesktopBackend::saveDnsPreset(int index, const QString &name, const QString &dns, const QString &dohUrl)
{
    if (index < 0 || index >= m_dnsPresets.size())
        return false;

    const QString cleanDns = dns.trimmed();
    if (!cleanDns.isEmpty() && !validateDns(cleanDns)) {
        setMessage(tr("Server DNS non validi. Specificare indirizzi IP validi separati da spazi."));
        return false;
    }

    QVariantMap map;
    map.insert(QStringLiteral("name"), name.trimmed());
    map.insert(QStringLiteral("dns"), cleanDns);
    map.insert(QStringLiteral("dohUrl"), dohUrl.trimmed());
    m_dnsPresets[index] = map;
    if (index == m_selectedDnsPreset) {
        m_httpsAddress = dohUrl.trimmed();
    }
    persistNetworkProfiles();
    emit networkPresetsChanged();
    setMessage(tr("Profilo DNS '%1' salvato.").arg(name.trimmed().isEmpty() ? QString::number(index + 1) : name.trimmed()));
    return true;
}

void DesktopBackend::refreshNetworkStatus()
{
    const quint64 reqId = ++m_networkRequestId;
    auto *proc = new QProcess(this);
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("LC_ALL"), QStringLiteral("C.UTF-8"));
    env.insert(QStringLiteral("LANG"), QStringLiteral("C.UTF-8"));
    proc->setProcessEnvironment(env);

    auto resetNet = [this, reqId]() {
        if (reqId != m_networkRequestId) return;
        m_networkActiveConnection.clear();
        m_networkInterface.clear();
        m_networkConnected = false;
        m_networkIpAddress.clear();
        m_networkGateway.clear();
        m_networkDns.clear();
        emit networkStatusChanged();
    };

    QPointer<QProcess> guard = proc;
    QTimer::singleShot(4000, proc, [guard, resetNet] {
        if (guard && guard->state() != QProcess::NotRunning) {
            guard->kill();
            resetNet();
        }
    });

    connect(proc, &QProcess::finished, this, [this, proc, reqId, resetNet](int exitCode, QProcess::ExitStatus) {
        if (reqId == m_networkRequestId) {
            const QStringList lines = QString::fromUtf8(proc->readAllStandardOutput()).split(QLatin1Char('\n'));
            if (exitCode == 0 && lines.size() >= 5 && !lines.at(0).trimmed().isEmpty()) {
                m_networkActiveConnection = lines.at(0).trimmed();
                m_networkInterface = lines.at(1).trimmed();
                m_networkConnected = true;
                m_networkIpAddress = lines.at(2).trimmed().section(QStringLiteral(" | "), 0, 0).section(QLatin1Char('/'), 0, 0);
                m_networkGateway = lines.at(3).trimmed();
                m_networkDns = lines.at(4).trimmed().replace(QStringLiteral(" | "), QStringLiteral(" "));
                emit networkStatusChanged();
            } else {
                resetNet();
            }
        }
        proc->deleteLater();
    });
    connect(proc, &QProcess::errorOccurred, this, [proc, resetNet](QProcess::ProcessError) {
        resetNet();
        proc->deleteLater();
    });

    // Singola interrogazione atomica a nmcli sul device attivo: restituisce Connessione, Device, IP, Gateway e DNS runtime
    const QString script = QStringLiteral(
        "dev=$(nmcli -t -f DEVICE,TYPE,STATE device status | awk -F: '($2==\"ethernet\"||$2==\"wifi\") && $3==\"connected\" {print $1; exit}'); "
        "[ -z \"$dev\" ] && dev=$(nmcli -t -f DEVICE,TYPE,STATE device status | awk -F: '$2!=\"loopback\" && $2!=\"bridge\" && $3==\"connected\" {print $1; exit}'); "
        "[ -z \"$dev\" ] && exit 1; "
        "conn=$(nmcli -g GENERAL.CONNECTION device show \"$dev\"); "
        "printf '%s\\n%s\\n' \"$conn\" \"$dev\"; "
        "nmcli -g IP4.ADDRESS,IP4.GATEWAY,IP4.DNS device show \"$dev\""
    );
    proc->start(QStringLiteral("bash"), {QStringLiteral("-c"), script});
}
void DesktopBackend::applyActiveNetworkProfile()
{
    if (m_selectedIpPreset < 0 || m_selectedIpPreset >= m_ipPresets.size() ||
        m_selectedDnsPreset < 0 || m_selectedDnsPreset >= m_dnsPresets.size()) {
        setMessage(tr("Profilo di rete non selezionato."));
        return;
    }

    if (m_networkActiveConnection.isEmpty()) {
        setMessage(tr("Nessuna connessione di rete attiva rilevata a cui applicare il profilo."));
        return;
    }

    const QString conn = m_networkActiveConnection;
    const QVariantMap ipMap = m_ipPresets.at(m_selectedIpPreset).toMap();
    const QVariantMap dnsMap = m_dnsPresets.at(m_selectedDnsPreset).toMap();

    QString ip = ipMap.value(QStringLiteral("address")).toString().trimmed();
    const QString gw = ipMap.value(QStringLiteral("gateway")).toString().trimmed();
    const QString dns = dnsMap.value(QStringLiteral("dns")).toString().trimmed();

    QStringList dnsList;
    if (!dns.isEmpty() && !validateDns(dns, &dnsList)) {
        setMessage(tr("Server DNS non valido nel profilo: %1").arg(dns));
        return;
    }

    // DHCP Mode (empty IP)
    if (ip.isEmpty()) {
        setMessage(tr("Applicazione profilo di rete (DHCP) su %1...").arg(conn));
        QStringList args = {
            QStringLiteral("connection"),
            QStringLiteral("modify"),
            conn,
            QStringLiteral("ipv4.method"),
            QStringLiteral("auto"),
            QStringLiteral("ipv4.addresses"),
            QString(),
            QStringLiteral("ipv4.gateway"),
            QString()
        };
        if (!dnsList.isEmpty()) {
            args << QStringLiteral("ipv4.dns") << dnsList.join(QLatin1Char(' '))
                 << QStringLiteral("ipv4.ignore-auto-dns") << QStringLiteral("yes");
        } else {
            args << QStringLiteral("ipv4.dns") << QString()
                 << QStringLiteral("ipv4.ignore-auto-dns") << QStringLiteral("no");
        }
        startProcess(QStringLiteral("nmcli"), args, QStringLiteral("network-apply-%1").arg(conn), false, 20000);
        return;
    }

    // Static IP Mode
    QString fullCidr;
    if (!validateIpv4Cidr(ip, &fullCidr)) {
        setMessage(tr("Indirizzo IP o prefisso non valido nel profilo: %1").arg(ip));
        return;
    }

    if (!gw.isEmpty() && !validateGateway(gw)) {
        setMessage(tr("Gateway non valido nel profilo: %1").arg(gw));
        return;
    }

    setMessage(tr("Applicazione profilo di rete su %1...").arg(conn));
    QStringList args = {
        QStringLiteral("connection"),
        QStringLiteral("modify"),
        conn,
        QStringLiteral("ipv4.method"),
        QStringLiteral("manual"),
        QStringLiteral("ipv4.addresses"),
        fullCidr,
        QStringLiteral("ipv4.gateway"),
        gw
    };
    if (!dnsList.isEmpty()) {
        args << QStringLiteral("ipv4.dns") << dnsList.join(QLatin1Char(' '))
             << QStringLiteral("ipv4.ignore-auto-dns") << QStringLiteral("yes");
    } else {
        args << QStringLiteral("ipv4.dns") << QString()
             << QStringLiteral("ipv4.ignore-auto-dns") << QStringLiteral("no");
    }
    startProcess(QStringLiteral("nmcli"), args, QStringLiteral("network-apply-%1").arg(conn), false, 20000);
}

void DesktopBackend::refreshWifiStatus()
{
    bool hasWifi = false;
    const QDir netDir(QStringLiteral("/sys/class/net"));
    for (const QString &iface : netDir.entryList(QDir::Dirs | QDir::NoDotAndDotDot)) {
        if (QFile::exists(netDir.filePath(iface + QStringLiteral("/wireless"))) ||
            QFile::exists(netDir.filePath(iface + QStringLiteral("/phy80211")))) {
            hasWifi = true;
            break;
        }
    }

    m_hasWifiHardware = hasWifi;
    bool hwBlocked = false;
    const QDir rfkillDir(QStringLiteral("/sys/class/rfkill"));
    for (const QString &rf : rfkillDir.entryList({QStringLiteral("rfkill*")}, QDir::Dirs)) {
        QFile typeFile(rfkillDir.filePath(rf + QStringLiteral("/type")));
        if (typeFile.open(QIODevice::ReadOnly | QIODevice::Text) &&
            typeFile.readLine().trimmed() == "wlan") {
            QFile hardFile(rfkillDir.filePath(rf + QStringLiteral("/hard")));
            if (hardFile.open(QIODevice::ReadOnly | QIODevice::Text) &&
                hardFile.readLine().trimmed() == "1") {
                hwBlocked = true;
                break;
            }
        }
    }
    m_wifiHardwareBlocked = hwBlocked;
    if (!hasWifi) {
        m_wifiEnabled = false;
        m_wifiStatusString = QStringLiteral("hardware-missing");
        emit wifiChanged();
        return;
    }

    const quint64 reqId = ++m_wifiRequestId;
    auto *proc = new QProcess(this);
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("LC_ALL"), QStringLiteral("C.UTF-8"));
    env.insert(QStringLiteral("LANG"), QStringLiteral("C.UTF-8"));
    proc->setProcessEnvironment(env);

    QPointer<QProcess> guard = proc;
    QTimer::singleShot(3000, proc, [guard] {
        if (guard && guard->state() != QProcess::NotRunning) guard->kill();
    });

    connect(proc, &QProcess::finished, this, [this, proc, reqId](int exitCode, QProcess::ExitStatus) {
        if (reqId == m_wifiRequestId && exitCode == 0) {
            const QString out = QString::fromUtf8(proc->readAllStandardOutput()).trimmed().toLower();
            m_wifiEnabled = (out == QStringLiteral("enabled"));
            m_wifiStatusString = m_wifiEnabled ? QStringLiteral("enabled") : QStringLiteral("disabled");
            emit wifiChanged();
        }
        proc->deleteLater();
    });
    connect(proc, &QProcess::errorOccurred, proc, &QProcess::deleteLater);

    proc->start(QStringLiteral("nmcli"), {QStringLiteral("radio"), QStringLiteral("wifi")});
}

void DesktopBackend::toggleWifi()
{
    if (m_wifiHardwareBlocked) {
        setMessage(tr("Impossibile modificare il Wi-Fi: interruttore hardware attivo (blocco rfkill)."));
        return;
    }
    setWifiEnabled(!m_wifiEnabled);
}

void DesktopBackend::setWifiEnabled(bool enable)
{
    if (m_wifiHardwareBlocked && enable) {
        setMessage(tr("Impossibile attivare il Wi-Fi: interruttore hardware attivo (blocco rfkill)."));
        return;
    }

    const QString newState = enable ? QStringLiteral("on") : QStringLiteral("off");
    auto *proc = new QProcess(this);
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("LC_ALL"), QStringLiteral("C.UTF-8"));
    env.insert(QStringLiteral("LANG"), QStringLiteral("C.UTF-8"));
    proc->setProcessEnvironment(env);

    connect(proc, &QProcess::finished, this, [this, proc](int, QProcess::ExitStatus) {
        refreshWifiStatus();
        proc->deleteLater();
    });
    connect(proc, &QProcess::errorOccurred, this, [proc](QProcess::ProcessError) {
        proc->deleteLater();
    });
    QPointer<QProcess> guard = proc;
    QTimer::singleShot(4000, proc, [guard] {
        if (guard && guard->state() != QProcess::NotRunning) guard->kill();
    });
    proc->start(QStringLiteral("nmcli"), {QStringLiteral("radio"), QStringLiteral("wifi"), newState});
}

void DesktopBackend::refreshBluetoothStatus()
{
    bool hasBt = false;
    bool hwBlocked = false;
    bool swBlocked = false;

    const QDir rfkillDir(QStringLiteral("/sys/class/rfkill"));
    for (const QString &rf : rfkillDir.entryList({QStringLiteral("rfkill*")}, QDir::Dirs)) {
        QFile typeFile(rfkillDir.filePath(rf + QStringLiteral("/type")));
        if (typeFile.open(QIODevice::ReadOnly | QIODevice::Text)) {
            const QString type = QString::fromUtf8(typeFile.readLine()).trimmed();
            if (type == QStringLiteral("bluetooth")) {
                hasBt = true;
                QFile hardFile(rfkillDir.filePath(rf + QStringLiteral("/hard")));
                if (hardFile.open(QIODevice::ReadOnly | QIODevice::Text)) {
                    if (QString::fromUtf8(hardFile.readLine()).trimmed() == QStringLiteral("1")) {
                        hwBlocked = true;
                    }
                }
                QFile softFile(rfkillDir.filePath(rf + QStringLiteral("/soft")));
                if (softFile.open(QIODevice::ReadOnly | QIODevice::Text)) {
                    if (QString::fromUtf8(softFile.readLine()).trimmed() == QStringLiteral("1")) {
                        swBlocked = true;
                    }
                }
            }
        }
    }

    const bool changed = (m_hasBluetoothHardware != hasBt ||
                          m_bluetoothHardwareBlocked != hwBlocked ||
                          m_bluetoothEnabled != (hasBt && !hwBlocked && !swBlocked));

    m_hasBluetoothHardware = hasBt;
    m_bluetoothHardwareBlocked = hwBlocked;
    m_bluetoothEnabled = (hasBt && !hwBlocked && !swBlocked);
    m_bluetoothStatusString = !hasBt ? QStringLiteral("hardware-missing")
                                     : (hwBlocked ? QStringLiteral("hardware-blocked")
                                                  : (m_bluetoothEnabled ? QStringLiteral("enabled") : QStringLiteral("disabled")));

    if (changed) {
        emit bluetoothChanged();
    }
}

void DesktopBackend::toggleBluetooth()
{
    if (m_privacyActive) {
        setMessage(tr("Impossibile modificare il Bluetooth mentre la Modalità Privacy è attiva."));
        return;
    }
    if (m_bluetoothHardwareBlocked) {
        setMessage(tr("Impossibile modificare il Bluetooth: blocco interruttore hardware attivo."));
        return;
    }
    setBluetoothEnabled(!m_bluetoothEnabled);
}

void DesktopBackend::setBluetoothEnabled(bool enable)
{
    if (m_bluetoothHardwareBlocked && enable) {
        setMessage(tr("Impossibile attivare il Bluetooth: blocco interruttore hardware attivo."));
        return;
    }

    const QString rfkillBin = findExecutableWithSbin(QStringLiteral("rfkill"));
    if (rfkillBin.isEmpty()) {
        setMessage(tr("Comando rfkill non trovato per la gestione del Bluetooth."));
        return;
    }

    const QString action = enable ? QStringLiteral("unblock") : QStringLiteral("block");
    auto *proc = new QProcess(this);
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("LC_ALL"), QStringLiteral("C.UTF-8"));
    env.insert(QStringLiteral("LANG"), QStringLiteral("C.UTF-8"));
    proc->setProcessEnvironment(env);

    connect(proc, &QProcess::finished, this, [this, proc](int, QProcess::ExitStatus) {
        refreshBluetoothStatus();
        proc->deleteLater();
    });
    connect(proc, &QProcess::errorOccurred, this, [proc](QProcess::ProcessError) {
        proc->deleteLater();
    });
    QPointer<QProcess> guard = proc;
    QTimer::singleShot(4000, proc, [guard] {
        if (guard && guard->state() != QProcess::NotRunning) guard->kill();
    });
    proc->start(rfkillBin, {action, QStringLiteral("bluetooth")});
}

void DesktopBackend::refreshTopMemoryProcesses()
{
    if (m_topProcessesProc && m_topProcessesProc->state() != QProcess::NotRunning) {
        return;
    }

    auto *proc = new QProcess(this);
    m_topProcessesProc = proc;

    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("LC_ALL"), QStringLiteral("C.UTF-8"));
    env.insert(QStringLiteral("LANG"), QStringLiteral("C.UTF-8"));
    proc->setProcessEnvironment(env);

    QPointer<QProcess> guard = proc;
    QTimer::singleShot(4000, proc, [guard] {
        if (guard && guard->state() != QProcess::NotRunning) {
            guard->kill();
        }
    });

    connect(proc, &QProcess::finished, this, [this, proc](int exitCode, QProcess::ExitStatus) {
        if (m_topProcessesProc == proc) {
            m_topProcessesProc = nullptr;
        }

        if (exitCode == 0) {
            struct ProcItem {
                QString pid;
                QString name;
                QString memPercent;
                QString memRss;
                qint64 rssKiB = 0;
            };
            QList<ProcItem> items;

            const QString out = QString::fromUtf8(proc->readAllStandardOutput());
            const QStringList lines = out.split(QLatin1Char('\n'), Qt::SkipEmptyParts);

            for (const QString &line : lines) {
                const auto parts = line.split(QLatin1Char(' '), Qt::SkipEmptyParts);
                // Expected columns: pid (0), %mem (1), rss in KiB (2), comm (3...)
                if (parts.size() >= 4) {
                    ProcItem it;
                    it.pid = parts.at(0);
                    it.memPercent = parts.at(1) + QStringLiteral("%");
                    it.rssKiB = parts.at(2).toLongLong();

                    if (it.rssKiB >= 1024 * 1024) {
                        it.memRss = QString::number(double(it.rssKiB) / (1024.0 * 1024.0), 'f', 1) + QStringLiteral(" GiB");
                    } else {
                        it.memRss = QString::number(it.rssKiB / 1024) + QStringLiteral(" MiB");
                    }

                    // Process comm may contain spaces (e.g. "Isolated Web Co")
                    it.name = parts.mid(3).join(QLatin1Char(' '));
                    items.append(it);
                }
            }

            // Strictly sort descending by RSS (physical RAM usage)
            std::sort(items.begin(), items.end(), [](const ProcItem &a, const ProcItem &b) {
                return a.rssKiB > b.rssKiB;
            });

            QVariantList list;
            const int maxCount = qMin(6, items.size());
            for (int i = 0; i < maxCount; ++i) {
                const auto &it = items.at(i);
                QVariantMap item;
                item[QStringLiteral("pid")] = it.pid;
                item[QStringLiteral("name")] = it.name;
                item[QStringLiteral("memPercent")] = it.memPercent;
                item[QStringLiteral("memRss")] = it.memRss;
                list.append(item);
            }

            m_topMemoryProcesses = list;
            emit topProcessesChanged();
        }
        proc->deleteLater();
    });

    connect(proc, &QProcess::errorOccurred, this, [this, proc](QProcess::ProcessError) {
        if (m_topProcessesProc == proc) {
            m_topProcessesProc = nullptr;
        }
        proc->deleteLater();
    });

    proc->start(QStringLiteral("ps"), QStringList{
        QStringLiteral("-eo"),
        QStringLiteral("pid,%mem,rss,comm"),
        QStringLiteral("--sort=-rss"),
        QStringLiteral("--no-headers")
    });
}
