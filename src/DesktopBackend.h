#pragma once

#include <QObject>
#include <QMutex>
#include <QPointer>
#include <QProcess>
#include <QString>
#include <QStringList>
#include <QUrl>
#include <QVariantList>
#include <QVariantMap>

class DesktopBackend : public QObject
{
    Q_OBJECT
    friend class DomainTest;
    Q_PROPERTY(QString appVersion READ appVersion CONSTANT)
    Q_PROPERTY(int cpuUsagePercent READ cpuUsagePercent NOTIFY resourcesChanged)
    Q_PROPERTY(qint64 memoryUsedMiB READ memoryUsedMiB NOTIFY resourcesChanged)
    Q_PROPERTY(qint64 memoryTotalMiB READ memoryTotalMiB NOTIFY resourcesChanged)
    Q_PROPERTY(int memoryPercent READ memoryPercent NOTIFY resourcesChanged)
    Q_PROPERTY(double cpuTemperatureC READ cpuTemperatureC NOTIFY resourcesChanged)
    Q_PROPERTY(qint64 diskRootTotalGiB READ diskRootTotalGiB NOTIFY resourcesChanged)
    Q_PROPERTY(qint64 diskRootAvailableGiB READ diskRootAvailableGiB NOTIFY resourcesChanged)
    Q_PROPERTY(int diskRootPercent READ diskRootPercent NOTIFY resourcesChanged)
    Q_PROPERTY(qint64 diskHomeTotalGiB READ diskHomeTotalGiB NOTIFY resourcesChanged)
    Q_PROPERTY(qint64 diskHomeAvailableGiB READ diskHomeAvailableGiB NOTIFY resourcesChanged)
    Q_PROPERTY(int diskHomePercent READ diskHomePercent NOTIFY resourcesChanged)

    Q_PROPERTY(QString powerProfile READ powerProfile NOTIFY powerProfileChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY stateChanged)
    Q_PROPERTY(bool isOperationCancellable READ isOperationCancellable NOTIFY stateChanged)
    Q_PROPERTY(QString lastMessage READ lastMessage NOTIFY stateChanged)
    Q_PROPERTY(QString diagnosticTitle READ diagnosticTitle NOTIFY diagnosticChanged)
    Q_PROPERTY(QString diagnosticOutput READ diagnosticOutput NOTIFY diagnosticChanged)

    Q_PROPERTY(QVariantList customActions READ customActions NOTIFY customActionsChanged)
    Q_PROPERTY(QString actionOutput READ actionOutput NOTIFY actionStateChanged)
    Q_PROPERTY(QString actionError READ actionError NOTIFY actionStateChanged)
    Q_PROPERTY(bool actionRunning READ actionRunning NOTIFY actionStateChanged)

    Q_PROPERTY(bool networkConnected READ networkConnected NOTIFY networkStatusChanged)
    Q_PROPERTY(QString networkActiveConnection READ networkActiveConnection NOTIFY networkStatusChanged)
    Q_PROPERTY(QString networkInterface READ networkInterface NOTIFY networkStatusChanged)
    Q_PROPERTY(QString networkIpAddress READ networkIpAddress NOTIFY networkStatusChanged)
    Q_PROPERTY(QString networkGateway READ networkGateway NOTIFY networkStatusChanged)
    Q_PROPERTY(QString networkDns READ networkDns NOTIFY networkStatusChanged)

    Q_PROPERTY(QVariantList ipPresets READ ipPresets NOTIFY networkPresetsChanged)
    Q_PROPERTY(QVariantList dnsPresets READ dnsPresets NOTIFY networkPresetsChanged)
    Q_PROPERTY(int selectedIpPreset READ selectedIpPreset NOTIFY networkPresetsChanged)
    Q_PROPERTY(int selectedDnsPreset READ selectedDnsPreset NOTIFY networkPresetsChanged)
    Q_PROPERTY(QString httpsAddress READ httpsAddress NOTIFY networkPresetsChanged)
    Q_PROPERTY(QString promptStatus READ bashPromptStatus NOTIFY promptStatusChanged)
    Q_PROPERTY(bool micMuted READ micMuted NOTIFY micStatusChanged)
    Q_PROPERTY(bool privacyActive READ privacyActive NOTIFY privacyStatusChanged)

    Q_PROPERTY(bool wifiEnabled READ wifiEnabled NOTIFY wifiChanged)
    Q_PROPERTY(bool hasWifiHardware READ hasWifiHardware NOTIFY wifiChanged)
    Q_PROPERTY(bool wifiHardwareBlocked READ wifiHardwareBlocked NOTIFY wifiChanged)
    Q_PROPERTY(QString wifiStatusString READ wifiStatusString NOTIFY wifiChanged)
    Q_PROPERTY(QVariantList topMemoryProcesses READ topMemoryProcesses NOTIFY topProcessesChanged)

public:
    static bool validateIpv4Cidr(const QString &ip, QString *outCleanCidr = nullptr);
    static bool validateGateway(const QString &gw);
    static bool validateDns(const QString &dns, QStringList *outDnsServers = nullptr);
    explicit DesktopBackend(QObject *parent = nullptr);
    ~DesktopBackend() override;

    QString appVersion() const { return QStringLiteral(MYSLOWROLL_CC_VERSION); }
    int cpuUsagePercent() const { return m_cpuUsagePercent; }
    qint64 memoryUsedMiB() const { return m_memoryUsedMiB; }
    qint64 memoryTotalMiB() const { return m_memoryTotalMiB; }
    int memoryPercent() const;
    double cpuTemperatureC() const { return m_cpuTemperatureC; }
    qint64 diskRootTotalGiB() const { return m_diskRootTotalGiB; }
    qint64 diskRootAvailableGiB() const { return m_diskRootAvailableGiB; }
    int diskRootPercent() const;
    qint64 diskHomeTotalGiB() const { return m_diskHomeTotalGiB; }
    qint64 diskHomeAvailableGiB() const { return m_diskHomeAvailableGiB; }
    int diskHomePercent() const;

    QString powerProfile() const { return m_powerProfile; }
    bool busy() const;
    bool isOperationCancellable() const { return m_activeProcess && m_activeProcess->property("opCancellable").toBool(); }
    QString lastMessage() const { return m_lastMessage; }
    QString diagnosticTitle() const { return m_diagnosticTitle; }
    QString diagnosticOutput() const { return m_diagnosticOutput; }

    const QVariantList &customActions() const { return m_customActions; }
    QString actionOutput() const { return m_actionOutput; }
    QString actionError() const { return m_actionError; }
    bool actionRunning() const { return m_actionRunning; }

    bool networkConnected() const { return m_networkConnected; }
    QString networkActiveConnection() const { return m_networkActiveConnection; }
    QString networkInterface() const { return m_networkInterface; }
    QString networkIpAddress() const { return m_networkIpAddress; }
    QString networkGateway() const { return m_networkGateway; }
    QString networkDns() const { return m_networkDns; }

    const QVariantList &ipPresets() const { return m_ipPresets; }
    const QVariantList &dnsPresets() const { return m_dnsPresets; }
    int selectedIpPreset() const { return m_selectedIpPreset; }
    int selectedDnsPreset() const { return m_selectedDnsPreset; }
    QString httpsAddress() const { return m_httpsAddress; }

    bool wifiEnabled() const { return m_wifiEnabled; }
    bool hasWifiHardware() const { return m_hasWifiHardware; }
    bool wifiHardwareBlocked() const { return m_wifiHardwareBlocked; }
    QString wifiStatusString() const { return m_wifiStatusString; }
    const QVariantList &topMemoryProcesses() const { return m_topMemoryProcesses; }

    bool micMuted() const { return m_micMuted; }
    bool privacyActive() const { return m_privacyActive; }
    Q_INVOKABLE void refreshResources();
    Q_INVOKABLE void refreshMicStatus();
    Q_INVOKABLE void toggleMic();
    Q_INVOKABLE void refreshPrivacyStatus();
    Q_INVOKABLE void togglePrivacy();
    Q_INVOKABLE void refreshPowerProfile();
    Q_INVOKABLE void setPowerProfile(const QString &profile);

    Q_INVOKABLE void restartAudio();
    Q_INVOKABLE void flushDns();

    Q_INVOKABLE void refreshNetworkStatus();
    Q_INVOKABLE void refreshWifiStatus();
    Q_INVOKABLE void toggleWifi();
    Q_INVOKABLE void setWifiEnabled(bool enable);
    Q_INVOKABLE void refreshTopMemoryProcesses();
    Q_INVOKABLE void selectIpPreset(int index);
    Q_INVOKABLE void selectDnsPreset(int index);
    Q_INVOKABLE void setHttpsAddress(const QString &url);
    Q_INVOKABLE bool saveIpPreset(int index, const QString &name, const QString &address, const QString &gateway);
    Q_INVOKABLE bool saveDnsPreset(int index, const QString &name, const QString &dns, const QString &dohUrl);
    Q_INVOKABLE void applyActiveNetworkProfile();

    Q_INVOKABLE bool isToolAvailable(const QString &toolId) const;
    Q_INVOKABLE bool launchTool(const QString &toolId);
    Q_INVOKABLE bool launchYastModule(const QString &moduleName);
    Q_INVOKABLE bool launchCustomScript(const QString &scriptName);

    Q_INVOKABLE void runCommand(const QString &commandLine, const QString &title);
    Q_INVOKABLE void clearDiagnostic();
    Q_INVOKABLE void clearMessage();
    Q_INVOKABLE void copyToClipboard(const QString &text);

    Q_INVOKABLE void initialize();
    Q_INVOKABLE void reloadCustomActions();
    Q_INVOKABLE bool resetCustomActionsToDefault();
    Q_INVOKABLE bool saveCustomAction(const QString &id, const QString &name,
                                      const QString &script, bool confirmBeforeRun,
                                      const QString &icon = QStringLiteral("utilities-terminal"));
    Q_INVOKABLE bool removeCustomAction(const QString &id);
    Q_INVOKABLE bool runCustomAction(const QString &id);
    Q_INVOKABLE void clearActionOutput();

    Q_INVOKABLE void cleanTrash(const QString &scope);
    Q_INVOKABLE void cleanJournal(int keepMb = 16);
    Q_INVOKABLE void cleanFlatpakUnused();
    Q_INVOKABLE void cleanZypperCache();
    Q_INVOKABLE void cleanThumbnailCache();
    Q_INVOKABLE void rebuildDesktopCache();

    Q_INVOKABLE void rebootToFirmware();
    Q_INVOKABLE void rebootSystem();

    Q_INVOKABLE QString bashPromptStatus() const;
    Q_INVOKABLE bool applyBashPromptPreset(const QString &presetId);

    Q_INVOKABLE void cancelCurrentOperation();

signals:
    void resourcesChanged();
    void powerProfileChanged();
    void stateChanged();
    void diagnosticChanged();
    void customActionsChanged();
    void actionStateChanged();
    void networkStatusChanged();
    void networkPresetsChanged();
    void wifiChanged();
    void topProcessesChanged();
    void promptStatusChanged();
    void micStatusChanged();
    void privacyStatusChanged();

private:
    QProcess *startProcess(const QString &program, const QStringList &arguments,
                           const QString &operationName, bool cancellable = true,
                           int timeoutMs = 60000, const QString &workingDir = QString());
    void terminateProcessGroup(QProcess *proc, bool force = false);
    void handleProcessFinished(QProcess *proc, const QString &operation, int exitCode, const QByteArray &output);

    void setBusy(bool busy);
    void setMessage(const QString &msg);

    QString customActionsFilePath() const;
    bool persistCustomActions();
    int customActionIndex(const QString &id) const;

    QString networkProfilesFilePath() const;
    void loadNetworkProfiles();
    bool persistNetworkProfiles();

    // Resource state
    quint64 m_prevCpuTotal = 0;
    quint64 m_prevCpuIdle = 0;
    int m_cpuUsagePercent = 0;
    qint64 m_memoryUsedMiB = 0;
    qint64 m_memoryTotalMiB = 0;
    double m_cpuTemperatureC = 0.0;
    qint64 m_diskRootTotalGiB = 0;
    qint64 m_diskRootAvailableGiB = 0;
    qint64 m_diskHomeTotalGiB = 0;
    qint64 m_diskHomeAvailableGiB = 0;

    QString m_powerProfile = QStringLiteral("standard");
    bool m_busy = false;
    QString m_lastMessage;
    QString m_diagnosticTitle;
    QString m_diagnosticOutput;

    // Custom actions
    QVariantList m_customActions;
    QString m_actionOutput;
    QString m_actionError;
    bool m_actionRunning = false;
    bool m_customActionsLoaded = false;

    // Network & DNS state
    bool m_networkConnected = false;
    QString m_networkActiveConnection;
    QString m_networkInterface;
    QString m_networkIpAddress;
    QString m_networkGateway;
    QString m_networkDns;

    QVariantList m_ipPresets;
    QVariantList m_dnsPresets;
    int m_selectedIpPreset = 0;
    int m_selectedDnsPreset = 0;
    QString m_httpsAddress;

    bool m_wifiEnabled = false;
    bool m_hasWifiHardware = true;
    bool m_wifiHardwareBlocked = false;
    QString m_wifiStatusString = QStringLiteral("unknown");
    quint64 m_wifiRequestId = 0;
    quint64 m_networkRequestId = 0;

    bool m_micMuted = true;
    bool m_privacyActive = false;

    QVariantList m_topMemoryProcesses;
    mutable QMutex m_busyMutex;

    QPointer<QProcess> m_activeProcess;
    QPointer<QProcess> m_topProcessesProc;
    QPointer<QProcess> m_micProc;
};
