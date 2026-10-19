#include "SlowrollBackend.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QRegularExpression>
#include <QSettings>
#include <QStandardPaths>
#include <QTextStream>
#include <QTimer>
#include <algorithm>
#include <csignal>
#include <cerrno>
#include <memory>

#ifdef Q_OS_UNIX
#include <sys/types.h>
#include <unistd.h>
#endif

namespace {
constexpr qsizetype kMaxOutputBytes = 256 * 1024;

QString findTrustedSystemBinary(const QString &name)
{
    for (const QString &dir : {QStringLiteral("/usr/sbin/"), QStringLiteral("/usr/bin/"), QStringLiteral("/sbin/"), QStringLiteral("/bin/")}) {
        const QString p = dir + name;
        if (QFile::exists(p)) {
            const QFileInfo fi(p);
            if (fi.isExecutable())
                return p;
        }
    }
    return {};
}

QString findEfibootmgr()
{
    return findTrustedSystemBinary(QStringLiteral("efibootmgr"));
}

QString findAtomicUpdate()
{
    return findTrustedSystemBinary(QStringLiteral("atomic-update"));
}

QStringList parseCsvLine(const QString &line)
{
    QStringList fields;
    QString current;
    bool inQuotes = false;
    for (int i = 0; i < line.length(); ++i) {
        const QChar c = line.at(i);
        if (c == QLatin1Char('"')) {
            if (inQuotes && i + 1 < line.length() && line.at(i + 1) == QLatin1Char('"')) {
                current += QLatin1Char('"');
                ++i;
            } else {
                inQuotes = !inQuotes;
            }
        } else if (c == QLatin1Char(',') && !inQuotes) {
            fields.append(current);
            current.clear();
        } else {
            current += c;
        }
    }
    fields.append(current);
    return fields;
}
} // namespace

SlowrollBackend::SlowrollBackend(QObject *parent)
    : QObject(parent)
{
}

void SlowrollBackend::initialize()
{
    refreshAll();
}

SlowrollBackend::~SlowrollBackend()
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

void SlowrollBackend::terminateProcessGroup(QProcess *proc, bool force)
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

QProcess *SlowrollBackend::startProcess(const QString &program, const QStringList &arguments,
                                        const QString &operationName, bool cancellable, int timeoutMs)
{
    if (m_busy) {
        setMessage(tr("Un'altra operazione è già in corso."));
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
        if (err != QProcess::FailedToStart)
            return;
        if (m_activeProcess == proc)
            m_activeProcess = nullptr;
        setBusy(false);
        setMessage(tr("Impossibile avviare l'operazione '%1': programma non trovato.").arg(operationName));
        proc->deleteLater();
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

void SlowrollBackend::cancelCurrentOperation()
{
    if (!m_activeProcess) return;
    if (!m_activeProcess->property("opCancellable").toBool()) {
        setMessage(tr("L'operazione di sistema in corso non supporta l'annullamento."));
        return;
    }
    m_activeProcess->setProperty("opUserCancelled", true);
    terminateProcessGroup(m_activeProcess.data(), false);
    if (m_activeProcess->property("opPermissionDeniedOnCancel").toBool()) {
        m_activeProcess->setProperty("opUserCancelled", false);
        setMessage(tr("Impossibile annullare l'operazione: richiede privilegi di root (EPERM)."));
        return;
    }
    setMessage(tr("Annullamento operazione di sistema richiesto..."));
    QPointer<QProcess> guard = m_activeProcess.data();
    QTimer::singleShot(3000, guard.data(), [this, guard] {
        if (guard && guard->state() != QProcess::NotRunning && guard->property("opUserCancelled").toBool()) {
            terminateProcessGroup(guard.data(), true);
        }
    });
}

void SlowrollBackend::handleProcessFinished(QProcess *proc, const QString &operationName, int exitCode, const QByteArray &output)
{
    const bool timedOut = proc && proc->property("opTimedOut").toBool();
    const bool userCancelled = proc && proc->property("opUserCancelled").toBool();
    const bool crashed = proc && (proc->exitStatus() == QProcess::CrashExit);
    const bool permDenied = proc && proc->property("opPermissionDeniedOnCancel").toBool();
    const bool effectiveUserCancelled = userCancelled && !permDenied;
    const bool failed = (exitCode != 0) || timedOut || effectiveUserCancelled || crashed;
    const QString outStr = QString::fromUtf8(output).trimmed();

    QString causeText;
    if (effectiveUserCancelled) {
        causeText = tr("annullata dall'utente");
    } else if (timedOut) {
        causeText = tr("interrotta per superamento del tempo massimo (timeout)");
    } else if (crashed) {
        causeText = tr("interrotta per terminazione anomala del processo");
    } else if (exitCode != 0) {
        causeText = tr("fallita con codice di uscita %1").arg(exitCode);
    }

    if (operationName == QStringLiteral("atomic-check")) {
        m_lastCheckTime = QDateTime::currentDateTime().toString(QStringLiteral("hh:mm - dd/MM/yyyy"));
        if (!failed) {
            setMessage(tr("Controllo aggiornamenti completato. %1").arg(outStr.isEmpty() ? tr("Nessun aggiornamento in sospeso.") : outStr));
        } else {
            setMessage(tr("Verifica aggiornamenti %1: %2").arg(causeText, outStr));
        }
        refreshAtomicState();
    } else if (operationName == QStringLiteral("cancel-reboot")) {
        if (!failed) {
            setMessage(tr("Transazione annullata con successo."));
        } else {
            m_needsInspection = true;
            m_atomicStatus = QStringLiteral("needs-inspection");
            m_atomicStateDescription = tr("Attenzione: annullamento transazione %1. Verificare lo stato del sistema prima di procedere con nuove operazioni.")
                .arg(causeText);
            emit atomicStatusChanged();
            setMessage(tr("Impossibile annullare la transazione (%1): %2").arg(causeText, outStr));
        }
        refreshAtomicState();
    } else if (operationName.startsWith(QStringLiteral("restart-service-"))) {
        const QString sName = operationName.mid(16);
        if (!failed) {
            setMessage(tr("Servizio %1 riavviato correttamente.").arg(sName));
        } else {
            setMessage(tr("Riavvio servizio %1 %2: %3").arg(sName, causeText, outStr));
        }
        refreshServices();
    } else if (operationName.startsWith(QStringLiteral("set-boot-next-"))) {
        const QString code = operationName.mid(14);
        if (!failed) {
            setMessage(tr("Prossimo avvio UEFI impostato con successo sulla voce #%1.").arg(code));
        } else {
            setMessage(tr("Impossibile impostare il prossimo avvio UEFI (%1): %2").arg(causeText, outStr));
        }
        refreshUefiEntries();
    } else if (operationName == QStringLiteral("clear-boot-next")) {
        if (!failed) {
            setMessage(tr("Voce di prossimo avvio UEFI (BootNext) annullata con successo."));
        } else {
            setMessage(tr("Impossibile annullare il prossimo avvio UEFI (%1): %2").arg(causeText, outStr));
        }
        refreshUefiEntries();
    }
}
bool SlowrollBackend::busy() const
{
    QMutexLocker locker(&m_busyMutex);
    return m_busy;
}

void SlowrollBackend::setBusy(bool b)
{
    {
        QMutexLocker locker(&m_busyMutex);
        if (m_busy == b) return;
        m_busy = b;
    }
    emit busyChanged();
}

void SlowrollBackend::setMessage(const QString &m)
{
    if (m_lastMessage == m) return;
    m_lastMessage = m;
    emit lastMessageChanged();
}

int SlowrollBackend::parseActiveSnapshotFromMountinfo(const QString &mountinfoContent)
{
    const QStringList lines = mountinfoContent.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    const QRegularExpression rx(QStringLiteral(R"(\.snapshots\/(\d+)\/snapshot)"));
    for (const QString &line : lines) {
        const QStringList parts = line.split(QLatin1Char(' '), Qt::SkipEmptyParts);
        if (parts.size() >= 5 && parts.at(4) == QStringLiteral("/")) {
            const auto match = rx.match(line);
            if (match.hasMatch()) {
                return match.captured(1).toInt();
            }
        }
    }
    return -1;
}

void SlowrollBackend::readAtomicStateFiles()
{
    // 1. Reset all derived variables to clean initial states
    m_activeSnapshot = -1;
    m_defaultSnapshot = -1;
    m_atomicStatus = QStringLiteral("idle");
    m_pendingReboot = false;
    m_needsInspection = false;
    m_atomicStateDescription = tr("Nessuna transazione atomica pendente (o aggiornamento atomico non configurato).");

    // 2. Discover active snapshot from /proc/self/mountinfo (instant, 0 external processes)
    QFile miFile(QStringLiteral("/proc/self/mountinfo"));
    if (miFile.open(QIODevice::ReadOnly | QIODevice::Text)) {
        m_activeSnapshot = parseActiveSnapshotFromMountinfo(QString::fromUtf8(miFile.readAll()));
    }

    // 3. Inspect real atomic state in /var/lib/myslowroll/atomic-update/state
    const QString statePath = QStringLiteral("/var/lib/myslowroll/atomic-update/state");
    QFile stateFile(statePath);
    if (stateFile.exists() && stateFile.open(QIODevice::ReadOnly | QIODevice::Text)) {
        QMap<QString, QString> kv;
        while (!stateFile.atEnd()) {
            const QString line = QString::fromUtf8(stateFile.readLine()).trimmed();
            if (line.isEmpty() || line.startsWith(QLatin1Char('#'))) continue;

            const int eq = line.indexOf(QLatin1Char('='));
            if (eq < 0) continue;
            const QString key = line.left(eq).trimmed();
            const QString val = line.mid(eq + 1).trimmed().remove(QLatin1Char('\'')).remove(QLatin1Char('"'));
            kv.insert(key, val);
        }

        if (kv.contains(QStringLiteral("target_snapshot"))) {
            bool ok = false;
            int target = kv.value(QStringLiteral("target_snapshot")).toInt(&ok);
            if (ok && target > 0) {
                m_defaultSnapshot = target;
            }
        }
        if (kv.contains(QStringLiteral("source_snapshot"))) {
            bool ok = false;
            int source = kv.value(QStringLiteral("source_snapshot")).toInt(&ok);
            if (ok && m_activeSnapshot < 0 && source > 0) {
                m_activeSnapshot = source;
            }
        }
        if (kv.contains(QStringLiteral("status"))) {
            const QString val = kv.value(QStringLiteral("status"));
            m_atomicStatus = val;
            if (val == QStringLiteral("pending-reboot")) {
                m_pendingReboot = true;
                const int snapNum = m_defaultSnapshot > 0 ? m_defaultSnapshot : (m_activeSnapshot > 0 ? m_activeSnapshot : 0);
                m_atomicStateDescription = tr("Aggiornamento atomico completato. Riavviare il sistema per attivare lo snapshot #%1.")
                    .arg(snapNum);
            } else if (val == QStringLiteral("needs-inspection")) {
                m_needsInspection = true;
                m_atomicStateDescription = tr("Attenzione: la transazione precedente richiede ispezione manuale.");
            } else if (val == QStringLiteral("rolled-back")) {
                if (m_activeSnapshot > 0) {
                    m_atomicStateDescription = tr("Sistema ripristinato allo snapshot #%1.").arg(m_activeSnapshot);
                } else {
                    m_atomicStateDescription = tr("Sistema ripristinato (snapshot attivo non determinato).");
                }
            } else if (val == QStringLiteral("confirmed")) {
                m_atomicStateDescription = tr("Aggiornamento confermato e operativo.");
            } else if (val == QStringLiteral("planned")) {
                m_atomicStateDescription = tr("Piano di aggiornamento verificato e pronto all'installazione.");
            } else {
                m_atomicStateDescription = tr("Stato transazionale: %1").arg(val);
            }
        }
    }

    if (m_defaultSnapshot < 0 && m_activeSnapshot > 0) {
        m_defaultSnapshot = m_activeSnapshot;
    }

    emit atomicStatusChanged();
}
void SlowrollBackend::refreshAtomicState()
{
    readAtomicStateFiles();
}

void SlowrollBackend::parseSnapperOutput(const QString &csvData)
{
    const QStringList lines = csvData.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    if (lines.isEmpty()) {
        m_snapshots.clear();
        emit snapshotsChanged();
        return;
    }

    int headerRow = -1;
    QStringList headerCols;
    for (int r = 0; r < lines.size(); ++r) {
        const QStringList candidate = parseCsvLine(lines.at(r));
        for (const QString &col : candidate) {
            const QString h = col.trimmed().toLower();
            if (h == QStringLiteral("number") || h == QStringLiteral("#")) {
                headerRow = r;
                headerCols = candidate;
                break;
            }
        }
        if (headerRow >= 0) break;
    }

    if (headerRow == -1) {
        m_snapshots.clear();
        emit snapshotsChanged();
        setMessage(tr("Formato snapshot Snapper non riconosciuto. Dati non disponibili."));
        return;
    }

    int colNumber = -1;
    int colDefault = -1;
    int colActive = -1;
    int colType = -1;
    int colDate = -1;
    int colDescription = -1;

    for (int c = 0; c < headerCols.size(); ++c) {
        const QString h = headerCols.at(c).trimmed().toLower();
        if (h == QStringLiteral("number") || h == QStringLiteral("#")) {
            colNumber = c;
        } else if (h == QStringLiteral("default")) {
            colDefault = c;
        } else if (h == QStringLiteral("active")) {
            colActive = c;
        } else if (h == QStringLiteral("type")) {
            colType = c;
        } else if (h == QStringLiteral("date")) {
            colDate = c;
        } else if (h == QStringLiteral("description")) {
            colDescription = c;
        }
    }

    QVariantList list;
    for (int i = headerRow + 1; i < lines.size(); ++i) {
        const QStringList cols = parseCsvLine(lines.at(i));
        if (cols.size() <= colNumber) continue;

        bool ok = false;
        int num = cols.at(colNumber).trimmed().toInt(&ok);
        if (!ok) continue;

        const bool isDef = (colDefault >= 0 && colDefault < cols.size())
            ? (cols.at(colDefault).trimmed().toLower() == QStringLiteral("yes"))
            : false;
        const bool isAct = (colActive >= 0 && colActive < cols.size())
            ? (cols.at(colActive).trimmed().toLower() == QStringLiteral("yes"))
            : false;
        const QString type = (colType >= 0 && colType < cols.size())
            ? cols.at(colType).trimmed()
            : QString();
        const QString date = (colDate >= 0 && colDate < cols.size())
            ? cols.at(colDate).trimmed()
            : QString();
        const QString desc = (colDescription >= 0 && colDescription < cols.size())
            ? cols.at(colDescription).trimmed()
            : QString();

        if (isAct) m_activeSnapshot = num;
        if (isDef && !m_pendingReboot) m_defaultSnapshot = num;

        QVariantMap row;
        row.insert(QStringLiteral("number"), num);
        row.insert(QStringLiteral("isDefault"), isDef);
        row.insert(QStringLiteral("isActive"), isAct);
        row.insert(QStringLiteral("type"), type);
        row.insert(QStringLiteral("date"), date);
        row.insert(QStringLiteral("description"), desc.isEmpty() ? (type == QStringLiteral("pre") ? tr("Prima dell'operazione") : tr("Snapshot")) : desc);
        list.append(row);
    }

    m_snapshots = list;
    emit snapshotsChanged();
    emit atomicStatusChanged();
}

void SlowrollBackend::refreshSnapshots()
{
    // Gli snapshot attivo e predefinito sono già rilevati istantaneamente da readAtomicStateFiles().
    // La gestione completa è delegata al modulo ufficiale YaST Snapper.
    m_snapshots.clear();
    emit snapshotsChanged();
}

void SlowrollBackend::refreshServices()
{
    // 1. Check failed units
    QProcess *failedProc = new QProcess(this);
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("LC_ALL"), QStringLiteral("C.UTF-8"));
    env.insert(QStringLiteral("LANG"), QStringLiteral("C.UTF-8"));
    failedProc->setProcessEnvironment(env);

    connect(failedProc, &QProcess::finished, this, [this, failedProc](int exitCode, QProcess::ExitStatus) {
        if (exitCode == 0) {
            const QString out = QString::fromUtf8(failedProc->readAllStandardOutput()).trimmed();
            QStringList failed;
            if (!out.isEmpty() && !out.contains(QStringLiteral("0 loaded units listed"))) {
                const QStringList lines = out.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
                for (const QString &line : lines) {
                    QString trimmed = line.trimmed();
                    // Strip systemd bullet ● (0x25CF), * or whitespace
                    while (!trimmed.isEmpty() && (trimmed.startsWith(QLatin1Char('*')) || trimmed.startsWith(QChar(0x25CF)) || trimmed.at(0).isSpace())) {
                        trimmed = trimmed.mid(1).trimmed();
                    }
                    if (!trimmed.isEmpty()) {
                        failed.append(trimmed);
                    }
                }
            }
            m_failedUnits = failed;
            emit servicesChanged();
        }
        failedProc->deleteLater();
    });
    connect(failedProc, &QProcess::errorOccurred, this, [this, failedProc](QProcess::ProcessError err) {
        if (err == QProcess::FailedToStart) {
            setMessage(tr("Impossibile avviare systemctl per la verifica delle unità."));
        }
        failedProc->deleteLater();
    });
    QPointer<QProcess> guardFailed = failedProc;
    QTimer::singleShot(5000, failedProc, [guardFailed] {
        if (guardFailed && guardFailed->state() != QProcess::NotRunning) {
            guardFailed->kill();
        }
    });
    failedProc->start(QStringLiteral("systemctl"), {
        QStringLiteral("list-units"),
        QStringLiteral("--failed"),
        QStringLiteral("--no-legend"),
        QStringLiteral("--plain")
    });

    // 2. Check key services states (firewalld, NetworkManager, bluetooth, cups) by Id and ActiveState properties
    QProcess *servicesProc = new QProcess(this);
    servicesProc->setProcessEnvironment(env);
    connect(servicesProc, &QProcess::finished, this, [this, servicesProc](int exitCode, QProcess::ExitStatus) {
        if (exitCode == 0) {
            const QString out = QString::fromUtf8(servicesProc->readAllStandardOutput());
            const QStringList blocks = out.split(QRegularExpression(QStringLiteral(R"(\n\s*\n)")), Qt::SkipEmptyParts);
            QVariantMap map;
            for (const QString &block : blocks) {
                const QStringList blockLines = block.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
                QString id;
                QString active;
                for (const QString &line : blockLines) {
                    const QString trimmed = line.trimmed();
                    if (trimmed.startsWith(QStringLiteral("Id="))) {
                        id = trimmed.mid(3).trimmed();
                    } else if (trimmed.startsWith(QStringLiteral("ActiveState="))) {
                        active = trimmed.mid(12).trimmed();
                    }
                }
                if (!id.isEmpty()) {
                    map.insert(id, active.isEmpty() ? QStringLiteral("inactive") : active);
                }
            }

            // Socket activation fallback: if cups.service is inactive/loaded but cups.socket is active
            if (map.value(QStringLiteral("cups.service")).toString() != QStringLiteral("active") &&
                map.value(QStringLiteral("cups.socket")).toString() == QStringLiteral("active")) {
                map.insert(QStringLiteral("cups.service"), QStringLiteral("active (socket)"));
            }

            m_keyServices = map;
            emit servicesChanged();
        }
        servicesProc->deleteLater();
    });
    connect(servicesProc, &QProcess::errorOccurred, this, [this, servicesProc](QProcess::ProcessError err) {
        if (err == QProcess::FailedToStart) {
            setMessage(tr("Impossibile verificare lo stato dei servizi con systemctl."));
        }
        servicesProc->deleteLater();
    });
    QPointer<QProcess> guardServices = servicesProc;
    QTimer::singleShot(5000, servicesProc, [guardServices] {
        if (guardServices && guardServices->state() != QProcess::NotRunning) {
            guardServices->kill();
        }
    });
    servicesProc->start(QStringLiteral("systemctl"), {
        QStringLiteral("show"),
        QStringLiteral("firewalld.service"),
        QStringLiteral("NetworkManager.service"),
        QStringLiteral("bluetooth.service"),
        QStringLiteral("cups.service"),
        QStringLiteral("cups.socket"),
        QStringLiteral("--property=Id,ActiveState,LoadState")
    });
}

void SlowrollBackend::refreshRepositories()
{
    QVariantList repos;
    const QDir repoDir(QStringLiteral("/etc/zypp/repos.d"));
    const QStringList files = repoDir.entryList({QStringLiteral("*.repo")}, QDir::Files, QDir::Name);

    for (const QString &file : files) {
        QSettings ini(repoDir.filePath(file), QSettings::IniFormat);
        for (const QString &alias : ini.childGroups()) {
            ini.beginGroup(alias);
            QVariantMap map;
            map.insert(QStringLiteral("alias"), alias);
            map.insert(QStringLiteral("name"), ini.value(QStringLiteral("name"), alias).toString());
            map.insert(QStringLiteral("url"), ini.value(QStringLiteral("baseurl")).toString());
            map.insert(QStringLiteral("enabled"), ini.value(QStringLiteral("enabled"), 1).toInt() == 1);
            map.insert(QStringLiteral("autorefresh"), ini.value(QStringLiteral("autorefresh"), 1).toInt() == 1);
            repos.append(map);
            ini.endGroup();
        }
    }

    std::sort(repos.begin(), repos.end(), [](const QVariant &a, const QVariant &b) {
        const bool enA = a.toMap().value(QStringLiteral("enabled")).toBool();
        const bool enB = b.toMap().value(QStringLiteral("enabled")).toBool();
        if (enA != enB) {
            return enA > enB; // Attivi (true) prima dei disattivi (false)
        }
        return a.toMap().value(QStringLiteral("name")).toString()
                   .localeAwareCompare(b.toMap().value(QStringLiteral("name")).toString()) < 0;
    });

    m_repositories = repos;
    emit repositoriesChanged();
}

void SlowrollBackend::refreshAll()
{
    refreshAtomicState();
    refreshServices();
    // Snapshot e repository vengono caricati solo su richiesta esplicita per evitare invocazioni superflue all'avvio
    refreshUefiEntries();
}

void SlowrollBackend::checkAtomicUpdates()
{
    const QString atomicExe = findAtomicUpdate();
    if (atomicExe.isEmpty()) {
        setMessage(tr("atomic-update non trovato nel sistema."));
        return;
    }
    QProcess *proc = startProcess(QStringLiteral("pkexec"), {atomicExe, QStringLiteral("check")},
                                  QStringLiteral("atomic-check"), false, 45000);
    if (proc) {
        setMessage(tr("Verifica aggiornamenti atomic-update in corso..."));
    }
}

void SlowrollBackend::cancelPendingReboot()
{
    const QString atomicExe = findAtomicUpdate();
    if (atomicExe.isEmpty()) {
        setMessage(tr("atomic-update non trovato nel sistema."));
        return;
    }
    QProcess *proc = startProcess(QStringLiteral("pkexec"), {atomicExe, QStringLiteral("recover"), QStringLiteral("clear-opening")},
                                  QStringLiteral("cancel-reboot"), false, 30000);
    if (proc) {
        setMessage(tr("Annullamento della transazione pendente in corso..."));
    }
}

void SlowrollBackend::restartService(const QString &serviceName)
{
    if (serviceName.isEmpty()) return;
    static const QRegularExpression unitRx(QStringLiteral("^[A-Za-z0-9@_][A-Za-z0-9@._:-]*\\.(service|socket|timer)$"));
    if (!unitRx.match(serviceName).hasMatch()) {
        setMessage(tr("Nome servizio non valido: %1").arg(serviceName));
        return;
    }
    const QString systemctl = findTrustedSystemBinary(QStringLiteral("systemctl"));
    if (systemctl.isEmpty()) {
        setMessage(tr("systemctl non disponibile nel sistema."));
        return;
    }
    // Su openSUSE systemctl gestisce nativamente l'autenticazione Polkit in sessione grafica
    QProcess *proc = startProcess(systemctl, {QStringLiteral("restart"), QStringLiteral("--"), serviceName},
                                  QStringLiteral("restart-service-%1").arg(serviceName), true, 15000);
    if (proc) {
        setMessage(tr("Riavvio del servizio %1 in corso...").arg(serviceName));
    }
}
void SlowrollBackend::loadServiceJournal(const QString &serviceName)
{
    if (serviceName.isEmpty()) return;
    static const QRegularExpression unitRx(QStringLiteral("^[A-Za-z0-9@_][A-Za-z0-9@._:-]*\\.(service|socket|timer)$"));
    if (!unitRx.match(serviceName).hasMatch()) {
        m_serviceJournal = tr("Nome servizio non valido.");
        emit serviceJournalChanged();
        return;
    }
    m_serviceJournal = tr("Caricamento log di %1...").arg(serviceName);
    emit serviceJournalChanged();

    auto *proc = new QProcess(this);
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("LC_ALL"), QStringLiteral("C.UTF-8"));
    env.insert(QStringLiteral("LANG"), QStringLiteral("C.UTF-8"));
    proc->setProcessEnvironment(env);
    connect(proc, &QProcess::finished, this, [this, proc](int, QProcess::ExitStatus) {
        m_serviceJournal = QString::fromUtf8(proc->readAllStandardOutput()).trimmed();
        if (m_serviceJournal.isEmpty()) {
            m_serviceJournal = tr("Nessun log disponibile per questa unità.");
        }
        emit serviceJournalChanged();
        proc->deleteLater();
    });
    connect(proc, &QProcess::errorOccurred, this, [this, proc](QProcess::ProcessError) {
        m_serviceJournal = tr("Impossibile avviare journalctl per questa unità.");
        emit serviceJournalChanged();
        proc->deleteLater();
    });
    QPointer<QProcess> guard = proc;
    QTimer::singleShot(5000, proc, [guard] {
        if (guard && guard->state() != QProcess::NotRunning) {
            guard->kill();
        }
    });

    proc->start(QStringLiteral("journalctl"), {QStringLiteral("-u"), serviceName, QStringLiteral("-n"), QStringLiteral("120"), QStringLiteral("--no-pager")});
}

void SlowrollBackend::clearServiceJournal()
{
    m_serviceJournal.clear();
    emit serviceJournalChanged();
}

void SlowrollBackend::clearMessage()
{
    m_lastMessage.clear();
    emit lastMessageChanged();
}

QVariantList SlowrollBackend::parseUefiEntries(const QString &output,
                                               QString &currentCode,
                                               QString &nextCode,
                                               QString &currentLabel,
                                               QString &nextLabel)
{
    currentCode.clear();
    nextCode.clear();
    currentLabel.clear();
    nextLabel.clear();
    QVariantList list;

    static const QRegularExpression currentRx(QStringLiteral(R"((?m)^BootCurrent:\s*([0-9A-Fa-f]{4}))"));
    static const QRegularExpression nextRx(QStringLiteral(R"((?m)^BootNext:\s*([0-9A-Fa-f]{4}))"));
    static const QRegularExpression orderRx(QStringLiteral(R"((?m)^BootOrder:\s*([0-9A-Fa-f]{4}(?:,[0-9A-Fa-f]{4})*))"));
    static const QRegularExpression entryRx(QStringLiteral(R"((?m)^Boot([0-9A-Fa-f]{4})\*?\s+(.+)$)"));

    auto curMatch = currentRx.match(output);
    if (curMatch.hasMatch()) {
        currentCode = curMatch.captured(1).toUpper();
    }

    auto nextMatch = nextRx.match(output);
    if (nextMatch.hasMatch()) {
        nextCode = nextMatch.captured(1).toUpper();
    }

    QStringList bootOrder;
    auto orderMatch = orderRx.match(output);
    if (orderMatch.hasMatch()) {
        const QString rawOrder = orderMatch.captured(1);
        const QStringList tokens = rawOrder.split(QLatin1Char(','), Qt::SkipEmptyParts);
        for (const QString &t : tokens) {
            bootOrder.append(t.trimmed().toUpper());
        }
    }

    QHash<QString, QVariantMap> byCode;
    auto it = entryRx.globalMatch(output);
    while (it.hasNext()) {
        auto m = it.next();
        const QString code = m.captured(1).toUpper();
        QString desc = m.captured(2).trimmed();
        const int tabIdx = desc.indexOf(QLatin1Char('\t'));
        if (tabIdx >= 0) {
            desc = desc.left(tabIdx).trimmed();
        }
        if (desc.isEmpty()) desc = tr("Voce %1").arg(code);

        QVariantMap entry;
        entry.insert(QStringLiteral("code"), code);
        entry.insert(QStringLiteral("name"), desc);
        entry.insert(QStringLiteral("label"), QStringLiteral("[%1] %2").arg(code, desc));
        entry.insert(QStringLiteral("isCurrent"), code == currentCode);
        entry.insert(QStringLiteral("isNext"), code == nextCode);
        entry.insert(QStringLiteral("orderIndex"), bootOrder.indexOf(code));

        byCode.insert(code, entry);

        if (code == currentCode) {
            currentLabel = desc;
        }
        if (code == nextCode) {
            nextLabel = desc;
        }
    }

    for (const QString &code : bootOrder) {
        if (byCode.contains(code)) {
            list.append(byCode.take(code));
        }
    }
    QStringList remainingKeys = byCode.keys();
    remainingKeys.sort();
    for (const QString &code : remainingKeys) {
        list.append(byCode.value(code));
    }

    return list;
}

bool SlowrollBackend::efiSystem() const
{
    return QFileInfo::exists(QStringLiteral("/sys/firmware/efi"));
}

void SlowrollBackend::resetUefiState()
{
    m_uefiAvailable = false;
    m_uefiEntries.clear();
    m_uefiCurrentBootCode.clear();
    m_uefiCurrentBootLabel.clear();
    m_uefiNextBootCode.clear();
    m_uefiNextBootLabel.clear();
    emit uefiEntriesChanged();
}

void SlowrollBackend::refreshUefiEntries()
{
    if (!efiSystem()) {
        resetUefiState();
        return;
    }
    const QString exe = findEfibootmgr();
    if (exe.isEmpty()) {
        resetUefiState();
        return;
    }

    auto *proc = new QProcess(this);
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("LC_ALL"), QStringLiteral("C.UTF-8"));
    env.insert(QStringLiteral("LANG"), QStringLiteral("C.UTF-8"));
    proc->setProcessEnvironment(env);
    connect(proc, &QProcess::finished, this, [this, proc](int exitCode, QProcess::ExitStatus status) {
        if (exitCode == 0 && status == QProcess::NormalExit) {
            m_uefiAvailable = true;
            m_uefiEntries = parseUefiEntries(QString::fromUtf8(proc->readAllStandardOutput()),
                                             m_uefiCurrentBootCode,
                                             m_uefiNextBootCode,
                                             m_uefiCurrentBootLabel,
                                             m_uefiNextBootLabel);
            emit uefiEntriesChanged();
        } else {
            resetUefiState();
        }
        proc->deleteLater();
    });
    connect(proc, &QProcess::errorOccurred, this, [this, proc](QProcess::ProcessError) {
        resetUefiState();
        proc->deleteLater();
    });
    QPointer<QProcess> guard = proc;
    QTimer::singleShot(4000, proc, [guard] {
        if (guard && guard->state() != QProcess::NotRunning) {
            guard->kill();
        }
    });
    proc->start(exe, {});
}

void SlowrollBackend::setUefiBootNext(const QString &bootCode)
{
    const QString token = bootCode.trimmed().toUpper();
    static const QRegularExpression codeRx(QStringLiteral("^[0-9A-Fa-f]{4}$"));
    if (!codeRx.match(token).hasMatch()) {
        setMessage(tr("Codice boot UEFI non valido: %1").arg(bootCode));
        return;
    }
    const QString exe = findEfibootmgr();
    if (exe.isEmpty()) {
        setMessage(tr("efibootmgr non è disponibile nel sistema."));
        return;
    }
    QProcess *proc = startProcess(QStringLiteral("pkexec"), {exe, QStringLiteral("-n"), token},
                                  QStringLiteral("set-boot-next-") + token, false, 15000);
    if (proc) {
        setMessage(tr("Impostazione del prossimo avvio sulla voce UEFI #%1 in corso...").arg(token));
    }
}

void SlowrollBackend::clearUefiBootNext()
{
    const QString exe = findEfibootmgr();
    if (exe.isEmpty()) {
        setMessage(tr("efibootmgr non è disponibile nel sistema."));
        return;
    }
    QProcess *proc = startProcess(QStringLiteral("pkexec"), {exe, QStringLiteral("-N")},
                                  QStringLiteral("clear-boot-next"), false, 15000);
    if (proc) {
        setMessage(tr("Cancellazione della voce di prossimo avvio UEFI in corso..."));
    }
}

