#pragma once

#include <QObject>
#include <QMutex>
#include <QPointer>
#include <QProcess>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>

class SlowrollBackend : public QObject
{
    Q_OBJECT
    friend class DomainTest;
    Q_PROPERTY(QString atomicStatus READ atomicStatus NOTIFY atomicStatusChanged)
    Q_PROPERTY(QString atomicStateDescription READ atomicStateDescription NOTIFY atomicStatusChanged)
    Q_PROPERTY(int activeSnapshot READ activeSnapshot NOTIFY atomicStatusChanged)
    Q_PROPERTY(int defaultSnapshot READ defaultSnapshot NOTIFY atomicStatusChanged)
    Q_PROPERTY(bool pendingReboot READ pendingReboot NOTIFY atomicStatusChanged)
    Q_PROPERTY(bool needsInspection READ needsInspection NOTIFY atomicStatusChanged)
    Q_PROPERTY(QString lastCheckTime READ lastCheckTime NOTIFY atomicStatusChanged)

    Q_PROPERTY(QVariantList snapshots READ snapshots NOTIFY snapshotsChanged)
    Q_PROPERTY(QVariantMap keyServices READ keyServices NOTIFY servicesChanged)
    Q_PROPERTY(QStringList failedUnits READ failedUnits NOTIFY servicesChanged)

    Q_PROPERTY(QVariantList repositories READ repositories NOTIFY repositoriesChanged)
    Q_PROPERTY(QString serviceJournal READ serviceJournal NOTIFY serviceJournalChanged)

    Q_PROPERTY(QVariantList uefiEntries READ uefiEntries NOTIFY uefiEntriesChanged)
    Q_PROPERTY(QString uefiCurrentBootCode READ uefiCurrentBootCode NOTIFY uefiEntriesChanged)
    Q_PROPERTY(QString uefiCurrentBootLabel READ uefiCurrentBootLabel NOTIFY uefiEntriesChanged)
    Q_PROPERTY(QString uefiNextBootCode READ uefiNextBootCode NOTIFY uefiEntriesChanged)
    Q_PROPERTY(QString uefiNextBootLabel READ uefiNextBootLabel NOTIFY uefiEntriesChanged)
    Q_PROPERTY(bool uefiAvailable READ uefiAvailable NOTIFY uefiEntriesChanged)
    Q_PROPERTY(bool efiSystem READ efiSystem CONSTANT)

    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(bool isOperationCancellable READ isOperationCancellable NOTIFY busyChanged)
    Q_PROPERTY(QString lastMessage READ lastMessage NOTIFY lastMessageChanged)

public:
    explicit SlowrollBackend(QObject *parent = nullptr);
    ~SlowrollBackend() override;

    Q_INVOKABLE void initialize();
    bool isOperationCancellable() const { return m_activeProcess && m_activeProcess->property("opCancellable").toBool(); }

    QString atomicStatus() const { return m_atomicStatus; }
    QString atomicStateDescription() const { return m_atomicStateDescription; }
    int activeSnapshot() const { return m_activeSnapshot; }
    int defaultSnapshot() const { return m_defaultSnapshot; }
    bool pendingReboot() const { return m_pendingReboot; }
    bool needsInspection() const { return m_needsInspection; }
    QString lastCheckTime() const { return m_lastCheckTime; }

    const QVariantList &snapshots() const { return m_snapshots; }
    const QVariantMap &keyServices() const { return m_keyServices; }
    const QStringList &failedUnits() const { return m_failedUnits; }
    const QVariantList &repositories() const { return m_repositories; }
    QString serviceJournal() const { return m_serviceJournal; }

    const QVariantList &uefiEntries() const { return m_uefiEntries; }
    QString uefiCurrentBootCode() const { return m_uefiCurrentBootCode; }
    QString uefiCurrentBootLabel() const { return m_uefiCurrentBootLabel; }
    QString uefiNextBootCode() const { return m_uefiNextBootCode; }
    QString uefiNextBootLabel() const { return m_uefiNextBootLabel; }
    bool uefiAvailable() const { return m_uefiAvailable; }
    bool efiSystem() const;

    bool busy() const;
    QString lastMessage() const { return m_lastMessage; }

    Q_INVOKABLE void refreshAtomicState();
    Q_INVOKABLE void refreshSnapshots();
    Q_INVOKABLE void refreshServices();
    Q_INVOKABLE void refreshRepositories();
    Q_INVOKABLE void refreshUefiEntries();
    Q_INVOKABLE void refreshAll();

    Q_INVOKABLE void checkAtomicUpdates();
    Q_INVOKABLE void cancelPendingReboot();
    Q_INVOKABLE void restartService(const QString &serviceName);
    Q_INVOKABLE void loadServiceJournal(const QString &serviceName);
    Q_INVOKABLE void clearServiceJournal();
    Q_INVOKABLE void setUefiBootNext(const QString &bootCode);
    Q_INVOKABLE void clearUefiBootNext();
    Q_INVOKABLE void clearMessage();
    Q_INVOKABLE void cancelCurrentOperation();

    // Pure parsing utilities accessible to unit tests
    void parseSnapperOutput(const QString &output);
    static int parseActiveSnapshotFromMountinfo(const QString &mountinfoContent);
    static QVariantList parseUefiEntries(const QString &output,
                                         QString &currentCode,
                                         QString &nextCode,
                                         QString &currentLabel,
                                         QString &nextLabel);
    static QVariantMap parseSystemctlShowOutput(const QString &output);

signals:
    void atomicStatusChanged();
    void snapshotsChanged();
    void servicesChanged();
    void repositoriesChanged();
    void serviceJournalChanged();
    void uefiEntriesChanged();
    void busyChanged();
    void lastMessageChanged();

private:
    QProcess *startProcess(const QString &program, const QStringList &arguments,
                           const QString &operationName, bool cancellable, int timeoutMs);
    void handleProcessFinished(QProcess *proc, const QString &operationName, int exitCode, const QByteArray &output);
    void terminateProcessGroup(QProcess *proc, bool force);

    void resetUefiState();
    void readAtomicStateFiles();

    void setBusy(bool b);
    void setMessage(const QString &m);

    QString m_atomicStatus = QStringLiteral("idle");
    QString m_atomicStateDescription = QStringLiteral("Stato del sistema nominale.");
    int m_activeSnapshot = -1;
    int m_defaultSnapshot = -1;
    bool m_pendingReboot = false;
    bool m_needsInspection = false;
    QString m_lastCheckTime;

    QVariantList m_snapshots;
    QVariantMap m_keyServices;
    QStringList m_failedUnits;
    quint64 m_servicesRequestId = 0;
    QVariantList m_repositories;
    QString m_serviceJournal;

    QVariantList m_uefiEntries;
    QString m_uefiCurrentBootCode;
    QString m_uefiCurrentBootLabel;
    QString m_uefiNextBootCode;
    QString m_uefiNextBootLabel;
    bool m_uefiAvailable = false;

    bool m_busy = false;
    mutable QMutex m_busyMutex;
    QString m_lastMessage;

    QPointer<QProcess> m_activeProcess;
};
