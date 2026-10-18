#pragma once

#include <QElapsedTimer>
#include <QEvent>
#include <QObject>
#include <QProcess>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>
#include <QVector>

#include <cstdint>
#include <future>

#include "runtime/task_scheduler.h"
#include "runtime/app_session_supervisor.h"
#include "runtime/runtime_snapshot.h"

class SystemBackend final : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString version READ version CONSTANT)
    Q_PROPERTY(QString hostname READ hostname NOTIFY systemInfoChanged)
    Q_PROPERTY(QString kernel READ kernel NOTIFY systemInfoChanged)
    Q_PROPERTY(QString diskUsed READ diskUsed NOTIFY storageChanged)
    Q_PROPERTY(QString diskTotal READ diskTotal NOTIFY storageChanged)
    Q_PROPERTY(int diskPercent READ diskPercent NOTIFY storageChanged)
    Q_PROPERTY(bool nvmeAvailable READ nvmeAvailable NOTIFY storageChanged)
    Q_PROPERTY(bool nvmeMounted READ nvmeMounted NOTIFY storageChanged)
    Q_PROPERTY(QString nvmeModel READ nvmeModel NOTIFY storageChanged)
    Q_PROPERTY(QString nvmeMountPoint READ nvmeMountPoint NOTIFY storageChanged)
    Q_PROPERTY(QString nvmeUsed READ nvmeUsed NOTIFY storageChanged)
    Q_PROPERTY(QString nvmeTotal READ nvmeTotal NOTIFY storageChanged)
    Q_PROPERTY(int nvmePercent READ nvmePercent NOTIFY storageChanged)
    Q_PROPERTY(QVariantList fileEntries READ fileEntries NOTIFY filesChanged)
    Q_PROPERTY(QString filePath READ filePath NOTIFY filesChanged)
    Q_PROPERTY(bool filesLoading READ filesLoading NOTIFY filesChanged)
    Q_PROPERTY(QString filesError READ filesError NOTIFY filesChanged)
    Q_PROPERTY(QString previewPath READ previewPath NOTIFY previewChanged)
    Q_PROPERTY(QString previewText READ previewText NOTIFY previewChanged)
    Q_PROPERTY(QString previewError READ previewError NOTIFY previewChanged)
    Q_PROPERTY(bool previewLoading READ previewLoading NOTIFY previewChanged)
    Q_PROPERTY(QVariantList favoriteLocations READ favoriteLocations NOTIFY favoritesChanged)
    Q_PROPERTY(bool fileOperationRunning READ fileOperationRunning NOTIFY fileOperationChanged)
    Q_PROPERTY(QString fileOperationText READ fileOperationText NOTIFY fileOperationChanged)
    Q_PROPERTY(QString wifiName READ wifiName NOTIFY wifiChanged)
    Q_PROPERTY(bool wifiConnected READ wifiConnected NOTIFY wifiChanged)
    Q_PROPERTY(int wifiSignal READ wifiSignal NOTIFY wifiChanged)
    Q_PROPERTY(QString wifiIpv4 READ wifiIpv4 NOTIFY wifiChanged)
    Q_PROPERTY(QString wifiGateway READ wifiGateway NOTIFY wifiChanged)
    Q_PROPERTY(QString wifiMac READ wifiMac NOTIFY wifiChanged)
    Q_PROPERTY(QString wifiDevice READ wifiDevice NOTIFY wifiChanged)
    Q_PROPERTY(bool wifiScanning READ wifiScanning NOTIFY wifiChanged)
    Q_PROPERTY(bool wifiOperating READ wifiOperating NOTIFY wifiChanged)
    Q_PROPERTY(QString wifiOperation READ wifiOperation NOTIFY wifiChanged)
    Q_PROPERTY(QString wifiOperationSsid READ wifiOperationSsid NOTIFY wifiChanged)
    Q_PROPERTY(QString wifiScanError READ wifiScanError NOTIFY wifiChanged)
    Q_PROPERTY(QVariantList wifiNetworks READ wifiNetworks NOTIFY wifiChanged)
    Q_PROPERTY(QVariantList ethernetPorts READ ethernetPorts NOTIFY ethernetChanged)
    Q_PROPERTY(bool ethernetOperating READ ethernetOperating NOTIFY ethernetChanged)
    Q_PROPERTY(QString ethernetOperationInterface READ ethernetOperationInterface NOTIFY ethernetChanged)
    Q_PROPERTY(QVariantMap powerManagement READ powerManagement NOTIFY powerChanged)
    Q_PROPERTY(bool batteryAvailable READ batteryAvailable NOTIFY powerChanged)
    Q_PROPERTY(int batteryPercent READ batteryPercent NOTIFY powerChanged)
    Q_PROPERTY(QString batteryStatus READ batteryStatus NOTIFY powerChanged)
    Q_PROPERTY(bool batteryCharging READ batteryCharging NOTIFY powerChanged)
    Q_PROPERTY(bool chargerAvailable READ chargerAvailable NOTIFY powerChanged)
    Q_PROPERTY(bool externalPowerPresent READ externalPowerPresent NOTIFY powerChanged)
    Q_PROPERTY(double batteryTemperatureC READ batteryTemperatureC NOTIFY powerChanged)
    Q_PROPERTY(QString chargeTemperatureZone READ chargeTemperatureZone NOTIFY powerChanged)
    Q_PROPERTY(int batteryVoltageMv READ batteryVoltageMv NOTIFY powerChanged)
    Q_PROPERTY(int batteryCurrentMa READ batteryCurrentMa NOTIFY powerChanged)
    Q_PROPERTY(QString batteryHealth READ batteryHealth NOTIFY powerChanged)
    Q_PROPERTY(double batteryPowerW READ batteryPowerW NOTIFY powerChanged)
    Q_PROPERTY(int batteryRawVoltageMv READ batteryRawVoltageMv NOTIFY powerChanged)
    Q_PROPERTY(int batteryRawCurrentMa READ batteryRawCurrentMa NOTIFY powerChanged)
    Q_PROPERTY(int batteryRemainingMah READ batteryRemainingMah NOTIFY powerChanged)
    Q_PROPERTY(int batteryFullChargeMah READ batteryFullChargeMah NOTIFY powerChanged)
    Q_PROPERTY(int batteryDesignCapacityMah READ batteryDesignCapacityMah NOTIFY powerChanged)
    Q_PROPERTY(bool gaugeCommunication READ gaugeCommunication NOTIFY powerChanged)
    Q_PROPERTY(QString gaugeError READ gaugeError NOTIFY powerChanged)
    Q_PROPERTY(QString batteryCalibrationStatus READ batteryCalibrationStatus NOTIFY powerChanged)
    Q_PROPERTY(QString batteryCalibrationSummary READ batteryCalibrationSummary NOTIFY powerChanged)
    Q_PROPERTY(int chargerInputLimitMa READ chargerInputLimitMa NOTIFY powerChanged)
    Q_PROPERTY(int chargerFastCurrentMa READ chargerFastCurrentMa NOTIFY powerChanged)
    Q_PROPERTY(int batteryCapacityLearningStep READ batteryCapacityLearningStep NOTIFY powerChanged)
    Q_PROPERTY(QString batteryCapacityLearningStatus READ batteryCapacityLearningStatus NOTIFY powerChanged)
    Q_PROPERTY(bool batteryCalibrationRollbackAvailable READ batteryCalibrationRollbackAvailable NOTIFY powerChanged)
    Q_PROPERTY(QString boardProfile READ boardProfile CONSTANT)
    Q_PROPERTY(QVariantMap hardwareCapabilities READ hardwareCapabilities CONSTANT)
    Q_PROPERTY(int volumePercent READ volumePercent NOTIFY audioChanged)
    Q_PROPERTY(bool audioAvailable READ audioAvailable NOTIFY audioChanged)
    Q_PROPERTY(int displayBrightnessPercent READ displayBrightnessPercent NOTIFY displayChanged)
    Q_PROPERTY(bool brightnessAvailable READ brightnessAvailable NOTIFY displayChanged)
    Q_PROPERTY(bool screenSleeping READ isScreenSleeping NOTIFY screenSleepingChanged)
    Q_PROPERTY(int sleepTimeoutSeconds READ sleepTimeoutSeconds WRITE setSleepTimeoutSeconds NOTIFY sleepTimeoutChanged)
    Q_PROPERTY(int sleepTimeoutIndex READ sleepTimeoutIndex WRITE setSleepTimeoutIndex NOTIFY sleepTimeoutChanged)
    Q_PROPERTY(int sleepPowerLevel READ sleepPowerLevel WRITE setSleepPowerLevel NOTIFY sleepPowerLevelChanged)
    Q_PROPERTY(QStringList keepScreenOnApps READ keepScreenOnApps NOTIFY keepScreenOnAppsChanged)
    Q_PROPERTY(bool wakeLockActive READ isWakeLockActive WRITE setWakeLockActive NOTIFY wakeLockActiveChanged)
    Q_PROPERTY(int cpuTotal READ cpuTotal NOTIFY performanceChanged)
    Q_PROPERTY(QVariantList cpuUsage READ cpuUsage NOTIFY performanceChanged)
    Q_PROPERTY(QVariantList cpuFrequencies READ cpuFrequencies NOTIFY performanceChanged)
    Q_PROPERTY(int gpuUsage READ gpuUsage NOTIFY performanceChanged)
    Q_PROPERTY(double cpuTemperatureC READ cpuTemperatureC NOTIFY performanceChanged)
    Q_PROPERTY(int cpuFrequencyMhz READ cpuFrequencyMhz NOTIFY performanceChanged)
    Q_PROPERTY(int cpuMaxFrequencyMhz READ cpuMaxFrequencyMhz NOTIFY performanceChanged)
    Q_PROPERTY(int gpuFrequencyMhz READ gpuFrequencyMhz NOTIFY performanceChanged)
    Q_PROPERTY(QString loadAverage READ loadAverage NOTIFY performanceChanged)
    Q_PROPERTY(QString uptime READ uptime NOTIFY performanceChanged)
    Q_PROPERTY(int processCount READ processCount NOTIFY performanceChanged)
    Q_PROPERTY(int memoryPercent READ memoryPercent NOTIFY performanceChanged)
    Q_PROPERTY(QString memoryUsed READ memoryUsed NOTIFY performanceChanged)
    Q_PROPERTY(QString memoryAvailable READ memoryAvailable NOTIFY performanceChanged)
    Q_PROPERTY(QString memoryTotal READ memoryTotal NOTIFY performanceChanged)
    Q_PROPERTY(QVariantList performanceHistory READ performanceHistory NOTIFY performanceChanged)
    Q_PROPERTY(int displayRotation READ displayRotation CONSTANT)
    Q_PROPERTY(int schedulerPendingTasks READ schedulerPendingTasks NOTIFY schedulerChanged)
    Q_PROPERTY(int schedulerRunningTasks READ schedulerRunningTasks NOTIFY schedulerChanged)
    Q_PROPERTY(int schedulerSubmittedTasks READ schedulerSubmittedTasks NOTIFY schedulerChanged)
    Q_PROPERTY(int schedulerRejectedTasks READ schedulerRejectedTasks NOTIFY schedulerChanged)
    Q_PROPERTY(int schedulerPeakPendingTasks READ schedulerPeakPendingTasks NOTIFY schedulerChanged)
    Q_PROPERTY(int schedulerWorkerCount READ schedulerWorkerCount CONSTANT)
    Q_PROPERTY(QString foregroundApp READ foregroundApp NOTIFY sessionChanged)
    Q_PROPERTY(bool foregroundAppActive READ foregroundAppActive NOTIFY sessionChanged)

public:
    explicit SystemBackend(QObject *parent = nullptr);
    ~SystemBackend() override;

    QString version() const;
    QString hostname() const;
    QString kernel() const;
    QString diskUsed() const;
    QString diskTotal() const;
    int diskPercent() const;
    bool nvmeAvailable() const;
    bool nvmeMounted() const;
    QString nvmeModel() const;
    QString nvmeMountPoint() const;
    QString nvmeUsed() const;
    QString nvmeTotal() const;
    int nvmePercent() const;
    QVariantList fileEntries() const;
    QString filePath() const;
    bool filesLoading() const;
    QString filesError() const;
    QString previewPath() const;
    QString previewText() const;
    QString previewError() const;
    bool previewLoading() const;
    QVariantList favoriteLocations() const;
    bool fileOperationRunning() const;
    QString fileOperationText() const;
    QString wifiName() const;
    bool wifiConnected() const;
    int wifiSignal() const;
    QString wifiIpv4() const;
    QString wifiGateway() const;
    QString wifiMac() const;
    QString wifiDevice() const;
    bool wifiScanning() const;
    bool wifiOperating() const;
    QString wifiOperation() const;
    QString wifiOperationSsid() const;
    QString wifiScanError() const;
    QVariantList wifiNetworks() const;
    QVariantList ethernetPorts() const;
    bool ethernetOperating() const;
    QString ethernetOperationInterface() const;
    QVariantMap powerManagement() const { return m_powerManagement; }
    bool batteryAvailable() const;
    int batteryPercent() const;
    QString batteryStatus() const;
    bool batteryCharging() const;
    bool chargerAvailable() const;
    bool externalPowerPresent() const;
    double batteryTemperatureC() const;
    QString chargeTemperatureZone() const;
    int batteryVoltageMv() const;
    int batteryCurrentMa() const;
    QString batteryHealth() const;
    double batteryPowerW() const;
    int batteryRawVoltageMv() const;
    int batteryRawCurrentMa() const;
    int batteryRemainingMah() const;
    int batteryFullChargeMah() const;
    int batteryDesignCapacityMah() const;
    bool gaugeCommunication() const;
    QString gaugeError() const;
    QString batteryCalibrationStatus() const;
    QString batteryCalibrationSummary() const;
    QString boardProfile() const;
    QVariantMap hardwareCapabilities() const;
    int volumePercent() const;
    bool audioAvailable() const;
    int displayBrightnessPercent() const;
    bool brightnessAvailable() const;
    int cpuTotal() const;
    QVariantList cpuUsage() const;
    QVariantList cpuFrequencies() const;
    int gpuUsage() const;
    double cpuTemperatureC() const;
    int cpuFrequencyMhz() const;
    int cpuMaxFrequencyMhz() const;
    int gpuFrequencyMhz() const;
    QString loadAverage() const;
    QString uptime() const;
    int processCount() const;
    int memoryPercent() const;
    QString memoryUsed() const;
    QString memoryAvailable() const;
    QString memoryTotal() const;
    QVariantList performanceHistory() const;
    int displayRotation() const;
    int schedulerPendingTasks() const;
    int schedulerRunningTasks() const;
    int schedulerSubmittedTasks() const;
    int schedulerRejectedTasks() const;
    int schedulerPeakPendingTasks() const;
    int schedulerWorkerCount() const;
    QString foregroundApp() const;
    bool foregroundAppActive() const;
    Q_INVOKABLE bool beginForegroundApp(const QString &appId);
    Q_INVOKABLE bool endForegroundApp(const QString &appId = QString());
    bool isScreenSleeping() const;
    int sleepTimeoutSeconds() const;
    int sleepTimeoutIndex() const;
    int sleepPowerLevel() const;
    QStringList keepScreenOnApps() const;
    bool isWakeLockActive() const;
    int chargerInputLimitMa() const { return m_chargerInputLimitMa; }
    int chargerFastCurrentMa() const { return m_chargerFastCurrentMa; }
    int batteryCapacityLearningStep() const { return m_batteryCapacityLearningStep; }
    QString batteryCapacityLearningStatus() const { return m_batteryCapacityLearningStatus; }
    bool batteryCalibrationRollbackAvailable() const { return m_batteryCalibrationRollbackAvailable; }

    Q_INVOKABLE void refresh();
    Q_INVOKABLE void refreshStatus();
    Q_INVOKABLE void refreshPerformance();
    Q_INVOKABLE void setActiveScope(const QString &scope);
    Q_INVOKABLE void boostInteractivePerformance(int tier = 1, int durationMs = 0);
    Q_INVOKABLE void releaseInteractivePerformance();
    Q_INVOKABLE qint64 idleMs() const;
    Q_INVOKABLE void scanWifi();
    Q_INVOKABLE void connectWifi(const QString &ssid, const QString &password);
    Q_INVOKABLE void forgetWifi(const QString &ssid);
    Q_INVOKABLE void configureEthernet(const QString &interfaceName, const QString &connectionName,
                                       const QString &method, const QString &address, int prefix,
                                       const QString &gateway, const QString &dns);
    Q_INVOKABLE void setEthernetConnected(const QString &interfaceName, bool connected);
    Q_INVOKABLE void setVolume(int percent);
    Q_INVOKABLE void playVolumeFeedback();
    Q_INVOKABLE void launchMindustry();
    Q_INVOKABLE void launchPvZ();
    Q_INVOKABLE void setDisplayBrightness(int percent);
    Q_INVOKABLE void setSleepTimeoutSeconds(int seconds);
    Q_INVOKABLE void setSleepTimeoutIndex(int index);
    Q_INVOKABLE void setSleepPowerLevel(int level);
    Q_INVOKABLE void setAppKeepScreenOn(const QString &appId, bool enabled);
    Q_INVOKABLE bool isAppKeepScreenOn(const QString &appId) const;
    Q_INVOKABLE void setWakeLockActive(bool active);
    Q_INVOKABLE void setScreenSleeping(bool sleeping);
    Q_INVOKABLE void wakeScreen();
    Q_INVOKABLE bool calibrateBattery(int referenceVoltageMv, int referenceCurrentMa,
                                      int designCapacityMah = -1, bool stable = true);
    Q_INVOKABLE bool rollbackBatteryCalibration();
    Q_INVOKABLE void startCapacityLearning();
    Q_INVOKABLE void advanceCapacityLearning();
    Q_INVOKABLE void cancelCapacityLearning();
    Q_INVOKABLE void clearBatteryCalibration();
    Q_INVOKABLE void browseDirectory(const QString &path);
    Q_INVOKABLE void previewDocument(const QString &path);
    Q_INVOKABLE void addFavoriteLocation(const QString &path, const QString &label);
    Q_INVOKABLE void removeFavoriteLocation(const QString &path);
    Q_INVOKABLE void transferFile(const QString &sourcePath, const QString &destinationDirectory,
                                  bool move);
    Q_INVOKABLE void saveAppData(const QString &key, const QString &data);
    Q_INVOKABLE QString loadAppData(const QString &key, const QString &defaultValue = QString()) const;

signals:
    void systemInfoChanged();
    void storageChanged();
    void filesChanged();
    void previewChanged();
    void favoritesChanged();
    void fileOperationChanged();
    void wifiChanged();
    void ethernetChanged();
    void powerChanged();
    void audioChanged();
    void displayChanged();
    void screenSleepingChanged();
    void sleepTimeoutChanged();
    void sleepPowerLevelChanged();
    void keepScreenOnAppsChanged();
    void wakeLockActiveChanged();
    void performanceChanged();
    void schedulerChanged();
    void sessionChanged();
    void inputActivity();
    void operationMessage(const QString &message, bool success);

protected:
    bool eventFilter(QObject *watched, QEvent *event) override;

private:
    void refreshSystem();
    void refreshStorage();
    void applyStorageSnapshot(const QVariantMap &snapshot);
    void applyStatusSnapshot(const QVariantMap &snapshot);
    QVariantMap collectPerformanceSnapshot();
    void applyPerformanceSnapshot(const QVariantMap &snapshot, const QString &scope);
    void activateInteractiveCpuBoost(int tier = 1, int durationMs = 0);
    void releaseInteractiveCpuBoost();

    QString m_hostname;
    QString m_kernel;
    QString m_diskUsed;
    QString m_diskTotal;
    int m_diskPercent = 0;
    bool m_nvmeAvailable = false;
    bool m_nvmeMounted = false;
    QString m_nvmeModel;
    QString m_nvmeMountPoint;
    QString m_nvmeUsed;
    QString m_nvmeTotal;
    int m_nvmePercent = 0;
    QVariantList m_fileEntries;
    QString m_filePath;
    QString m_filesError;
    bool m_filesLoading = false;
    QString m_previewPath;
    QString m_previewText;
    QString m_previewError;
    bool m_previewLoading = false;
    QVariantList m_favoriteLocations;
    bool m_fileOperationRunning = false;
    QString m_fileOperationText;
    QString m_wifiName;
    int m_wifiSignal = 0;
    QString m_wifiIpv4;
    QString m_wifiGateway;
    QString m_wifiMac;
    QString m_wifiDevice;
    QString m_wifiOperation;
    QString m_wifiOperationSsid;
    QString m_wifiScanError;
    int m_wifiEmptyPollCount = 0;
    QVariantList m_wifiNetworks;
    QVariantList m_pendingWifiNetworks;
    QString m_pendingWifiScanError;
    QVariantList m_ethernetPorts;
    QString m_ethernetOperationInterface;
    QVariantMap m_powerManagement;
    QString m_lastPowerEvent;
    bool m_batteryAvailable = false;
    int m_batteryPercent = -1;
    QString m_batteryStatus;
    bool m_batteryCharging = false;
    bool m_chargerAvailable = false;
    bool m_externalPowerPresent = false;
    double m_batteryTemperatureC = -273.15;
    QString m_chargeTemperatureZone;
    int m_batteryVoltageMv = -1;
    int m_batteryCurrentMa = 0;
    int m_batteryRawVoltageMv = -1;
    int m_batteryRawCurrentMa = 0;
    int m_batteryRemainingMah = -1;
    int m_batteryFullChargeMah = -1;
    int m_batteryDesignCapacityMah = -1;
    bool m_gaugeCommunication = false;
    QString m_gaugeError;
    QString m_batteryCalibrationStatus = QStringLiteral("未校准");
    QString m_batteryCalibrationSummary;
    QString m_batteryHealth;
    QString m_boardProfile;
    QVariantMap m_hardwareCapabilities;
    int m_volumePercent = -1;
    bool m_audioAvailable = false;
    int m_displayBrightnessPercent = -1;
    bool m_brightnessAvailable = false;
    QString m_backlightPath;
    int m_brightnessMax = 0;
    bool m_statusRefreshPending = false;
    QString m_activeScope = QStringLiteral("home");
    QElapsedTimer m_idleElapsedTimer;
    int m_cpuTotal = -1;
    QVariantList m_cpuUsage;
    QVariantList m_cpuFrequencies;
    int m_gpuUsage = -1;
    double m_cpuTemperatureC = -273.15;
    int m_cpuFrequencyMhz = -1;
    int m_cpuMaxFrequencyMhz = -1;
    int m_gpuFrequencyMhz = -1;
    QString m_loadAverage;
    QString m_uptime;
    int m_processCount = -1;
    int m_memoryPercent = -1;
    qint64 m_memoryUsedBytes = 0;
    qint64 m_memoryAvailableBytes = 0;
    qint64 m_memoryTotalBytes = 0;
    QVector<quint64> m_cpuPrevIdle;
    QVector<quint64> m_cpuPrevTotal;
    QVariantList m_performanceHistory;
    bool m_cpuHavePrev = false;
    bool m_statusTaskRunning = false;
    bool m_storageTaskRunning = false;
    bool m_storageRefreshPending = false;
    QVariantMap m_pendingStorageSnapshot;
    bool m_performanceTaskRunning = false;
    bool m_performanceRefreshPending = false;
    QVariantMap m_pendingPerformanceSnapshot;
    bool m_wifiScanRunning = false;
    bool m_wifiOperationRunning = false;
    bool m_ethernetOperationRunning = false;
    bool m_directoryTaskRunning = false;
    QString m_pendingDirectoryPath;
    bool m_previewTaskRunning = false;
    QString m_pendingPreviewPath;
    meow::TaskScheduler m_runtimeScheduler{0, 256};
    meow::AppSessionSupervisor m_sessionSupervisor;
    meow::RuntimeSnapshotStore m_runtimeSnapshotStore;
    std::uint64_t m_runtimeSequence = 0;
    std::future<void> m_mindustryLaunchFuture;
    QTimer m_mindustryLaunchPollTimer;
    QProcess m_pvzLaunchProcess;
    int m_pendingVolumePercent = 65;
    QTimer m_volumeSetTimer;
    QProcess m_volumeSetProcess;
    QProcess m_feedbackProcess;
    int m_pendingBrightnessPercent = 30;
    QTimer m_brightnessSetTimer;
    bool m_screenSleeping = false;
    int m_sleepTimeoutSeconds = 60;
    int m_sleepPowerLevel = 1;
    QStringList m_keepScreenOnApps;
    bool m_wakeLockActive = false;
    int m_chargerInputLimitMa = -1;
    int m_chargerFastCurrentMa = -1;
    int m_batteryCapacityLearningStep = 0;
    QString m_batteryCapacityLearningStatus;
    bool m_batteryCalibrationRollbackAvailable = false;
    int m_brightnessBeforeSleep = 50;
    QString m_savedScopeBeforeSleep;
};

