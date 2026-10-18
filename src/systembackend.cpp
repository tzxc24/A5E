#include "systembackend.h"
#include "power_snapshot_reader.h"

#include <QAbstractSocket>
#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QNetworkAddressEntry>
#include <QNetworkInterface>
#include <QRegularExpression>
#include <QSaveFile>
#include <QSet>
#include <QStorageInfo>
#include <QSettings>
#include <QSysInfo>
#include <QUrl>
#include <QtMath>
#include <cstdio>
#include <chrono>
#include <cstdint>
#include <stdexcept>
#include <utility>

#ifdef Q_OS_LINUX
#include <fcntl.h>
#include <sys/ioctl.h>
#include <unistd.h>
#endif

#include "version.h"

namespace {

const QString kCpuFreqSleepStatePath = QStringLiteral("/var/lib/meow-os/cpufreq-sleep.state");
const QString kCpuFreqBoostStatePath = QStringLiteral("/var/lib/meow-os/cpufreq-boost.state");

QString formatBytes(qint64 bytes);

QString readTextFile(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) return QString();
    return QString::fromLocal8Bit(file.readAll()).trimmed();
}

bool saveCpuFreqState(const QString &path, const QVector<QPair<QString, QByteArray>> &limits)
{
    QSaveFile state(path);
    if (!state.open(QIODevice::WriteOnly | QIODevice::Text)) return false;
    for (const auto &limit : limits) {
        state.write(limit.first.toUtf8());
        state.write("\t");
        state.write(limit.second);
        state.write("\n");
    }
    return state.commit();
}

struct ProcessResult {
    QString output;
    int exitCode = -1;
    bool started = false;
    bool timedOut = false;

    bool ok() const { return started && !timedOut && exitCode == 0; }
};

ProcessResult runProcessDetailed(const QString &program, const QStringList &arguments, int timeoutMs = 5000)
{
    ProcessResult result;
    QProcess process;
    process.setProcessChannelMode(QProcess::MergedChannels);
    process.start(program, arguments);
    result.started = process.waitForStarted(qMin(timeoutMs, 3000));
    if (!result.started) return result;
    if (!process.waitForFinished(timeoutMs)) {
        result.timedOut = true;
        process.kill();
        process.waitForFinished(500);
    }
    result.output = QString::fromLocal8Bit(process.readAll()).trimmed();
    result.exitCode = process.exitCode();
    return result;
}

QString runProcess(const QString &program, const QStringList &arguments, int timeoutMs = 5000)
{
    const ProcessResult result = runProcessDetailed(program, arguments, timeoutMs);
    return result.started && !result.timedOut ? result.output : QString();
}

QVariantMap detectHardwareCapabilities(QString *profile)
{
    const QString model = readTextFile(QStringLiteral("/proc/device-tree/model"));
    const QString compatible = readTextFile(QStringLiteral("/proc/device-tree/compatible"));
    QString selected = QStringLiteral("Generic Linux");
    if (model.contains(QStringLiteral("A5E"), Qt::CaseInsensitive)
            || compatible.contains(QStringLiteral("cubie-a5e"), Qt::CaseInsensitive)) {
        selected = QStringLiteral("Radxa Cubie A5E");
    } else if (model.contains(QStringLiteral("A733"), Qt::CaseInsensitive)
               || compatible.contains(QStringLiteral("a733"), Qt::CaseInsensitive)
               || qEnvironmentVariableIsSet("MEOW_A733_PROFILE")) {
        selected = QStringLiteral("Allwinner A733 (通用)");
    } else if (model.contains(QStringLiteral("RK35"), Qt::CaseInsensitive)
               || compatible.contains(QStringLiteral("rockchip"), Qt::CaseInsensitive)
               || qEnvironmentVariableIsSet("MEOW_RK_PROFILE")) {
        selected = QStringLiteral("Rockchip RK35xx (通用)");
    }
    if (profile) *profile = selected;
    QVariantMap caps;
    caps.insert(QStringLiteral("display"), true);
    caps.insert(QStringLiteral("touch"), QFileInfo::exists(QStringLiteral("/dev/input/meow-touch")));
    caps.insert(QStringLiteral("power"), QFileInfo::exists(QStringLiteral("/sys/class/power_supply")));
    caps.insert(QStringLiteral("audio"), QFileInfo::exists(QStringLiteral("/proc/asound/cards")));
    caps.insert(QStringLiteral("wifi"), QFileInfo::exists(QStringLiteral("/sys/class/net/wlan0")));
    caps.insert(QStringLiteral("ethernet"), QFileInfo::exists(QStringLiteral("/sys/class/net/eth0")));
    caps.insert(QStringLiteral("nvme"), QFileInfo::exists(QStringLiteral("/sys/class/nvme")));
    caps.insert(QStringLiteral("usb3"), QFileInfo::exists(QStringLiteral("/sys/bus/usb/devices")));
    caps.insert(QStringLiteral("pcie"), QFileInfo::exists(QStringLiteral("/sys/bus/pci")));
    caps.insert(QStringLiteral("profileSource"), model.isEmpty() ? QStringLiteral("fallback") : model);
    return caps;
}

bool readInteger(const QString &path, qint64 *value)
{
    bool ok = false;
    const qint64 parsed = readTextFile(path).toLongLong(&ok);
    if (ok) *value = parsed;
    return ok;
}

QVariantMap collectStorageSnapshot()
{
    QVariantMap result;
    QStorageInfo storage(QStringLiteral("/"));
    storage.refresh();
    if (!storage.isValid() || !storage.isReady() || storage.bytesTotal() <= 0) return result;
    const qint64 used = storage.bytesTotal() - storage.bytesAvailable();
    result.insert(QStringLiteral("diskUsed"), formatBytes(used));
    result.insert(QStringLiteral("diskTotal"), formatBytes(storage.bytesTotal()));
    result.insert(QStringLiteral("diskPercent"), qBound(0, static_cast<int>(100.0 * used / storage.bytesTotal()), 100));

    bool nvmeAvailable = false;
    bool nvmeMounted = false;
    QString nvmeModel;
    QString nvmeMountPoint;
    QString nvmeUsed;
    QString nvmeTotal;
    int nvmePercent = 0;
    QStorageInfo dataStorage(QStringLiteral("/data"));
    if (dataStorage.isValid() && dataStorage.isReady() && dataStorage.bytesTotal() > 0) {
        nvmeMounted = true;
        nvmeMountPoint = QStringLiteral("/data");
        nvmeUsed = formatBytes(dataStorage.bytesTotal() - dataStorage.bytesAvailable());
        nvmeTotal = formatBytes(dataStorage.bytesTotal());
        nvmePercent = qBound(0, static_cast<int>(100.0 * (dataStorage.bytesTotal() - dataStorage.bytesAvailable()) / dataStorage.bytesTotal()), 100);
    }
    QDir sysBlock(QStringLiteral("/sys/block"));
    sysBlock.setNameFilters({QStringLiteral("nvme*n*")});
    const QStringList nvmeDevices = sysBlock.entryList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name);
    if (!nvmeDevices.isEmpty()) {
        const QString deviceName = nvmeDevices.first();
        const QString sysPath = sysBlock.absoluteFilePath(deviceName);
        nvmeAvailable = true;
        nvmeModel = readTextFile(sysPath + QStringLiteral("/device/model"));
        qint64 sectors = 0;
        if (readInteger(sysPath + QStringLiteral("/size"), &sectors) && sectors > 0)
            nvmeTotal = formatBytes(sectors * 512);
        const QString devicePrefix = QStringLiteral("/dev/") + deviceName;
        for (QStorageInfo volume : QStorageInfo::mountedVolumes()) {
            if (!QString::fromLocal8Bit(volume.device()).startsWith(devicePrefix)) continue;
            volume.refresh();
            if (!volume.isValid() || !volume.isReady() || volume.bytesTotal() <= 0) continue;
            const qint64 nvmeBytesUsed = volume.bytesTotal() - volume.bytesAvailable();
            nvmeMounted = true;
            nvmeMountPoint = volume.rootPath();
            nvmeUsed = formatBytes(nvmeBytesUsed);
            nvmeTotal = formatBytes(volume.bytesTotal());
            nvmePercent = qBound(0, static_cast<int>(100.0 * nvmeBytesUsed / volume.bytesTotal()), 100);
            break;
        }
    }
    result.insert(QStringLiteral("nvmeAvailable"), nvmeAvailable);
    result.insert(QStringLiteral("nvmeMounted"), nvmeMounted);
    result.insert(QStringLiteral("nvmeModel"), nvmeModel);
    result.insert(QStringLiteral("nvmeMountPoint"), nvmeMountPoint);
    result.insert(QStringLiteral("nvmeUsed"), nvmeUsed);
    result.insert(QStringLiteral("nvmeTotal"), nvmeTotal);
    result.insert(QStringLiteral("nvmePercent"), nvmePercent);
    return result;
}

double normalizeTemperature(qint64 raw)
{
    const qint64 magnitude = qAbs(raw);
    if (magnitude >= 10000) return raw / 1000.0;
    if (magnitude >= 100) return raw / 10.0;
    return static_cast<double>(raw);
}

QString formatBytes(qint64 bytes)
{
    static const char *units[] = {"B", "KB", "MB", "GB", "TB"};
    double value = qMax<qint64>(0, bytes);
    int unit = 0;
    while (value >= 1024.0 && unit < 4) {
        value /= 1024.0;
        ++unit;
    }
    return QStringLiteral("%1 %2").arg(value, 0, 'f', unit == 0 ? 0 : 1)
            .arg(QString::fromLatin1(units[unit]));
}

QStringList splitNmcliTerseLine(const QString &line)
{
    QStringList fields;
    QString current;
    bool escaped = false;
    for (const QChar ch : line) {
        if (escaped) {
            current.append(ch);
            escaped = false;
        } else if (ch == QLatin1Char('\\')) {
            escaped = true;
        } else if (ch == QLatin1Char(':')) {
            fields.append(current);
            current.clear();
        } else {
            current.append(ch);
        }
    }
    if (escaped) current.append(QLatin1Char('\\'));
    fields.append(current);
    return fields;
}

int parseWifiSignal(const QString &value)
{
    bool ok = false;
    const int signal = value.trimmed().toInt(&ok);
    return ok ? qBound(0, signal, 100) : -1;
}

QVariantList collectEthernetPorts()
{
    QVariantList ports;
    for (const QString &name : {QStringLiteral("eth0"), QStringLiteral("eth1")}) {
        const QString base = QStringLiteral("/sys/class/net/") + name;
        if (!QFileInfo::exists(base)) continue;

        qint64 carrierValue = 0;
        const bool carrier = readInteger(base + QStringLiteral("/carrier"), &carrierValue) && carrierValue == 1;
        qint64 speedValue = -1;
        readInteger(base + QStringLiteral("/speed"), &speedValue);
        qint64 mtuValue = 0;
        readInteger(base + QStringLiteral("/mtu"), &mtuValue);

        QString ipv4;
        QString ipv6;
        QString gateway;
        QString connectionName;
        QString method = QStringLiteral("auto");
        QStringList dnsServers;
        const QNetworkInterface interface = QNetworkInterface::interfaceFromName(name);
        for (const QNetworkAddressEntry &address : interface.addressEntries()) {
            const QHostAddress ip = address.ip();
            const QString formatted = ip.toString() + QLatin1Char('/') + QString::number(address.prefixLength());
            if (ip.protocol() == QAbstractSocket::IPv4Protocol && ipv4.isEmpty()) ipv4 = formatted;
            else if (ip.protocol() == QAbstractSocket::IPv6Protocol && ipv6.isEmpty()
                     && !ip.isLinkLocal()) ipv6 = formatted;
        }

        const QString deviceDetails = runProcess(QStringLiteral("nmcli"),
                                                 {QStringLiteral("-t"), QStringLiteral("-e"),
                                                  QStringLiteral("yes"), QStringLiteral("-f"),
                                                  QStringLiteral("GENERAL.CONNECTION,IP4.GATEWAY"),
                                                  QStringLiteral("device"), QStringLiteral("show"), name}, 1200);
        for (const QString &line : deviceDetails.split(QRegularExpression(QStringLiteral("\\r?\\n")),
                                                       Qt::SkipEmptyParts)) {
            const int separator = line.indexOf(QLatin1Char(':'));
            if (separator <= 0) continue;
            const QString key = line.left(separator);
            const QString value = line.mid(separator + 1).trimmed();
            if (key == QStringLiteral("GENERAL.CONNECTION")) connectionName = value;
            else if (key == QStringLiteral("IP4.GATEWAY") && gateway.isEmpty()) gateway = value;
        }
        if (!connectionName.isEmpty() && connectionName != QStringLiteral("--")) {
            const QString connectionDetails = runProcess(QStringLiteral("nmcli"),
                                                         {QStringLiteral("-t"), QStringLiteral("-e"),
                                                          QStringLiteral("yes"), QStringLiteral("-f"),
                                                          QStringLiteral("ipv4.method,ipv4.dns"),
                                                          QStringLiteral("connection"), QStringLiteral("show"),
                                                          QStringLiteral("id"), connectionName}, 1200);
            for (const QString &line : connectionDetails.split(QRegularExpression(QStringLiteral("\\r?\\n")),
                                                                Qt::SkipEmptyParts)) {
                const int separator = line.indexOf(QLatin1Char(':'));
                if (separator <= 0) continue;
                const QString key = line.left(separator).toLower();
                const QString value = line.mid(separator + 1).trimmed();
                if (key == QStringLiteral("ipv4.method") && !value.isEmpty()) method = value;
                else if (key == QStringLiteral("ipv4.dns") && !value.isEmpty()) dnsServers.append(value);
            }
        }

        QVariantMap port;
        port.insert(QStringLiteral("name"), name);
        port.insert(QStringLiteral("connected"), carrier);
        port.insert(QStringLiteral("state"), readTextFile(base + QStringLiteral("/operstate")));
        port.insert(QStringLiteral("speed"), carrier && speedValue > 0 ? static_cast<int>(speedValue) : 0);
        port.insert(QStringLiteral("duplex"), carrier ? readTextFile(base + QStringLiteral("/duplex")) : QString());
        port.insert(QStringLiteral("mac"), readTextFile(base + QStringLiteral("/address")));
        port.insert(QStringLiteral("mtu"), static_cast<int>(mtuValue));
        port.insert(QStringLiteral("ipv4"), ipv4);
        port.insert(QStringLiteral("ipv6"), ipv6);
        port.insert(QStringLiteral("gateway"), gateway);
        port.insert(QStringLiteral("connection"), connectionName == QStringLiteral("--") ? QString() : connectionName);
        port.insert(QStringLiteral("method"), method);
        port.insert(QStringLiteral("dns"), dnsServers.join(QStringLiteral(", ")));
        ports.append(port);
    }
    return ports;
}

bool parseCpuLine(const QByteArray &line, QVector<quint64> *idleOut, QVector<quint64> *totalOut)
{
    // "cpu0  user nice system idle iowait irq softirq steal guest guest_nice"
    char cpuName[32] = {};
    unsigned long long values[8] = {};
    const int parsed = std::sscanf(line.constData(),
                                   "%31s %llu %llu %llu %llu %llu %llu %llu %llu",
                                   cpuName, &values[0], &values[1], &values[2], &values[3],
                                   &values[4], &values[5], &values[6], &values[7]);
    if (parsed < 5 || QByteArray(cpuName).indexOf("cpu") != 0) return false;
    const int count = parsed - 1;
    quint64 total = 0;
    for (int i = 0; i < count; ++i) total += static_cast<quint64>(values[i]);
    idleOut->append(static_cast<quint64>(values[3])
                    + (count > 4 ? static_cast<quint64>(values[4]) : 0));
    totalOut->append(total);
    return true;
}

int parseGpuBusy(const QString &text)
{
    QString value = text.trimmed();
    if (value.isEmpty()) return -1;
    if (value.endsWith(QLatin1Char('%'))) value.chop(1);
    value = value.trimmed();
    bool ok = false;
    const qint64 parsed = value.toLongLong(&ok);
    if (!ok || parsed < 0 || parsed > 100) return -1;
    return static_cast<int>(parsed);
}

QVariantMap collectStatus(const QString &scope)
{
    QVariantMap result;
    if (scope != QStringLiteral("idle")) {
        const ProcessResult wifiResult = runProcessDetailed(QStringLiteral("nmcli"),
                                                             {QStringLiteral("-t"), QStringLiteral("-e"), QStringLiteral("yes"),
                                                              QStringLiteral("-f"), QStringLiteral("ACTIVE,SSID,SIGNAL"),
                                                              QStringLiteral("device"), QStringLiteral("wifi")}, 2500);
        const QString wifi = wifiResult.output;
        QString currentWifi;
        int currentSignal = -1;
        for (const QString &line : wifi.split(QRegularExpression(QStringLiteral("\\r?\\n")), Qt::SkipEmptyParts)) {
            const QStringList fields = splitNmcliTerseLine(line);
            if (fields.size() >= 2 && (fields.at(0) == QStringLiteral("yes") || fields.at(0) == QStringLiteral("*"))) {
                currentWifi = fields.at(1);
                if (fields.size() >= 3) currentSignal = parseWifiSignal(fields.at(2));
                break;
            }
        }
        // `nmcli device wifi` can briefly report SIGNAL as `--` or 0 while
        // NetworkManager still has an active association.  Read the cached
        // scan table and match the active SSID before exposing a false 0%.
        if (!currentWifi.isEmpty() && currentSignal <= 0) {
            const ProcessResult listResult = runProcessDetailed(
                    QStringLiteral("nmcli"),
                    {QStringLiteral("-t"), QStringLiteral("-e"), QStringLiteral("yes"),
                     QStringLiteral("-f"), QStringLiteral("IN-USE,SSID,SIGNAL"),
                     QStringLiteral("device"), QStringLiteral("wifi"), QStringLiteral("list"),
                     QStringLiteral("ifname"), QStringLiteral("wlan0"),
                     QStringLiteral("--rescan"), QStringLiteral("no")}, 1500);
            for (const QString &line : listResult.output.split(QRegularExpression(QStringLiteral("\\r?\\n")), Qt::SkipEmptyParts)) {
                const QStringList fields = splitNmcliTerseLine(line);
                if (fields.size() >= 3 && fields.at(1) == currentWifi) {
                    const int cachedSignal = parseWifiSignal(fields.at(2));
                    if (cachedSignal > 0) currentSignal = cachedSignal;
                    break;
                }
            }
        }
        if (currentSignal < 0) currentSignal = 0;
        if (wifiResult.ok()) {
            result.insert(QStringLiteral("wifiName"), currentWifi);
            result.insert(QStringLiteral("wifiSignal"), currentSignal);
        }

        if (!currentWifi.isEmpty() && scope == QStringLiteral("wifi")) {
            QString wifiDevice;
            QString wifiIpv4;
            QString wifiGateway;
            QString wifiMac;
            const QString deviceStatus = runProcess(QStringLiteral("nmcli"),
                                                    {QStringLiteral("-t"), QStringLiteral("-e"), QStringLiteral("yes"),
                                                     QStringLiteral("-f"), QStringLiteral("DEVICE,TYPE,STATE"),
                                                     QStringLiteral("device"), QStringLiteral("status")}, 1500);
            for (const QString &line : deviceStatus.split(QRegularExpression(QStringLiteral("\\r?\\n")), Qt::SkipEmptyParts)) {
                const QStringList fields = splitNmcliTerseLine(line);
                if (fields.size() >= 3 && fields.at(1) == QStringLiteral("wifi")
                        && fields.at(2).startsWith(QStringLiteral("connected"))) {
                    wifiDevice = fields.at(0);
                    break;
                }
            }
            if (wifiDevice.isEmpty()) wifiDevice = QStringLiteral("wlan0");

            const QNetworkInterface interface = QNetworkInterface::interfaceFromName(wifiDevice);
            for (const QNetworkAddressEntry &address : interface.addressEntries()) {
                const QHostAddress ip = address.ip();
                if (ip.protocol() == QAbstractSocket::IPv4Protocol && wifiIpv4.isEmpty()) {
                    wifiIpv4 = ip.toString();
                    break;
                }
            }

            const QString deviceShow = runProcess(QStringLiteral("nmcli"),
                                                  {QStringLiteral("-t"), QStringLiteral("-e"), QStringLiteral("yes"),
                                                   QStringLiteral("-f"), QStringLiteral("IP4.GATEWAY,GENERAL.HWADDR"),
                                                   QStringLiteral("device"), QStringLiteral("show"), wifiDevice}, 1500);
            for (const QString &line : deviceShow.split(QRegularExpression(QStringLiteral("\\r?\\n")), Qt::SkipEmptyParts)) {
                const int sep = line.indexOf(QLatin1Char(':'));
                if (sep <= 0) continue;
                const QString key = line.left(sep);
                const QString value = line.mid(sep + 1).trimmed();
                if (key == QStringLiteral("IP4.GATEWAY") && wifiGateway.isEmpty()) wifiGateway = value;
                else if (key.endsWith(QStringLiteral("HWADDR")) && wifiMac.isEmpty()) wifiMac = value;
            }
            if (wifiMac.isEmpty()) wifiMac = readTextFile(QStringLiteral("/sys/class/net/") + wifiDevice + QStringLiteral("/address"));
            result.insert(QStringLiteral("wifiDevice"), wifiDevice);
            result.insert(QStringLiteral("wifiIpv4"), wifiIpv4);
            result.insert(QStringLiteral("wifiGateway"), wifiGateway);
            result.insert(QStringLiteral("wifiMac"), wifiMac);
        }
    }

    const QString cards = readTextFile(QStringLiteral("/proc/asound/cards"));
    const bool audioAvailable = cards.contains(QStringLiteral("Meow Speaker"), Qt::CaseInsensitive)
            || cards.contains(QStringLiteral("meow-speaker"), Qt::CaseInsensitive)
            || cards.contains(QStringLiteral("simple-card"), Qt::CaseInsensitive);
    int volumePercent = -1;
    if (audioAvailable) {
        const QRegularExpression percentExpression(QStringLiteral("\\[(\\d{1,3})%\\]"));
        for (const QString &control : {QStringLiteral("Speaker"), QStringLiteral("Meow")}) {
            const QString output = runProcess(QStringLiteral("amixer"),
                                              {QStringLiteral("-c"), QStringLiteral("Speaker"),
                                               QStringLiteral("sget"), control}, 1200);
            QRegularExpressionMatchIterator matches = percentExpression.globalMatch(output);
            while (matches.hasNext()) {
                bool ok = false;
                const int value = matches.next().captured(1).toInt(&ok);
                if (ok) volumePercent = qBound(0, value, 100);
            }
            if (volumePercent >= 0) break;
        }
    }
    result.insert(QStringLiteral("audioAvailable"), audioAvailable);
    result.insert(QStringLiteral("volumePercent"), volumePercent);

    QString backlightPath;
    int brightnessMax = 0;
    int brightnessPercent = -1;
    const QDir backlights(QStringLiteral("/sys/class/backlight"));
    for (const QString &entry : backlights.entryList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name)) {
        const QString base = backlights.absoluteFilePath(entry);
        qint64 current = 0;
        qint64 maximum = 0;
        if (readInteger(base + QStringLiteral("/actual_brightness"), &current)
                && readInteger(base + QStringLiteral("/max_brightness"), &maximum)
                && maximum > 0) {
            backlightPath = base + QStringLiteral("/brightness");
            brightnessMax = static_cast<int>(maximum);
            brightnessPercent = qBound(0, qRound(100.0 * current / maximum), 100);
            break;
        }
    }
    result.insert(QStringLiteral("backlightPath"), backlightPath);
    result.insert(QStringLiteral("brightnessMax"), brightnessMax);
    result.insert(QStringLiteral("displayBrightnessPercent"), brightnessPercent);
    result.insert(QStringLiteral("brightnessAvailable"), !backlightPath.isEmpty());

    qint64 memTotal = 0;
    qint64 memAvailable = 0;
    QFile memInfo(QStringLiteral("/proc/meminfo"));
    if (memInfo.open(QIODevice::ReadOnly | QIODevice::Text)) {
        while (true) {
            const QByteArray line = memInfo.readLine();
            if (line.isEmpty()) break;
            long long value = 0;
            if (line.startsWith("MemTotal:")
                    && std::sscanf(line.constData(), "MemTotal: %lld", &value) == 1) {
                memTotal = value;
            } else if (line.startsWith("MemAvailable:")
                       && std::sscanf(line.constData(), "MemAvailable: %lld", &value) == 1) {
                memAvailable = value;
            }
            if (memTotal > 0 && memAvailable > 0) break;
        }
    }
    memTotal *= 1024;
    memAvailable *= 1024;
    const qint64 memUsed = qMax<qint64>(0, memTotal - memAvailable);
    const int memPercent = memTotal > 0 ? qBound(0, static_cast<int>(100.0 * memUsed / memTotal), 100) : -1;
    result.insert(QStringLiteral("memoryPercent"), memPercent);
    result.insert(QStringLiteral("memoryUsedBytes"), memUsed);
    result.insert(QStringLiteral("memoryAvailableBytes"), memAvailable);
    result.insert(QStringLiteral("memoryTotalBytes"), memTotal);

    if (scope == QStringLiteral("ethernet")) {
        result.insert(QStringLiteral("ethernetPorts"), collectEthernetPorts());
    }
    // Read last so unrelated process probes cannot age the accepted snapshot.
    const QVariantMap power = PowerSnapshot::read();
    for (auto it = power.cbegin(); it != power.cend(); ++it) result.insert(it.key(), it.value());

    return result;
}

QString wifiFailureMessage(const ProcessResult &result, const QString &operation)
{
    if (result.timedOut) {
        if (operation == QStringLiteral("connect")) return QStringLiteral("Wi-Fi 连接超时");
        if (operation == QStringLiteral("forget")) return QStringLiteral("删除网络超时");
        return QStringLiteral("Wi-Fi 扫描超时");
    }
    const QString output = result.output;
    if (output.contains(QStringLiteral("not authorized"), Qt::CaseInsensitive)) {
        return operation == QStringLiteral("scan") ? QStringLiteral("没有 Wi-Fi 扫描权限")
                                                    : QStringLiteral("没有修改网络的权限");
    }
    if (output.contains(QStringLiteral("No network with SSID"), Qt::CaseInsensitive)
            || output.contains(QStringLiteral("not found"), Qt::CaseInsensitive)) {
        return QStringLiteral("未找到该网络，请重新扫描");
    }
    if (output.contains(QStringLiteral("Secrets were required"), Qt::CaseInsensitive)
            || output.contains(QStringLiteral("password"), Qt::CaseInsensitive)) {
        return QStringLiteral("密码错误或认证失败");
    }
    if (output.contains(QStringLiteral("unavailable"), Qt::CaseInsensitive)) {
        return QStringLiteral("无线网卡当前不可用");
    }
    if (operation == QStringLiteral("connect")) return QStringLiteral("Wi-Fi 连接失败");
    if (operation == QStringLiteral("forget")) return QStringLiteral("删除网络失败");
    return QStringLiteral("Wi-Fi 扫描失败");
}

QVariantMap collectWifiNetworks()
{
    QVariantMap result;
    QSet<QString> savedNetworks;
    const QString savedOutput = runProcess(QStringLiteral("nmcli"),
                                           {QStringLiteral("-t"), QStringLiteral("-e"), QStringLiteral("yes"),
                                            QStringLiteral("-f"), QStringLiteral("NAME,TYPE"),
                                            QStringLiteral("connection"), QStringLiteral("show")}, 2500);
    for (const QString &line : savedOutput.split(QRegularExpression(QStringLiteral("\\r?\\n")), Qt::SkipEmptyParts)) {
        const QStringList fields = splitNmcliTerseLine(line);
        if (fields.size() >= 2 && fields.at(1) == QStringLiteral("802-11-wireless")) {
            savedNetworks.insert(fields.at(0));
        }
    }

    const ProcessResult scanResult = runProcessDetailed(QStringLiteral("nmcli"),
                                                         {QStringLiteral("device"), QStringLiteral("wifi"),
                                                          QStringLiteral("rescan"), QStringLiteral("ifname"),
                                                          QStringLiteral("wlan0")}, 12000);
    const ProcessResult listResult = runProcessDetailed(QStringLiteral("nmcli"),
                                                         {QStringLiteral("-t"), QStringLiteral("-e"),
                                                          QStringLiteral("yes"), QStringLiteral("-f"),
                                                          QStringLiteral("IN-USE,SSID,SIGNAL,CHAN,FREQ,RATE,SECURITY,BARS"),
                                                          QStringLiteral("device"), QStringLiteral("wifi"),
                                                          QStringLiteral("list"), QStringLiteral("ifname"),
                                                          QStringLiteral("wlan0"), QStringLiteral("--rescan"),
                                                          QStringLiteral("no")}, 5000);
    QVariantList networks;
    QSet<QString> seen;
    for (const QString &line : listResult.output.split(QRegularExpression(QStringLiteral("\\r?\\n")), Qt::SkipEmptyParts)) {
        const QStringList fields = splitNmcliTerseLine(line);
        if (fields.size() < 8 || fields.at(1).isEmpty() || seen.contains(fields.at(1))) continue;
        seen.insert(fields.at(1));
        bool frequencyOk = false;
        const int frequency = fields.at(4).section(QLatin1Char(' '), 0, 0).toInt(&frequencyOk);
        QString band;
        if (frequencyOk && frequency >= 5925) band = QStringLiteral("6 GHz");
        else if (frequencyOk && frequency >= 4900) band = QStringLiteral("5 GHz");
        else if (frequencyOk && frequency > 0) band = QStringLiteral("2.4 GHz");
        QVariantMap item;
        item.insert(QStringLiteral("active"), fields.at(0) == QStringLiteral("*") || fields.at(0) == QStringLiteral("yes"));
        item.insert(QStringLiteral("ssid"), fields.at(1));
        item.insert(QStringLiteral("signal"), fields.at(2).toInt());
        item.insert(QStringLiteral("channel"), fields.at(3).toInt());
        item.insert(QStringLiteral("frequency"), frequencyOk ? frequency : 0);
        item.insert(QStringLiteral("band"), band);
        item.insert(QStringLiteral("rate"), fields.at(5));
        item.insert(QStringLiteral("security"), fields.at(6).isEmpty() || fields.at(6) == QStringLiteral("--")
                    ? QStringLiteral("开放") : QString(fields.at(6)).replace(QLatin1Char(' '), QLatin1Char('/')));
        item.insert(QStringLiteral("bars"), fields.at(7));
        item.insert(QStringLiteral("saved"), savedNetworks.contains(fields.at(1)));
        networks.append(item);
    }
    const bool ok = scanResult.ok() && listResult.ok();
    result.insert(QStringLiteral("ok"), ok);
    result.insert(QStringLiteral("networks"), networks);
    result.insert(QStringLiteral("message"), ok ? QString()
                                                 : wifiFailureMessage(scanResult.ok() ? listResult : scanResult,
                                                                      QStringLiteral("scan")));
    return result;
}

QVariantMap runWifiOperation(const QString &operation, const QString &ssid, const QString &password)
{
    QVariantMap result;
    ProcessResult processResult;
    if (operation == QStringLiteral("connect")) {
        const ProcessResult savedProfile = runProcessDetailed(QStringLiteral("nmcli"),
                                                               {QStringLiteral("connection"), QStringLiteral("show"),
                                                                QStringLiteral("id"), ssid}, 3000);
        if (!password.isEmpty() && savedProfile.ok()) {
            const ProcessResult updatePassword = runProcessDetailed(QStringLiteral("nmcli"),
                                                                     {QStringLiteral("connection"), QStringLiteral("modify"),
                                                                      QStringLiteral("id"), ssid,
                                                                      QStringLiteral("802-11-wireless-security.psk"), password}, 5000);
            processResult = updatePassword.ok()
                    ? runProcessDetailed(QStringLiteral("nmcli"),
                                         {QStringLiteral("connection"), QStringLiteral("up"),
                                          QStringLiteral("id"), ssid, QStringLiteral("ifname"),
                                          QStringLiteral("wlan0")}, 30000)
                    : updatePassword;
        } else {
            QStringList arguments{QStringLiteral("device"), QStringLiteral("wifi"), QStringLiteral("connect"), ssid,
                                  QStringLiteral("ifname"), QStringLiteral("wlan0")};
            if (!password.isEmpty()) arguments << QStringLiteral("password") << password;
            processResult = runProcessDetailed(QStringLiteral("nmcli"), arguments, 30000);
        }
    } else {
        processResult = runProcessDetailed(QStringLiteral("nmcli"),
                                           {QStringLiteral("connection"), QStringLiteral("delete"),
                                            QStringLiteral("id"), ssid}, 8000);
    }
    const bool ok = processResult.ok();
    result.insert(QStringLiteral("ok"), ok);
    result.insert(QStringLiteral("operation"), operation);
    result.insert(QStringLiteral("message"), ok
                  ? (operation == QStringLiteral("connect") ? QStringLiteral("Wi-Fi 已连接")
                                                             : QStringLiteral("已忘记网络"))
                  : wifiFailureMessage(processResult, operation));
    return result;
}

QVariantMap runEthernetConfiguration(const QString &interfaceName, const QString &requestedConnection,
                                     const QString &method, const QString &address, int prefix,
                                     const QString &gateway, const QString &dns)
{
    QVariantMap result;
    result.insert(QStringLiteral("interface"), interfaceName);
    if (interfaceName != QStringLiteral("eth0") && interfaceName != QStringLiteral("eth1")) {
        result.insert(QStringLiteral("ok"), false);
        result.insert(QStringLiteral("message"), QStringLiteral("无效的有线网络接口"));
        return result;
    }
    const bool manual = method == QStringLiteral("manual");
    if (manual && (address.trimmed().isEmpty() || prefix < 1 || prefix > 32)) {
        result.insert(QStringLiteral("ok"), false);
        result.insert(QStringLiteral("message"), QStringLiteral("请填写有效的 IPv4 地址和前缀长度"));
        return result;
    }

    QString connectionName = requestedConnection.trimmed();
    ProcessResult operation;
    if (connectionName.isEmpty()) {
        connectionName = QStringLiteral("Meow %1").arg(interfaceName);
        operation = runProcessDetailed(QStringLiteral("nmcli"),
                                       {QStringLiteral("connection"), QStringLiteral("add"),
                                        QStringLiteral("type"), QStringLiteral("ethernet"),
                                        QStringLiteral("ifname"), interfaceName,
                                        QStringLiteral("con-name"), connectionName}, 8000);
        if (!operation.ok()) {
            result.insert(QStringLiteral("ok"), false);
            result.insert(QStringLiteral("message"), QStringLiteral("无法创建有线网络配置"));
            return result;
        }
    }

    QStringList arguments{QStringLiteral("connection"), QStringLiteral("modify"),
                          QStringLiteral("id"), connectionName, QStringLiteral("ipv4.method"),
                          manual ? QStringLiteral("manual") : QStringLiteral("auto")};
    if (manual) {
        arguments << QStringLiteral("ipv4.addresses")
                  << address.trimmed() + QLatin1Char('/') + QString::number(prefix)
                  << QStringLiteral("ipv4.gateway") << gateway.trimmed()
                  << QStringLiteral("ipv4.dns") << dns.trimmed();
    } else {
        arguments << QStringLiteral("ipv4.addresses") << QString()
                  << QStringLiteral("ipv4.gateway") << QString()
                  << QStringLiteral("ipv4.dns") << QString();
    }
    operation = runProcessDetailed(QStringLiteral("nmcli"), arguments, 8000);
    if (!operation.ok()) {
        result.insert(QStringLiteral("ok"), false);
        result.insert(QStringLiteral("message"), QStringLiteral("应用有线网络配置失败"));
        return result;
    }
    const ProcessResult activation = runProcessDetailed(QStringLiteral("nmcli"),
                                                         {QStringLiteral("connection"), QStringLiteral("up"),
                                                          QStringLiteral("id"), connectionName,
                                                          QStringLiteral("ifname"), interfaceName}, 30000);
    result.insert(QStringLiteral("ok"), true);
    result.insert(QStringLiteral("message"), activation.ok()
                  ? QStringLiteral("有线网络配置已应用")
                  : QStringLiteral("配置已保存，等待网线连接"));
    return result;
}

QVariantMap runEthernetLinkOperation(const QString &interfaceName, bool connect)
{
    QVariantMap result;
    result.insert(QStringLiteral("interface"), interfaceName);
    const ProcessResult operation = runProcessDetailed(QStringLiteral("nmcli"),
                                                        {QStringLiteral("device"),
                                                         connect ? QStringLiteral("connect") : QStringLiteral("disconnect"),
                                                         interfaceName}, connect ? 30000 : 8000);
    result.insert(QStringLiteral("ok"), operation.ok());
    result.insert(QStringLiteral("message"), operation.ok()
                  ? (connect ? QStringLiteral("网口已连接") : QStringLiteral("网口已断开"))
                  : (connect ? QStringLiteral("网口连接失败") : QStringLiteral("网口断开失败")));
    return result;
}

bool isUserFilePath(const QString &path)
{
    const QString clean = QDir::cleanPath(path);
    return clean == QStringLiteral("/home/radxa") || clean.startsWith(QStringLiteral("/home/radxa/"))
            || clean == QStringLiteral("/data") || clean.startsWith(QStringLiteral("/data/"));
}

bool copyFileTree(const QString &source, const QString &destination, QString *error)
{
    const QFileInfo sourceInfo(source);
    if (sourceInfo.isSymLink()) {
        if (error) *error = QStringLiteral("暂不支持复制符号链接");
        return false;
    }
    if (!sourceInfo.isDir()) {
        if (QFile::copy(source, destination)) return true;
        if (error) *error = QStringLiteral("无法复制文件");
        return false;
    }
    if (!QDir().mkpath(destination)) {
        if (error) *error = QStringLiteral("无法创建目标文件夹");
        return false;
    }
    const QDir directory(source);
    const QFileInfoList children = directory.entryInfoList(
        QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden | QDir::System,
        QDir::DirsFirst | QDir::Name);
    for (const QFileInfo &child : children) {
        if (!copyFileTree(child.absoluteFilePath(),
                          QDir(destination).filePath(child.fileName()), error))
            return false;
    }
    return true;
}

QString availableDestination(const QString &directory, const QString &name)
{
    QString candidate = QDir(directory).filePath(name);
    if (!QFileInfo::exists(candidate)) return candidate;
    const QFileInfo original(name);
    const QString base = original.completeBaseName().isEmpty() ? name : original.completeBaseName();
    const QString suffix = original.suffix();
    for (int copy = 2; copy < 10000; ++copy) {
        const QString renamed = suffix.isEmpty()
                ? QStringLiteral("%1 (%2)").arg(base).arg(copy)
                : QStringLiteral("%1 (%2).%3").arg(base).arg(copy).arg(suffix);
        candidate = QDir(directory).filePath(renamed);
        if (!QFileInfo::exists(candidate)) return candidate;
    }
    return QString();
}

} // namespace

SystemBackend::SystemBackend(QObject *parent)
    : QObject(parent)
{
    m_hardwareCapabilities = detectHardwareCapabilities(&m_boardProfile);
    m_batteryCalibrationStatus = QStringLiteral("已禁用");
    m_batteryCalibrationSummary = QStringLiteral("旧校准配置保留但不再应用；电池实际容量尚未确认");
    QSettings displaySettings(QStringLiteral("Meow OS"), QStringLiteral("display"));
    m_sleepTimeoutSeconds = displaySettings.value(QStringLiteral("sleepTimeoutSeconds"), 60).toInt();
    m_sleepPowerLevel = displaySettings.value(QStringLiteral("sleepPowerLevel"), 1).toInt();
    if (displaySettings.contains(QStringLiteral("keepScreenOnApps"))) {
        m_keepScreenOnApps = displaySettings.value(QStringLiteral("keepScreenOnApps")).toStringList();
    } else {
        m_keepScreenOnApps = QStringList{QStringLiteral("touch-test"), QStringLiteral("reaction-game")};
        displaySettings.setValue(QStringLiteral("keepScreenOnApps"), m_keepScreenOnApps);
    }
    QSettings fileSettings(QStringLiteral("Meow OS"), QStringLiteral("files"));
    m_favoriteLocations = fileSettings.value(QStringLiteral("favorites")).toList();
    const int favoriteDefaultsVersion = fileSettings.value(QStringLiteral("favoriteDefaultsVersion"), 0).toInt();
    if (favoriteDefaultsVersion < 2) {
        const auto ensureFavorite = [this](const QString &path, const QString &label) {
            for (const QVariant &item : m_favoriteLocations)
                if (item.toMap().value(QStringLiteral("path")).toString() == path) return;
            QVariantMap favorite;
            favorite.insert(QStringLiteral("path"), path);
            favorite.insert(QStringLiteral("label"), label);
            m_favoriteLocations.append(favorite);
        };
        ensureFavorite(QStringLiteral("/"), QStringLiteral("系统盘"));
        ensureFavorite(QStringLiteral("/data"), QStringLiteral("NVMe"));
        fileSettings.setValue(QStringLiteral("favorites"), m_favoriteLocations);
        fileSettings.setValue(QStringLiteral("favoriteDefaultsVersion"), 2);
        fileSettings.setValue(QStringLiteral("favoritesInitialized"), true);
    }
    m_idleElapsedTimer.start();
    if (qApp) qApp->installEventFilter(this);
    m_volumeSetTimer.setSingleShot(true);
    m_volumeSetTimer.setInterval(80);
    m_brightnessSetTimer.setSingleShot(true);
    m_brightnessSetTimer.setInterval(60);

    // Preload system memory metrics synchronously so status bar never flashes empty
    {
        qint64 total = 0, avail = 0;
        QFile mem(QStringLiteral("/proc/meminfo"));
        if (mem.open(QIODevice::ReadOnly | QIODevice::Text)) {
            while (true) {
                const QByteArray line = mem.readLine();
                if (line.isEmpty()) break;
                long long v = 0;
                if (line.startsWith("MemTotal:") && std::sscanf(line.constData(), "MemTotal: %lld", &v) == 1) total = v;
                else if (line.startsWith("MemAvailable:") && std::sscanf(line.constData(), "MemAvailable: %lld", &v) == 1) avail = v;
                if (total > 0 && avail > 0) break;
            }
            if (total > 0) {
                total *= 1024; avail *= 1024;
                m_memoryTotalBytes = total;
                m_memoryAvailableBytes = avail;
                m_memoryUsedBytes = qMax<qint64>(0, total - avail);
                m_memoryPercent = qBound(0, static_cast<int>(100.0 * m_memoryUsedBytes / total), 100);
            }
        }
    }

    m_cpuBoostReleaseTimer.setSingleShot(true);
    m_cpuBoostReleaseTimer.setInterval(320);
    connect(&m_cpuBoostReleaseTimer, &QTimer::timeout,
            this, &SystemBackend::releaseInteractiveCpuBoost);
    m_runtimeScheduler.setInteractiveWakeupCallback([this]() {
        QMetaObject::invokeMethod(this, [this]() { activateInteractiveCpuBoost(); },
                                  Qt::QueuedConnection);
    });
    m_volumeSetProcess.setProcessChannelMode(QProcess::MergedChannels);
    m_feedbackProcess.setProcessChannelMode(QProcess::MergedChannels);
    connect(&m_volumeSetTimer, &QTimer::timeout, this, [this]() {
        if (m_volumeSetProcess.state() != QProcess::NotRunning) {
            m_volumeSetTimer.start();
            return;
        }
        m_volumeSetProcess.start(QStringLiteral("amixer"),
                                 {QStringLiteral("-c"), QStringLiteral("Speaker"),
                                  QStringLiteral("sset"), QStringLiteral("Speaker"),
                                  QString::number(m_pendingVolumePercent) + QLatin1Char('%')});
    });
    connect(&m_volumeSetProcess,
            QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this](int, QProcess::ExitStatus) { refreshStatus(); });
    connect(&m_brightnessSetTimer, &QTimer::timeout, this, [this]() {
        if (m_backlightPath.isEmpty() || m_brightnessMax <= 0) return;
        const int level = qBound(1, qRound(m_brightnessMax * m_pendingBrightnessPercent / 100.0),
                                 m_brightnessMax);
        QFile brightness(m_backlightPath);
        if (!brightness.open(QIODevice::WriteOnly | QIODevice::Text)) return;
        brightness.write(QByteArray::number(level));
        brightness.close();
        refreshStatus();
    });
    m_mindustryLaunchPollTimer.setInterval(50);
    m_mindustryLaunchPollTimer.setSingleShot(false);
    connect(&m_mindustryLaunchPollTimer, &QTimer::timeout, this, [this]() {
        if (!m_mindustryLaunchFuture.valid()
                || m_mindustryLaunchFuture.wait_for(std::chrono::milliseconds(0))
                   != std::future_status::ready) return;
        m_mindustryLaunchPollTimer.stop();
        bool requested = false;
        try {
            m_mindustryLaunchFuture.get();
            requested = true;
        } catch (...) {
            requested = false;
        }
        emit operationMessage(requested ? QStringLiteral("像素工厂正在启动…")
                                        : QStringLiteral("像素工厂启动失败，请检查游戏服务与授权"),
                              requested);
        emit schedulerChanged();
    });
    connect(&m_pvzLaunchProcess, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this](int code, QProcess::ExitStatus status) {
        const bool ok = code == 0 && status == QProcess::NormalExit;
        emit operationMessage(ok ? QStringLiteral("植物大战僵尸正在启动…")
                                 : QStringLiteral("游戏启动失败，请检查 meow-pvz 服务与授权"), ok);
    });
    connect(&m_pvzLaunchProcess, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart)
            emit operationMessage(QStringLiteral("无法执行游戏启动命令"), false);
    });
    refresh();
    QTimer::singleShot(250, this, &SystemBackend::refreshPerformance);
}

QString SystemBackend::version() const { return QStringLiteral(MEOW_OS_VERSION); }
QString SystemBackend::hostname() const { return m_hostname; }
QString SystemBackend::kernel() const { return m_kernel; }
QString SystemBackend::diskUsed() const { return m_diskUsed; }
QString SystemBackend::diskTotal() const { return m_diskTotal; }
int SystemBackend::diskPercent() const { return m_diskPercent; }
bool SystemBackend::nvmeAvailable() const { return m_nvmeAvailable; }
bool SystemBackend::nvmeMounted() const { return m_nvmeMounted; }
QString SystemBackend::nvmeModel() const { return m_nvmeModel; }
QString SystemBackend::nvmeMountPoint() const { return m_nvmeMountPoint; }
QString SystemBackend::nvmeUsed() const { return m_nvmeUsed; }
QString SystemBackend::nvmeTotal() const { return m_nvmeTotal; }
int SystemBackend::nvmePercent() const { return m_nvmePercent; }
QVariantList SystemBackend::fileEntries() const { return m_fileEntries; }
QString SystemBackend::filePath() const { return m_filePath; }
bool SystemBackend::filesLoading() const { return m_filesLoading; }
QString SystemBackend::filesError() const { return m_filesError; }
QString SystemBackend::previewPath() const { return m_previewPath; }
QString SystemBackend::previewText() const { return m_previewText; }
QString SystemBackend::previewError() const { return m_previewError; }
bool SystemBackend::previewLoading() const { return m_previewLoading; }
QVariantList SystemBackend::favoriteLocations() const { return m_favoriteLocations; }
bool SystemBackend::fileOperationRunning() const { return m_fileOperationRunning; }
QString SystemBackend::fileOperationText() const { return m_fileOperationText; }
QString SystemBackend::wifiName() const { return m_wifiName; }
bool SystemBackend::wifiConnected() const { return !m_wifiName.isEmpty(); }
int SystemBackend::wifiSignal() const { return m_wifiSignal; }
QString SystemBackend::wifiIpv4() const { return m_wifiIpv4; }
QString SystemBackend::wifiGateway() const { return m_wifiGateway; }
QString SystemBackend::wifiMac() const { return m_wifiMac; }
QString SystemBackend::wifiDevice() const { return m_wifiDevice; }
bool SystemBackend::wifiScanning() const { return m_wifiScanRunning; }
bool SystemBackend::wifiOperating() const { return m_wifiOperationRunning; }
QString SystemBackend::wifiOperation() const { return m_wifiOperation; }
QString SystemBackend::wifiOperationSsid() const { return m_wifiOperationSsid; }
QString SystemBackend::wifiScanError() const { return m_wifiScanError; }
QVariantList SystemBackend::wifiNetworks() const { return m_wifiNetworks; }
QVariantList SystemBackend::ethernetPorts() const { return m_ethernetPorts; }
bool SystemBackend::ethernetOperating() const { return m_ethernetOperationRunning; }
QString SystemBackend::ethernetOperationInterface() const { return m_ethernetOperationInterface; }
bool SystemBackend::batteryAvailable() const { return m_batteryAvailable; }
int SystemBackend::batteryPercent() const { return m_batteryPercent; }
QString SystemBackend::batteryStatus() const { return m_batteryStatus; }
bool SystemBackend::batteryCharging() const { return m_batteryCharging; }
bool SystemBackend::chargerAvailable() const { return m_chargerAvailable; }
bool SystemBackend::externalPowerPresent() const { return m_externalPowerPresent; }
double SystemBackend::batteryTemperatureC() const { return m_batteryTemperatureC; }
QString SystemBackend::chargeTemperatureZone() const { return m_chargeTemperatureZone; }
int SystemBackend::batteryVoltageMv() const { return m_batteryVoltageMv; }
int SystemBackend::batteryCurrentMa() const { return m_batteryCurrentMa; }
QString SystemBackend::batteryHealth() const { return m_batteryHealth; }
double SystemBackend::batteryPowerW() const
{
    if (!m_batteryAvailable || m_batteryVoltageMv < 0
            || !m_powerManagement.value("currentValid").toBool()
            || !m_powerManagement.value("voltageValid").toBool()) return -1.0;
    return qAbs(static_cast<double>(m_batteryVoltageMv) * m_batteryCurrentMa) / 1000000.0;
}

int SystemBackend::batteryRawVoltageMv() const { return m_batteryRawVoltageMv; }
int SystemBackend::batteryRawCurrentMa() const { return m_batteryRawCurrentMa; }
int SystemBackend::batteryRemainingMah() const { return m_batteryRemainingMah; }
int SystemBackend::batteryFullChargeMah() const { return m_batteryFullChargeMah; }
int SystemBackend::batteryDesignCapacityMah() const { return m_batteryDesignCapacityMah; }
bool SystemBackend::gaugeCommunication() const { return m_gaugeCommunication; }
QString SystemBackend::gaugeError() const { return m_gaugeError; }
QString SystemBackend::batteryCalibrationStatus() const { return m_batteryCalibrationStatus; }
QString SystemBackend::batteryCalibrationSummary() const { return m_batteryCalibrationSummary; }
QString SystemBackend::boardProfile() const { return m_boardProfile; }
QVariantMap SystemBackend::hardwareCapabilities() const { return m_hardwareCapabilities; }
int SystemBackend::volumePercent() const { return m_volumePercent; }
bool SystemBackend::audioAvailable() const { return m_audioAvailable; }
int SystemBackend::displayBrightnessPercent() const { return m_displayBrightnessPercent; }
bool SystemBackend::brightnessAvailable() const { return m_brightnessAvailable; }
int SystemBackend::cpuTotal() const { return m_cpuTotal; }
QVariantList SystemBackend::cpuUsage() const { return m_cpuUsage; }
QVariantList SystemBackend::cpuFrequencies() const { return m_cpuFrequencies; }
int SystemBackend::gpuUsage() const { return m_gpuUsage; }
double SystemBackend::cpuTemperatureC() const { return m_cpuTemperatureC; }
int SystemBackend::cpuFrequencyMhz() const { return m_cpuFrequencyMhz; }
int SystemBackend::cpuMaxFrequencyMhz() const { return m_cpuMaxFrequencyMhz; }
int SystemBackend::gpuFrequencyMhz() const { return m_gpuFrequencyMhz; }
QString SystemBackend::loadAverage() const { return m_loadAverage; }
QString SystemBackend::uptime() const { return m_uptime; }
int SystemBackend::processCount() const { return m_processCount; }
int SystemBackend::memoryPercent() const { return m_memoryPercent; }
QString SystemBackend::memoryUsed() const { return formatBytes(m_memoryUsedBytes); }
QString SystemBackend::memoryAvailable() const { return formatBytes(m_memoryAvailableBytes); }
QString SystemBackend::memoryTotal() const { return formatBytes(m_memoryTotalBytes); }
QVariantList SystemBackend::performanceHistory() const { return m_performanceHistory; }

int SystemBackend::displayRotation() const
{
    bool ok = false;
    const int value = qEnvironmentVariableIntValue("MEOW_UI_ROTATION", &ok);
    return ok ? value : -90;
}

int SystemBackend::schedulerPendingTasks() const
{
    return static_cast<int>(m_runtimeScheduler.pendingTasks());
}

int SystemBackend::schedulerRunningTasks() const
{
    return static_cast<int>(m_runtimeScheduler.runningTasks());
}

int SystemBackend::schedulerSubmittedTasks() const
{
    return static_cast<int>(m_runtimeScheduler.stats().submitted);
}

int SystemBackend::schedulerRejectedTasks() const
{
    return static_cast<int>(m_runtimeScheduler.stats().rejected);
}

int SystemBackend::schedulerPeakPendingTasks() const
{
    return static_cast<int>(m_runtimeScheduler.stats().peakPending);
}

int SystemBackend::schedulerWorkerCount() const
{
    return static_cast<int>(m_runtimeScheduler.workerCount());
}

QString SystemBackend::foregroundApp() const
{
    return QString::fromStdString(m_sessionSupervisor.activeAppId());
}

bool SystemBackend::foregroundAppActive() const
{
    return m_sessionSupervisor.hasActiveSession();
}

bool SystemBackend::beginForegroundApp(const QString &appId)
{
    if (appId.isEmpty()) return false;
    const bool started = m_sessionSupervisor.start(appId.toStdString());
    if (started) emit sessionChanged();
    return started;
}

bool SystemBackend::endForegroundApp(const QString &appId)
{
    if (!m_sessionSupervisor.hasActiveSession()) return true;
    if (!appId.isEmpty() && foregroundApp() != appId) return false;
    const bool stopped = m_sessionSupervisor.stop();
    if (stopped) emit sessionChanged();
    return stopped;
}

void SystemBackend::refresh()
{
    refreshSystem();
    refreshStorage();
    refreshStatus();
    refreshPerformance();
}

void SystemBackend::refreshStatus()
{
    if (m_statusTaskRunning) {
        m_statusRefreshPending = true;
        return;
    }
    m_statusTaskRunning = true;
    const QString scope = m_activeScope;
    const meow::TaskPriority priority = scope == QStringLiteral("idle")
            ? meow::TaskPriority::Background : meow::TaskPriority::Interactive;
    const bool accepted = m_runtimeScheduler.trySubmit(priority, [this, scope]() {
        const QVariantMap snapshot = collectStatus(scope);
        QMetaObject::invokeMethod(this, [this, snapshot]() {
            m_statusTaskRunning = false;
            applyStatusSnapshot(snapshot);
            emit schedulerChanged();
            if (m_statusRefreshPending) {
                m_statusRefreshPending = false;
                refreshStatus();
            }
        }, Qt::QueuedConnection);
    });
    if (!accepted) {
        m_statusTaskRunning = false;
        m_statusRefreshPending = true;
        QTimer::singleShot(120, this, [this]() {
            if (!m_statusRefreshPending) return;
            m_statusRefreshPending = false;
            refreshStatus();
        });
    }
    emit schedulerChanged();
}

void SystemBackend::setActiveScope(const QString &scope)
{
    if (m_activeScope == scope) return;
    m_activeScope = scope;
    if (scope == QLatin1String("wifi") && !m_pendingWifiNetworks.isEmpty()) {
        m_wifiNetworks = m_pendingWifiNetworks;
        m_wifiScanError = m_pendingWifiScanError;
        m_pendingWifiNetworks.clear();
        m_pendingWifiScanError.clear();
        QTimer::singleShot(20, this, [this]() { emit wifiChanged(); });
    }
    if (scope == QLatin1String("storage") && !m_pendingStorageSnapshot.isEmpty()) {
        const QVariantMap snapshot = m_pendingStorageSnapshot;
        m_pendingStorageSnapshot.clear();
        QTimer::singleShot(20, this, [this, snapshot]() { applyStorageSnapshot(snapshot); });
    }
    if (scope == QLatin1String("performance")) {
        if (!m_pendingPerformanceSnapshot.isEmpty()) {
            const QVariantMap snapshot = m_pendingPerformanceSnapshot;
            m_pendingPerformanceSnapshot.clear();
            QTimer::singleShot(20, this, [this, snapshot, scope]() { applyPerformanceSnapshot(snapshot, scope); });
        }
        refreshPerformance();
    }
    if (!m_statusTaskRunning) refreshStatus();
}

void SystemBackend::boostInteractivePerformance(int tier, int durationMs)
{
    activateInteractiveCpuBoost(tier, durationMs);
}

void SystemBackend::releaseInteractivePerformance()
{
    releaseInteractiveCpuBoost();
}

void SystemBackend::activateInteractiveCpuBoost(int tier, int durationMs)
{
    if (m_screenSleeping) return;
    const int timeout = durationMs > 0 ? durationMs : (tier >= 2 ? 650 : 280);
    if (!m_cpuBoostRestoreMins.isEmpty()) {
        m_cpuBoostReleaseTimer.start(timeout);
        return;
    }
    if (m_cpuBoostRestoreMins.isEmpty()) {
        const QDir cpufreq(QStringLiteral("/sys/devices/system/cpu/cpufreq"));
        const QStringList policies = cpufreq.entryList({QStringLiteral("policy*")}, QDir::Dirs | QDir::NoDotAndDotDot);
        for (const QString &policy : policies) {
            const QString base = cpufreq.absoluteFilePath(policy);
            const QString minPath = base + QStringLiteral("/scaling_min_freq");
            const QByteArray currentMin = readTextFile(minPath).toLocal8Bit();
            const QByteArray maximum = readTextFile(base + QStringLiteral("/scaling_max_freq")).toLocal8Bit();
            if (currentMin.isEmpty() || maximum.isEmpty()) continue;
            m_cpuBoostRestoreMins.append(qMakePair(minPath, currentMin));
        }
        if (!saveCpuFreqState(kCpuFreqBoostStatePath, m_cpuBoostRestoreMins)) {
            m_cpuBoostRestoreMins.clear();
            return;
        }
        for (const auto &entry : m_cpuBoostRestoreMins) {
            const QString base = QFileInfo(entry.first).absolutePath();
            const QByteArray maximum = readTextFile(base + QStringLiteral("/scaling_max_freq")).toLocal8Bit();
            QFile file(entry.first);
            if (!maximum.isEmpty() && file.open(QIODevice::WriteOnly | QIODevice::Text))
                file.write(maximum + '\n');
        }
    }
    m_cpuBoostReleaseTimer.start(timeout);
}

void SystemBackend::releaseInteractiveCpuBoost()
{
    m_cpuBoostReleaseTimer.stop();
    for (const auto &entry : m_cpuBoostRestoreMins) {
        QFile file(entry.first);
        if (!file.open(QIODevice::WriteOnly | QIODevice::Text)) continue;
        file.write(entry.second + '\n');
    }
    m_cpuBoostRestoreMins.clear();
    QFile::remove(kCpuFreqBoostStatePath);
}

qint64 SystemBackend::idleMs() const
{
    return m_idleElapsedTimer.isValid() ? m_idleElapsedTimer.elapsed() : 0;
}

bool SystemBackend::eventFilter(QObject *watched, QEvent *event)
{
    Q_UNUSED(watched)
    switch (event->type()) {
    case QEvent::MouseButtonPress:
    case QEvent::TouchBegin:
    case QEvent::KeyPress:
        m_idleElapsedTimer.restart();
        if (m_screenSleeping) {
            wakeScreen();
            return true;
        }
        emit inputActivity();
        break;
    case QEvent::MouseButtonRelease:
    case QEvent::TouchEnd:
    case QEvent::Wheel:
        m_idleElapsedTimer.restart();
        break;
    default:
        break;
    }
    return false;
}

void SystemBackend::refreshPerformance()
{
    if (m_performanceTaskRunning) {
        m_performanceRefreshPending = true;
        return;
    }
    m_performanceTaskRunning = true;
    const QString scope = m_activeScope;
    const meow::TaskPriority priority = scope == QStringLiteral("performance")
            ? meow::TaskPriority::Interactive : meow::TaskPriority::Background;
    const bool accepted = m_runtimeScheduler.trySubmit(priority, [this, scope]() {
        const QVariantMap snapshot = collectPerformanceSnapshot();
        QMetaObject::invokeMethod(this, [this, snapshot, scope]() {
            m_performanceTaskRunning = false;
            const int mem = snapshot.value(QStringLiteral("memoryPercent"), -1).toInt();
            if (mem >= 0 && (mem != m_memoryPercent || m_memoryPercent < 0)) {
                m_memoryPercent = mem;
                m_memoryUsedBytes = snapshot.value(QStringLiteral("memoryUsedBytes"), 0).toLongLong();
                m_memoryAvailableBytes = snapshot.value(QStringLiteral("memoryAvailableBytes"), 0).toLongLong();
                m_memoryTotalBytes = snapshot.value(QStringLiteral("memoryTotalBytes"), 0).toLongLong();
                emit performanceChanged();
            }
            if (m_activeScope == QStringLiteral("performance"))
                applyPerformanceSnapshot(snapshot, scope);
            else
                m_pendingPerformanceSnapshot = snapshot;
            emit schedulerChanged();
            if (m_performanceRefreshPending) {
                m_performanceRefreshPending = false;
                refreshPerformance();
            }
        }, Qt::QueuedConnection);
    });
    if (!accepted) m_performanceTaskRunning = false;
    emit schedulerChanged();
}

QVariantMap SystemBackend::collectPerformanceSnapshot()
{
    QVector<quint64> idle;
    QVector<quint64> total;
    QFile statFile(QStringLiteral("/proc/stat"));
    if (statFile.open(QIODevice::ReadOnly | QIODevice::Text)) {
        while (true) {
            const QByteArray rawLine = statFile.readLine();
            if (rawLine.isEmpty()) break;
            const QByteArray line = rawLine.trimmed();
            if (!line.startsWith("cpu")) continue;
            parseCpuLine(line, &idle, &total);
        }
    }
    QVariantList usage;
    const bool cpuSampleValid = !idle.isEmpty() && idle.size() == total.size();
    if (cpuSampleValid && m_cpuHavePrev && m_cpuPrevIdle.size() == idle.size()
            && m_cpuPrevTotal.size() == total.size()) {
        for (int i = 0; i < idle.size(); ++i) {
            const qint64 idleDelta = static_cast<qint64>(idle.at(i) - m_cpuPrevIdle.at(i));
            const qint64 totalDelta = static_cast<qint64>(total.at(i) - m_cpuPrevTotal.at(i));
            const int percent = totalDelta > 0
                    ? qBound(0, static_cast<int>(100.0 * (totalDelta - idleDelta) / totalDelta), 100)
                    : 0;
            usage.append(percent);
        }
    } else if (cpuSampleValid) {
        for (int i = 0; i < idle.size(); ++i) usage.append(0);
    }
    if (cpuSampleValid) {
        m_cpuHavePrev = true;
        m_cpuPrevIdle = idle;
        m_cpuPrevTotal = total;
    }
    const int cpuTotal = usage.isEmpty() ? -1 : usage.at(0).toInt();

    int gpu = -1;
    for (const QString &path : {QStringLiteral("/sys/kernel/gpu/gpu_busy"),
                                QStringLiteral("/sys/kernel/gpu/gpu_utilization")}) {
        const QString text = readTextFile(path);
        if (text.isEmpty()) continue;
        const int parsed = parseGpuBusy(text);
        if (parsed >= 0) { gpu = parsed; break; }
    }
    int gpuFrequencyMhz = -1;
    const QDir devfreq(QStringLiteral("/sys/class/devfreq"));
    for (const QString &entry : devfreq.entryList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name)) {
        const QString base = devfreq.absoluteFilePath(entry);
        const QString deviceName = readTextFile(base + QStringLiteral("/name")).toLower();
        if (!entry.contains(QStringLiteral("gpu"), Qt::CaseInsensitive)
                && !deviceName.contains(QStringLiteral("gpu"))) continue;
        qint64 gpuFrequencyHz = 0;
        if (readInteger(base + QStringLiteral("/cur_freq"), &gpuFrequencyHz) && gpuFrequencyHz > 0)
            gpuFrequencyMhz = static_cast<int>(gpuFrequencyHz / 1000000);
        if (gpu < 0) {
            const QString load = readTextFile(base + QStringLiteral("/load"));
            const QStringList fields = load.split(QRegularExpression(QStringLiteral("\\s+")), Qt::SkipEmptyParts);
            bool firstOk = false;
            QString firstField = fields.value(0);
            firstField.remove(QLatin1Char('%'));
            const qint64 first = firstField.toLongLong(&firstOk);
            if (firstOk && fields.size() == 1 && first >= 0 && first <= 100) {
                gpu = static_cast<int>(first);
            } else if (firstOk && fields.size() >= 2) {
                bool secondOk = false;
                const qint64 second = fields.at(1).toLongLong(&secondOk);
                if (secondOk && second > 0 && first >= 0 && first <= second)
                    gpu = qBound(0, static_cast<int>(100.0 * first / second), 100);
            }
        }
        break;
    }

    double cpuTemperature = -273.15;
    const QDir thermal(QStringLiteral("/sys/class/thermal"));
    const QStringList thermalZones = thermal.entryList(QStringList{QStringLiteral("thermal_zone*")},
                                                       QDir::Dirs, QDir::Name);
    for (const QString &zone : thermalZones) {
        const QString base = thermal.absoluteFilePath(zone);
        const QString type = readTextFile(base + QStringLiteral("/type")).toLower();
        if (!type.contains(QStringLiteral("cpu")) && !type.contains(QStringLiteral("soc"))) continue;
        qint64 raw = 0;
        if (readInteger(base + QStringLiteral("/temp"), &raw)) {
            cpuTemperature = normalizeTemperature(raw);
            break;
        }
    }

    qint64 frequencyKhz = 0;
    int cpuFrequencyMhz = -1;
    if (readInteger(QStringLiteral("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"), &frequencyKhz)
            && frequencyKhz > 0) {
        cpuFrequencyMhz = static_cast<int>(frequencyKhz / 1000);
    }
    qint64 maxFrequencyKhz = 0;
    int cpuMaxFrequencyMhz = -1;
    if ((readInteger(QStringLiteral("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq"), &maxFrequencyKhz)
         || readInteger(QStringLiteral("/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq"), &maxFrequencyKhz))
            && maxFrequencyKhz > 0) {
        cpuMaxFrequencyMhz = static_cast<int>(maxFrequencyKhz / 1000);
    }
    QVariantList cpuFrequencies;
    const int logicalCoreCount = cpuSampleValid ? qMax(0, idle.size() - 1) : 0;
    for (int core = 0; core < logicalCoreCount; ++core) {
        qint64 coreFrequencyKhz = 0;
        const QString path = QStringLiteral("/sys/devices/system/cpu/cpu%1/cpufreq/scaling_cur_freq").arg(core);
        cpuFrequencies.append(readInteger(path, &coreFrequencyKhz) && coreFrequencyKhz > 0
                              ? static_cast<int>(coreFrequencyKhz / 1000) : -1);
    }

    QString loadAverage;
    const QStringList loadFields = readTextFile(QStringLiteral("/proc/loadavg"))
            .split(QRegularExpression(QStringLiteral("\\s+")), Qt::SkipEmptyParts);
    if (loadFields.size() >= 3)
        loadAverage = loadFields.at(0) + QStringLiteral(" · ") + loadFields.at(1) + QStringLiteral(" · ") + loadFields.at(2);

    QString uptime;
    bool uptimeOk = false;
    const qint64 uptimeSeconds = readTextFile(QStringLiteral("/proc/uptime"))
            .section(QLatin1Char(' '), 0, 0).toDouble(&uptimeOk);
    if (uptimeOk && uptimeSeconds >= 0) {
        const qint64 days = uptimeSeconds / 86400;
        const qint64 hours = (uptimeSeconds % 86400) / 3600;
        const qint64 minutes = (uptimeSeconds % 3600) / 60;
        uptime = days > 0
                ? QStringLiteral("%1 天 %2 小时").arg(days).arg(hours)
                : QStringLiteral("%1 小时 %2 分钟").arg(hours).arg(minutes);
    }

    int processCount = 0;
    const QDir proc(QStringLiteral("/proc"));
    for (const QString &entry : proc.entryList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name)) {
        bool numeric = false;
        entry.toInt(&numeric);
        if (numeric) ++processCount;
    }

    qint64 memTotal = 0;
    qint64 memAvailable = 0;
    QFile memInfo(QStringLiteral("/proc/meminfo"));
    if (memInfo.open(QIODevice::ReadOnly | QIODevice::Text)) {
        while (true) {
            const QByteArray line = memInfo.readLine();
            if (line.isEmpty()) break;
            long long value = 0;
            if (line.startsWith("MemTotal:")
                    && std::sscanf(line.constData(), "MemTotal: %lld", &value) == 1) {
                memTotal = value;
            } else if (line.startsWith("MemAvailable:")
                       && std::sscanf(line.constData(), "MemAvailable: %lld", &value) == 1) {
                memAvailable = value;
            }
            if (memTotal > 0 && memAvailable > 0) break;
        }
    }
    // /proc/meminfo reports kB while the UI byte formatter expects bytes.
    memTotal *= 1024;
    memAvailable *= 1024;
    const qint64 memUsed = qMax<qint64>(0, memTotal - memAvailable);
    const int memPercent = memTotal > 0 ? qBound(0, static_cast<int>(100.0 * memUsed / memTotal), 100) : -1;

    QVariantMap sample;
    sample.insert(QStringLiteral("cpu"), cpuTotal);
    sample.insert(QStringLiteral("gpu"), gpu);
    sample.insert(QStringLiteral("memory"), memPercent);
    sample.insert(QStringLiteral("memoryUsed"), memUsed);
    sample.insert(QStringLiteral("memoryTotal"), memTotal);
    QVariantMap result;
    result.insert(QStringLiteral("cpuTotal"), cpuTotal);
    result.insert(QStringLiteral("cpuUsage"), usage);
    result.insert(QStringLiteral("cpuFrequencies"), cpuFrequencies);
    result.insert(QStringLiteral("gpuUsage"), gpu);
    result.insert(QStringLiteral("cpuTemperatureC"), cpuTemperature);
    result.insert(QStringLiteral("cpuFrequencyMhz"), cpuFrequencyMhz);
    result.insert(QStringLiteral("cpuMaxFrequencyMhz"), cpuMaxFrequencyMhz);
    result.insert(QStringLiteral("gpuFrequencyMhz"), gpuFrequencyMhz);
    result.insert(QStringLiteral("loadAverage"), loadAverage);
    result.insert(QStringLiteral("uptime"), uptime);
    result.insert(QStringLiteral("processCount"), processCount);
    result.insert(QStringLiteral("memoryPercent"), memPercent);
    result.insert(QStringLiteral("memoryUsedBytes"), memUsed);
    result.insert(QStringLiteral("memoryAvailableBytes"), memAvailable);
    result.insert(QStringLiteral("memoryTotalBytes"), memTotal);
    result.insert(QStringLiteral("historySample"), sample);
    return result;
}

void SystemBackend::applyPerformanceSnapshot(const QVariantMap &snapshot, const QString &scope)
{
    m_cpuTotal = snapshot.value(QStringLiteral("cpuTotal"), -1).toInt();
    m_cpuUsage = snapshot.value(QStringLiteral("cpuUsage")).toList();
    m_cpuFrequencies = snapshot.value(QStringLiteral("cpuFrequencies")).toList();
    m_gpuUsage = snapshot.value(QStringLiteral("gpuUsage"), -1).toInt();
    m_cpuTemperatureC = snapshot.value(QStringLiteral("cpuTemperatureC"), -273.15).toDouble();
    m_cpuFrequencyMhz = snapshot.value(QStringLiteral("cpuFrequencyMhz"), -1).toInt();
    m_cpuMaxFrequencyMhz = snapshot.value(QStringLiteral("cpuMaxFrequencyMhz"), -1).toInt();
    m_gpuFrequencyMhz = snapshot.value(QStringLiteral("gpuFrequencyMhz"), -1).toInt();
    m_loadAverage = snapshot.value(QStringLiteral("loadAverage")).toString();
    m_uptime = snapshot.value(QStringLiteral("uptime")).toString();
    m_processCount = snapshot.value(QStringLiteral("processCount"), 0).toInt();
    m_memoryPercent = snapshot.value(QStringLiteral("memoryPercent"), -1).toInt();
    m_memoryUsedBytes = snapshot.value(QStringLiteral("memoryUsedBytes"), 0).toLongLong();
    m_memoryAvailableBytes = snapshot.value(QStringLiteral("memoryAvailableBytes"), 0).toLongLong();
    m_memoryTotalBytes = snapshot.value(QStringLiteral("memoryTotalBytes"), 0).toLongLong();
    if (m_performanceHistory.size() >= 60) m_performanceHistory.removeFirst();
    m_performanceHistory.append(snapshot.value(QStringLiteral("historySample")));
    meow::RuntimeSnapshot runtimeSnapshot;
    runtimeSnapshot.sequence = ++m_runtimeSequence;
    runtimeSnapshot.cpuPercent = m_cpuTotal;
    runtimeSnapshot.memoryPercent = m_memoryPercent;
    runtimeSnapshot.gpuPercent = m_gpuUsage;
    runtimeSnapshot.displayRotation = displayRotation();
    runtimeSnapshot.foregroundApp = scope.toStdString();
    m_runtimeSnapshotStore.publish(std::move(runtimeSnapshot));
    emit performanceChanged();
}

void SystemBackend::refreshSystem()
{
    const QString hostname = readTextFile(QStringLiteral("/etc/hostname"));
    const QString kernel = QSysInfo::kernelVersion();
    if (hostname != m_hostname || kernel != m_kernel) {
        m_hostname = hostname;
        m_kernel = kernel;
        emit systemInfoChanged();
    }
}

void SystemBackend::refreshStorage()
{
    if (m_storageTaskRunning) {
        m_storageRefreshPending = true;
        return;
    }
    m_storageTaskRunning = true;
    const bool accepted = m_runtimeScheduler.trySubmit(meow::TaskPriority::Background, [this]() {
        const QVariantMap snapshot = collectStorageSnapshot();
        QMetaObject::invokeMethod(this, [this, snapshot]() {
            m_storageTaskRunning = false;
            if (m_activeScope == QStringLiteral("storage"))
                applyStorageSnapshot(snapshot);
            else
                m_pendingStorageSnapshot = snapshot;
            emit schedulerChanged();
            if (m_storageRefreshPending) {
                m_storageRefreshPending = false;
                refreshStorage();
            }
        }, Qt::QueuedConnection);
    });
    if (!accepted) m_storageTaskRunning = false;
    emit schedulerChanged();
}

void SystemBackend::applyStorageSnapshot(const QVariantMap &snapshot)
{
    if (!snapshot.contains(QStringLiteral("diskTotal"))) return;
    const QString diskUsed = snapshot.value(QStringLiteral("diskUsed")).toString();
    const QString diskTotal = snapshot.value(QStringLiteral("diskTotal")).toString();
    const int diskPercent = snapshot.value(QStringLiteral("diskPercent")).toInt();
    const bool nvmeAvailable = snapshot.value(QStringLiteral("nvmeAvailable")).toBool();
    const bool nvmeMounted = snapshot.value(QStringLiteral("nvmeMounted")).toBool();
    const QString nvmeModel = snapshot.value(QStringLiteral("nvmeModel")).toString();
    const QString nvmeMountPoint = snapshot.value(QStringLiteral("nvmeMountPoint")).toString();
    const QString nvmeUsed = snapshot.value(QStringLiteral("nvmeUsed")).toString();
    const QString nvmeTotal = snapshot.value(QStringLiteral("nvmeTotal")).toString();
    const int nvmePercent = snapshot.value(QStringLiteral("nvmePercent")).toInt();
    if (diskUsed == m_diskUsed && diskTotal == m_diskTotal && diskPercent == m_diskPercent
            && nvmeAvailable == m_nvmeAvailable && nvmeMounted == m_nvmeMounted
            && nvmeModel == m_nvmeModel && nvmeMountPoint == m_nvmeMountPoint
            && nvmeUsed == m_nvmeUsed && nvmeTotal == m_nvmeTotal && nvmePercent == m_nvmePercent) return;
    m_diskUsed = diskUsed;
    m_diskTotal = diskTotal;
    m_diskPercent = diskPercent;
    m_nvmeAvailable = nvmeAvailable;
    m_nvmeMounted = nvmeMounted;
    m_nvmeModel = nvmeModel;
    m_nvmeMountPoint = nvmeMountPoint;
    m_nvmeUsed = nvmeUsed;
    m_nvmeTotal = nvmeTotal;
    m_nvmePercent = nvmePercent;
    emit storageChanged();
}

void SystemBackend::applyStatusSnapshot(const QVariantMap &snapshot)
{
    if (snapshot.contains(QStringLiteral("wifiName"))) {
        QString wifiName = snapshot.value(QStringLiteral("wifiName")).toString();
        int wifiSignal = qBound(0, snapshot.value(QStringLiteral("wifiSignal"), m_wifiSignal).toInt(), 100);
        QString wifiIpv4 = m_wifiIpv4;
        QString wifiGateway = m_wifiGateway;
        QString wifiMac = m_wifiMac;
        QString wifiDevice = m_wifiDevice;
        if (snapshot.contains(QStringLiteral("wifiIpv4"))) wifiIpv4 = snapshot.value(QStringLiteral("wifiIpv4")).toString();
        if (snapshot.contains(QStringLiteral("wifiGateway"))) wifiGateway = snapshot.value(QStringLiteral("wifiGateway")).toString();
        if (snapshot.contains(QStringLiteral("wifiMac"))) wifiMac = snapshot.value(QStringLiteral("wifiMac")).toString();
        if (snapshot.contains(QStringLiteral("wifiDevice"))) wifiDevice = snapshot.value(QStringLiteral("wifiDevice")).toString();
        if (!wifiName.isEmpty() && wifiSignal == 0 && m_wifiSignal > 0) {
            // Preserve the last valid RSSI during NetworkManager's transient
            // zero/unknown window; a connected network must not flash 0%.
            wifiSignal = m_wifiSignal;
        }
        if (wifiName.isEmpty() && !m_wifiName.isEmpty()) {
            ++m_wifiEmptyPollCount;
            if (m_wifiEmptyPollCount < 2) wifiName = m_wifiName;
            else {
                wifiIpv4.clear();
                wifiGateway.clear();
                wifiSignal = 0;
            }
        } else {
            m_wifiEmptyPollCount = 0;
        }
        if (wifiName != m_wifiName || wifiSignal != m_wifiSignal || wifiIpv4 != m_wifiIpv4 || wifiGateway != m_wifiGateway
                || wifiMac != m_wifiMac || wifiDevice != m_wifiDevice) {
            m_wifiName = wifiName;
            m_wifiSignal = wifiSignal;
            m_wifiIpv4 = wifiIpv4;
            m_wifiGateway = wifiGateway;
            m_wifiMac = wifiMac;
            m_wifiDevice = wifiDevice;
            emit wifiChanged();
        }
    }

    const bool batteryAvailable = snapshot.value(QStringLiteral("batteryAvailable")).toBool();
    const int batteryPercent = snapshot.value(QStringLiteral("batteryPercent"), -1).toInt();
    const QString batteryStatus = snapshot.value(QStringLiteral("batteryStatus")).toString();
    const bool batteryCharging = snapshot.value(QStringLiteral("batteryCharging")).toBool();
    const bool chargerAvailable = snapshot.value(QStringLiteral("chargerAvailable")).toBool();
    const bool externalPowerPresent = snapshot.value(QStringLiteral("externalPowerPresent")).toBool();
    const double batteryTemperatureC = snapshot.value(QStringLiteral("batteryTemperatureC"), -273.15).toDouble();
    const QString chargeTemperatureZone = snapshot.value(QStringLiteral("chargeTemperatureZone")).toString();
    const int batteryRawVoltageMv = snapshot.value(QStringLiteral("batteryRawVoltageMv"), -1).toInt();
    const int batteryRawCurrentMa = snapshot.value(QStringLiteral("batteryRawCurrentMa")).toInt();

    const int batteryVoltageMv = snapshot.value(QStringLiteral("batteryVoltageMv"), -1).toInt();
    const int batteryCurrentMa = snapshot.value(QStringLiteral("batteryCurrentMa")).toInt();
    const QVariantMap management = snapshot.value(QStringLiteral("powerManagement")).toMap();
    const QString lastEvent = management.value(QStringLiteral("lastEvent")).toString();
    const bool newEvent = !lastEvent.isEmpty() && lastEvent != m_lastPowerEvent;
    if (management != m_powerManagement) {
        m_powerManagement = management;
        emit powerChanged();
    }
    if (newEvent) {
        m_lastPowerEvent = lastEvent;
        emit operationMessage(lastEvent, false);
    }

    const int batteryRemainingMah = snapshot.value(QStringLiteral("batteryRemainingMah"), -1).toInt();
    const int batteryFullChargeMah = snapshot.value(QStringLiteral("batteryFullChargeMah"), -1).toInt();
    const int batteryDesignCapacityMah = snapshot.value(QStringLiteral("batteryDesignCapacityMah"), -1).toInt();
    const bool gaugeCommunication = snapshot.value(QStringLiteral("gaugeCommunication")).toBool();
    const QString gaugeError = snapshot.value(QStringLiteral("gaugeError")).toString();
    const QString batteryHealth = snapshot.value(QStringLiteral("batteryHealth")).toString();
    if (batteryAvailable != m_batteryAvailable || batteryPercent != m_batteryPercent
            || batteryStatus != m_batteryStatus || batteryCharging != m_batteryCharging
            || chargerAvailable != m_chargerAvailable || externalPowerPresent != m_externalPowerPresent
            || !qFuzzyCompare(batteryTemperatureC + 274.15, m_batteryTemperatureC + 274.15)
            || chargeTemperatureZone != m_chargeTemperatureZone || batteryVoltageMv != m_batteryVoltageMv
            || batteryCurrentMa != m_batteryCurrentMa || batteryHealth != m_batteryHealth) {
        m_batteryAvailable = batteryAvailable;
        m_batteryPercent = batteryPercent;
        m_batteryStatus = batteryStatus;
        m_batteryCharging = batteryCharging;
        m_chargerAvailable = chargerAvailable;
        m_externalPowerPresent = externalPowerPresent;
        m_batteryTemperatureC = batteryTemperatureC;
        m_chargeTemperatureZone = chargeTemperatureZone;
        m_batteryVoltageMv = batteryVoltageMv;
        m_batteryCurrentMa = batteryCurrentMa;
        m_batteryHealth = batteryHealth;
        emit powerChanged();
    }
    if (batteryRawVoltageMv != m_batteryRawVoltageMv || batteryRawCurrentMa != m_batteryRawCurrentMa
            || batteryRemainingMah != m_batteryRemainingMah || batteryFullChargeMah != m_batteryFullChargeMah
            || batteryDesignCapacityMah != m_batteryDesignCapacityMah
            || gaugeCommunication != m_gaugeCommunication || gaugeError != m_gaugeError) {
        m_batteryRawVoltageMv = batteryRawVoltageMv;
        m_batteryRawCurrentMa = batteryRawCurrentMa;
        m_batteryRemainingMah = batteryRemainingMah;
        m_batteryFullChargeMah = batteryFullChargeMah;
        m_batteryDesignCapacityMah = batteryDesignCapacityMah > 0 ? batteryDesignCapacityMah : -1;
        m_gaugeCommunication = gaugeCommunication;
        m_gaugeError = gaugeError;
        emit powerChanged();
    }

    const int chargerInputLimitMa = snapshot.value(QStringLiteral("chargerInputLimitMa"), -1).toInt();
    const int chargerFastCurrentMa = snapshot.value(QStringLiteral("chargerFastCurrentMa"), -1).toInt();
    if (chargerInputLimitMa != m_chargerInputLimitMa || chargerFastCurrentMa != m_chargerFastCurrentMa) {
        m_chargerInputLimitMa = chargerInputLimitMa;
        m_chargerFastCurrentMa = chargerFastCurrentMa;
        emit powerChanged();
    }

    const int memPercent = snapshot.value(QStringLiteral("memoryPercent"), -1).toInt();
    if (memPercent >= 0 && (memPercent != m_memoryPercent || m_memoryPercent < 0)) {
        m_memoryPercent = memPercent;
        m_memoryUsedBytes = snapshot.value(QStringLiteral("memoryUsedBytes"), 0).toLongLong();
        m_memoryAvailableBytes = snapshot.value(QStringLiteral("memoryAvailableBytes"), 0).toLongLong();
        m_memoryTotalBytes = snapshot.value(QStringLiteral("memoryTotalBytes"), 0).toLongLong();
        emit performanceChanged();
    }

    const int volumePercent = snapshot.value(QStringLiteral("volumePercent"), -1).toInt();
    const bool audioAvailable = snapshot.value(QStringLiteral("audioAvailable")).toBool();
    const bool hasVolume = snapshot.contains(QStringLiteral("volumePercent"));
    if ((hasVolume && volumePercent != m_volumePercent) || audioAvailable != m_audioAvailable) {
        if (hasVolume) m_volumePercent = volumePercent;
        m_audioAvailable = audioAvailable;
        emit audioChanged();
    }

    const QString backlightPath = snapshot.value(QStringLiteral("backlightPath")).toString();
    const int brightnessMax = snapshot.value(QStringLiteral("brightnessMax")).toInt();
    int brightnessPercent = snapshot.value(QStringLiteral("displayBrightnessPercent"), -1).toInt();
    const bool brightnessAvailable = snapshot.value(QStringLiteral("brightnessAvailable")).toBool();
    if (brightnessAvailable && brightnessPercent <= 0 && brightnessMax > 0 && !m_screenSleeping) {
        brightnessPercent = 75;
        setDisplayBrightness(75);
    }
    if (backlightPath != m_backlightPath || brightnessMax != m_brightnessMax
            || brightnessPercent != m_displayBrightnessPercent
            || brightnessAvailable != m_brightnessAvailable) {
        m_backlightPath = backlightPath;
        m_brightnessMax = brightnessMax;
        m_displayBrightnessPercent = brightnessPercent;
        m_brightnessAvailable = brightnessAvailable;
        emit displayChanged();
    }

    const QVariantList ethernetPorts = snapshot.value(QStringLiteral("ethernetPorts")).toList();
    if (snapshot.contains(QStringLiteral("ethernetPorts")) && ethernetPorts != m_ethernetPorts) {
        m_ethernetPorts = ethernetPorts;
        emit ethernetChanged();
    }
}

void SystemBackend::scanWifi()
{
    if (m_wifiScanRunning) return;
    if (!m_wifiScanError.isEmpty()) {
        m_wifiScanError.clear();
        emit wifiChanged();
    }
    m_wifiScanRunning = true;
    const bool accepted = m_runtimeScheduler.trySubmit(meow::TaskPriority::Interactive, [this]() {
        const QVariantMap result = collectWifiNetworks();
        QMetaObject::invokeMethod(this, [this, result]() {
            m_wifiScanRunning = false;
            const QVariantList networks = result.value(QStringLiteral("networks")).toList();
            const QString message = result.value(QStringLiteral("message")).toString();
            if (m_activeScope == QStringLiteral("wifi")) {
                m_wifiNetworks = networks;
                m_wifiScanError = message;
            } else {
                m_pendingWifiNetworks = networks;
                m_pendingWifiScanError = message;
            }
            emit wifiChanged();
            emit schedulerChanged();
            refreshStatus();
        }, Qt::QueuedConnection);
    });
    if (!accepted) {
        m_wifiScanRunning = false;
        m_wifiScanError = QStringLiteral("系统忙，请稍后重试");
    }
    emit wifiChanged();
    emit schedulerChanged();
}

void SystemBackend::connectWifi(const QString &ssid, const QString &password)
{
    if (!m_wifiOperationRunning) {
        m_wifiOperation = QStringLiteral("connect");
        m_wifiOperationSsid = ssid;
        m_wifiOperationRunning = true;
        const bool accepted = m_runtimeScheduler.trySubmit(meow::TaskPriority::Interactive, [this, ssid, password]() {
            const QVariantMap result = runWifiOperation(QStringLiteral("connect"), ssid, password);
            QMetaObject::invokeMethod(this, [this, result]() {
                const bool ok = result.value(QStringLiteral("ok")).toBool();
                m_wifiOperationRunning = false;
                m_wifiOperation.clear();
                m_wifiOperationSsid.clear();
                emit wifiChanged();
                emit schedulerChanged();
                emit operationMessage(result.value(QStringLiteral("message")).toString(), ok);
                refreshStatus();
                scanWifi();
            }, Qt::QueuedConnection);
        });
        if (!accepted) {
            m_wifiOperationRunning = false;
            m_wifiOperation.clear();
            m_wifiOperationSsid.clear();
            emit operationMessage(QStringLiteral("系统忙，请稍后重试"), false);
        }
        emit wifiChanged();
        emit schedulerChanged();
    }
}

void SystemBackend::forgetWifi(const QString &ssid)
{
    if (!m_wifiOperationRunning) {
        m_wifiOperation = QStringLiteral("forget");
        m_wifiOperationSsid = ssid;
        m_wifiOperationRunning = true;
        const bool accepted = m_runtimeScheduler.trySubmit(meow::TaskPriority::Interactive, [this, ssid]() {
            const QVariantMap result = runWifiOperation(QStringLiteral("forget"), ssid, QString());
            QMetaObject::invokeMethod(this, [this, result]() {
                const bool ok = result.value(QStringLiteral("ok")).toBool();
                m_wifiOperationRunning = false;
                m_wifiOperation.clear();
                m_wifiOperationSsid.clear();
                emit wifiChanged();
                emit schedulerChanged();
                emit operationMessage(result.value(QStringLiteral("message")).toString(), ok);
                refreshStatus();
                scanWifi();
            }, Qt::QueuedConnection);
        });
        if (!accepted) {
            m_wifiOperationRunning = false;
            m_wifiOperation.clear();
            m_wifiOperationSsid.clear();
            emit operationMessage(QStringLiteral("系统忙，请稍后重试"), false);
        }
        emit wifiChanged();
        emit schedulerChanged();
    }
}

void SystemBackend::configureEthernet(const QString &interfaceName, const QString &connectionName,
                                      const QString &method, const QString &address, int prefix,
                                      const QString &gateway, const QString &dns)
{
    if (m_ethernetOperationRunning) return;
    m_ethernetOperationInterface = interfaceName;
    m_ethernetOperationRunning = true;
    emit ethernetChanged();
    const bool accepted = m_runtimeScheduler.trySubmit(meow::TaskPriority::Interactive, [this, interfaceName, connectionName, method, address, prefix, gateway, dns]() {
        const QVariantMap result = runEthernetConfiguration(interfaceName, connectionName, method, address, prefix, gateway, dns);
        QMetaObject::invokeMethod(this, [this, result]() {
            const bool ok = result.value(QStringLiteral("ok")).toBool();
            m_ethernetOperationRunning = false;
            m_ethernetOperationInterface.clear();
            emit ethernetChanged();
            emit schedulerChanged();
            emit operationMessage(result.value(QStringLiteral("message")).toString(), ok);
            refreshStatus();
        }, Qt::QueuedConnection);
    });
    if (!accepted) {
        m_ethernetOperationRunning = false;
        m_ethernetOperationInterface.clear();
        emit ethernetChanged();
        emit operationMessage(QStringLiteral("系统忙，请稍后重试"), false);
    }
    emit schedulerChanged();
}

void SystemBackend::setEthernetConnected(const QString &interfaceName, bool connected)
{
    if (m_ethernetOperationRunning) return;
    m_ethernetOperationInterface = interfaceName;
    m_ethernetOperationRunning = true;
    emit ethernetChanged();
    const bool accepted = m_runtimeScheduler.trySubmit(meow::TaskPriority::Interactive, [this, interfaceName, connected]() {
        const QVariantMap result = runEthernetLinkOperation(interfaceName, connected);
        QMetaObject::invokeMethod(this, [this, result]() {
            const bool ok = result.value(QStringLiteral("ok")).toBool();
            m_ethernetOperationRunning = false;
            m_ethernetOperationInterface.clear();
            emit ethernetChanged();
            emit schedulerChanged();
            emit operationMessage(result.value(QStringLiteral("message")).toString(), ok);
            refreshStatus();
        }, Qt::QueuedConnection);
    });
    if (!accepted) {
        m_ethernetOperationRunning = false;
        m_ethernetOperationInterface.clear();
        emit ethernetChanged();
        emit operationMessage(QStringLiteral("系统忙，请稍后重试"), false);
    }
    emit schedulerChanged();
}

void SystemBackend::setVolume(int percent)
{
    m_pendingVolumePercent = qBound(0, percent, 100);
    if (m_volumePercent != m_pendingVolumePercent) {
        m_volumePercent = m_pendingVolumePercent;
        emit audioChanged();
    }
    m_volumeSetTimer.start();
}

void SystemBackend::playVolumeFeedback()
{
    if (!m_audioAvailable) return;
    // Let the debounced mixer write land first, so the feedback is played at
    // the newly selected volume instead of the previous setting.
    QTimer::singleShot(160, this, [this]() {
        if (m_feedbackProcess.state() != QProcess::NotRunning) return;
        m_feedbackProcess.start(QStringLiteral("aplay"),
                                {QStringLiteral("-q"),
                                 QStringLiteral("-D"), QStringLiteral("meow_volume"),
                                 QStringLiteral("/opt/meow-os/assets/sounds/volume-meow.wav")});
    });
}

void SystemBackend::launchMindustry()
{
    if (m_mindustryLaunchFuture.valid()
            && m_mindustryLaunchFuture.wait_for(std::chrono::milliseconds(0))
               != std::future_status::ready) return;
    // systemctl can block while policykit/sudo resolves credentials. Keep it
    // off the Qt GUI thread so a tap always receives immediate feedback.
    m_mindustryLaunchFuture = m_runtimeScheduler.submit(meow::TaskPriority::Interactive, [] {
        const int exitCode = QProcess::execute(QStringLiteral("sudo"),
                                               {QStringLiteral("-n"), QStringLiteral("/bin/systemctl"),
                                                QStringLiteral("start"),
                                                QStringLiteral("meow-mindustry.service")});
        if (exitCode != 0) throw std::runtime_error("mindustry service start failed");
    });
    m_mindustryLaunchPollTimer.start();
    emit operationMessage(QStringLiteral("像素工厂启动请求已提交…"), true);
    emit schedulerChanged();
}

void SystemBackend::launchPvZ()
{
    if (m_pvzLaunchProcess.state() != QProcess::NotRunning) return;
    const QString gameDir = QStringLiteral("/home/radxa/games/pvz");
    if (!QFileInfo(gameDir + QStringLiteral("/pvz-portable")).isExecutable()
            || !QFileInfo::exists(gameDir + QStringLiteral("/main.pak"))
            || !QFileInfo(gameDir + QStringLiteral("/properties")).isDir()) {
        emit operationMessage(QStringLiteral("未找到原生游戏或资源，请先安装 PvZ-Portable"), false);
        return;
    }
    m_pvzLaunchProcess.start(QStringLiteral("sudo"),
                            {QStringLiteral("-n"), QStringLiteral("/bin/systemctl"),
                             QStringLiteral("--no-block"), QStringLiteral("start"),
                             QStringLiteral("meow-pvz.service")});
}

void SystemBackend::setDisplayBrightness(int percent)
{
    m_pendingBrightnessPercent = qBound(10, percent, 100);
    if (m_displayBrightnessPercent != m_pendingBrightnessPercent) {
        m_displayBrightnessPercent = m_pendingBrightnessPercent;
        emit displayChanged();
    }
    m_brightnessSetTimer.start();
}

bool SystemBackend::isScreenSleeping() const
{
    return m_screenSleeping;
}

int SystemBackend::sleepTimeoutSeconds() const
{
    return m_sleepTimeoutSeconds;
}

int SystemBackend::sleepTimeoutIndex() const
{
    if (m_sleepTimeoutSeconds == 30) return 0;
    if (m_sleepTimeoutSeconds == 60) return 1;
    if (m_sleepTimeoutSeconds == 180) return 2;
    if (m_sleepTimeoutSeconds <= 0) return 3;
    return 1;
}

void SystemBackend::setSleepTimeoutSeconds(int seconds)
{
    if (m_sleepTimeoutSeconds == seconds) return;
    m_sleepTimeoutSeconds = seconds;
    QSettings displaySettings(QStringLiteral("Meow OS"), QStringLiteral("display"));
    displaySettings.setValue(QStringLiteral("sleepTimeoutSeconds"), m_sleepTimeoutSeconds);
    emit sleepTimeoutChanged();
}

void SystemBackend::setSleepTimeoutIndex(int index)
{
    int seconds = 60;
    if (index == 0) seconds = 30;
    else if (index == 1) seconds = 60;
    else if (index == 2) seconds = 180;
    else if (index == 3) seconds = 0;
    setSleepTimeoutSeconds(seconds);
}

int SystemBackend::sleepPowerLevel() const
{
    return m_sleepPowerLevel;
}

void SystemBackend::setSleepPowerLevel(int level)
{
    if (m_sleepPowerLevel == level) return;
    m_sleepPowerLevel = level;
    QSettings displaySettings(QStringLiteral("Meow OS"), QStringLiteral("display"));
    displaySettings.setValue(QStringLiteral("sleepPowerLevel"), m_sleepPowerLevel);
    emit sleepPowerLevelChanged();
}

QStringList SystemBackend::keepScreenOnApps() const
{
    return m_keepScreenOnApps;
}

void SystemBackend::setAppKeepScreenOn(const QString &appId, bool enabled)
{
    if (appId.isEmpty()) return;
    bool changed = false;
    if (enabled && !m_keepScreenOnApps.contains(appId)) {
        m_keepScreenOnApps.append(appId);
        changed = true;
    } else if (!enabled && m_keepScreenOnApps.contains(appId)) {
        m_keepScreenOnApps.removeAll(appId);
        changed = true;
    }
    if (changed) {
        QSettings displaySettings(QStringLiteral("Meow OS"), QStringLiteral("display"));
        displaySettings.setValue(QStringLiteral("keepScreenOnApps"), m_keepScreenOnApps);
        emit keepScreenOnAppsChanged();
    }
}

bool SystemBackend::isAppKeepScreenOn(const QString &appId) const
{
    return m_keepScreenOnApps.contains(appId);
}

bool SystemBackend::isWakeLockActive() const
{
    return m_wakeLockActive;
}

void SystemBackend::setWakeLockActive(bool active)
{
    if (m_wakeLockActive == active) return;
    m_wakeLockActive = active;
    emit wakeLockActiveChanged();
}

void SystemBackend::setScreenSleeping(bool sleeping)
{
    if (m_screenSleeping == sleeping) return;
    m_screenSleeping = sleeping;
    if (m_screenSleeping) {
        m_cpuBoostReleaseTimer.stop();
        releaseInteractiveCpuBoost();
        m_brightnessBeforeSleep = m_displayBrightnessPercent > 0 ? m_displayBrightnessPercent : 50;
        if (!m_backlightPath.isEmpty() && m_brightnessMax > 0) {
            QFile brightness(m_backlightPath);
            if (brightness.open(QIODevice::WriteOnly | QIODevice::Text)) {
                brightness.write("0");
                brightness.close();
            }
        }
        m_savedScopeBeforeSleep = m_activeScope;
        m_activeScope = QStringLiteral("sleeping");

        // True System-Level Deep Low-Power Throttling
        if (m_sleepPowerLevel == 1) {
            m_savedCpufreqLimits.clear();
            const QDir cpufreq(QStringLiteral("/sys/devices/system/cpu/cpufreq"));
            const QStringList policies = cpufreq.entryList(
                    {QStringLiteral("policy*")}, QDir::Dirs | QDir::NoDotAndDotDot);
            QStringList policyDirs;
            for (const QString &policy : policies)
                policyDirs.append(cpufreq.absoluteFilePath(policy));
            for (const QString &dirPath : policyDirs) {
                const QString maxFreqPath = dirPath + QStringLiteral("/scaling_max_freq");
                const QByteArray current = readTextFile(maxFreqPath).toLocal8Bit();
                if (!current.isEmpty())
                    m_savedCpufreqLimits.append(qMakePair(maxFreqPath, current));
            }
            // Never lower the policy ceiling unless the exact original values
            // are durable. A service restart during sleep can then recover them.
            if (saveCpuFreqState(kCpuFreqSleepStatePath, m_savedCpufreqLimits)) {
                for (const auto &limit : m_savedCpufreqLimits) {
                    QFile maxFreqFile(limit.first);
                    if (maxFreqFile.open(QIODevice::WriteOnly | QIODevice::Text))
                        maxFreqFile.write("408000\n");
                }
            } else {
                m_savedCpufreqLimits.clear();
            }
        }
    } else {
        // Restore CPU Frequency scaling limits on wake
        for (const auto &pair : m_savedCpufreqLimits) {
            QFile maxFreqFile(pair.first);
            if (maxFreqFile.exists() && maxFreqFile.open(QIODevice::WriteOnly | QIODevice::Text)) {
                maxFreqFile.write(pair.second + "\n");
                maxFreqFile.close();
            }
        }
        m_savedCpufreqLimits.clear();
        QFile::remove(kCpuFreqSleepStatePath);

        if (!m_backlightPath.isEmpty() && m_brightnessMax > 0) {
            const int targetPercent = m_brightnessBeforeSleep > 0 ? m_brightnessBeforeSleep : 50;
            const int level = qBound(1, qRound(m_brightnessMax * targetPercent / 100.0), m_brightnessMax);
            QFile brightness(m_backlightPath);
            if (brightness.open(QIODevice::WriteOnly | QIODevice::Text)) {
                brightness.write(QByteArray::number(level));
                brightness.close();
            }
        }
        m_activeScope = m_savedScopeBeforeSleep.isEmpty() ? QStringLiteral("home") : m_savedScopeBeforeSleep;
        m_idleElapsedTimer.restart();
        refreshStatus();
    }
    emit screenSleepingChanged();
}

void SystemBackend::wakeScreen()
{
    setScreenSleeping(false);
}

bool SystemBackend::calibrateBattery(int referenceVoltageMv, int referenceCurrentMa,
                                     int designCapacityMah, bool stable)
{
    Q_UNUSED(referenceVoltageMv) Q_UNUSED(referenceCurrentMa) Q_UNUSED(designCapacityMah) Q_UNUSED(stable)
    emit operationMessage(QStringLiteral("校准已禁用：旧偏移不再应用，实际电池配置尚未确认"), false);
    return false;
}
bool SystemBackend::rollbackBatteryCalibration()
{
    emit operationMessage(QStringLiteral("旧校准已停用，保留原配置供备份；不应用或回滚偏移"), false);
    return false;
}
void SystemBackend::startCapacityLearning()
{
    m_batteryCapacityLearningStep = 0;
    m_batteryCapacityLearningStatus = QStringLiteral("容量学习已禁用：尚未确认电池实际容量，不进行深放电引导");
    emit powerChanged();
    emit operationMessage(m_batteryCapacityLearningStatus, false);
}
void SystemBackend::advanceCapacityLearning() { startCapacityLearning(); }
void SystemBackend::cancelCapacityLearning() { m_batteryCapacityLearningStep = 0; emit powerChanged(); }
void SystemBackend::clearBatteryCalibration()
{
    emit operationMessage(QStringLiteral("旧校准未应用，原配置保留；不会重置或写入电量计"), false);
}

void SystemBackend::browseDirectory(const QString &requestedPath)
{
    QString path = requestedPath;
    if (path.startsWith(QStringLiteral("file:"))) path = QUrl(path).toLocalFile();
    path = QDir::cleanPath(path);
    if (!QDir(path).isAbsolute()) path = QStringLiteral("/home/radxa");
    if (m_directoryTaskRunning) {
        m_pendingDirectoryPath = path;
        return;
    }
    m_directoryTaskRunning = true;
    m_filesLoading = true;
    m_filesError.clear();
    emit filesChanged();
    const bool accepted = m_runtimeScheduler.trySubmit(meow::TaskPriority::Interactive, [this, path]() {
        const auto deliver = [this](const QVariantMap &result) {
            QMetaObject::invokeMethod(this, [this, result]() {
                m_directoryTaskRunning = false;
                m_fileEntries = result.value(QStringLiteral("entries")).toList();
                m_filePath = result.value(QStringLiteral("path")).toString();
                m_filesError = result.value(QStringLiteral("error")).toString();
                m_filesLoading = false;
                emit filesChanged();
                emit schedulerChanged();
                if (!m_pendingDirectoryPath.isEmpty()) {
                    const QString next = m_pendingDirectoryPath;
                    m_pendingDirectoryPath.clear();
                    browseDirectory(next);
                }
            }, Qt::QueuedConnection);
        };
        QVariantMap result;
        result.insert(QStringLiteral("path"), path);
        QVariantList entries;
        QDir directory(path);
        if (!directory.exists() || !directory.isReadable()) {
            result.insert(QStringLiteral("error"), QStringLiteral("无法读取此位置"));
            result.insert(QStringLiteral("entries"), entries);
            deliver(result);
            return;
        }
        const QFileInfoList files = directory.entryInfoList(
            QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Readable,
            QDir::DirsFirst | QDir::Name | QDir::IgnoreCase);
        const int limit = qMin(files.size(), 1000);
        for (int index = 0; index < limit; ++index) {
            const QFileInfo &info = files.at(index);
            QVariantMap entry;
            entry.insert(QStringLiteral("name"), info.fileName());
            entry.insert(QStringLiteral("path"), info.absoluteFilePath());
            entry.insert(QStringLiteral("directory"), info.isDir());
            entry.insert(QStringLiteral("size"), info.isDir() ? 0 : info.size());
            entry.insert(QStringLiteral("modified"), info.lastModified().toString(QStringLiteral("yyyy-MM-dd HH:mm")));
            entries.append(entry);
        }
        if (files.size() > limit)
            result.insert(QStringLiteral("error"), QStringLiteral("此目录项目过多，仅显示前 1000 项"));
        result.insert(QStringLiteral("entries"), entries);
        deliver(result);
    });
    if (!accepted) {
        m_directoryTaskRunning = false;
        m_filesLoading = false;
        m_filesError = QStringLiteral("系统忙，请稍后重试");
        emit filesChanged();
    }
    emit schedulerChanged();
}

void SystemBackend::previewDocument(const QString &requestedPath)
{
    QString path = requestedPath;
    if (path.startsWith(QStringLiteral("file:"))) path = QUrl(path).toLocalFile();
    path = QDir::cleanPath(path);
    if (m_previewTaskRunning) {
        m_pendingPreviewPath = path;
        return;
    }
    m_previewTaskRunning = true;
    m_previewPath = path;
    m_previewText.clear();
    m_previewError.clear();
    m_previewLoading = true;
    emit previewChanged();
    const bool accepted = m_runtimeScheduler.trySubmit(meow::TaskPriority::Interactive, [this, path]() {
        const auto deliver = [this](const QVariantMap &result) {
            QMetaObject::invokeMethod(this, [this, result]() {
                m_previewTaskRunning = false;
                m_previewPath = result.value(QStringLiteral("path")).toString();
                m_previewText = result.value(QStringLiteral("text")).toString();
                m_previewError = result.value(QStringLiteral("error")).toString();
                m_previewLoading = false;
                emit previewChanged();
                emit schedulerChanged();
                if (!m_pendingPreviewPath.isEmpty()) {
                    const QString next = m_pendingPreviewPath;
                    m_pendingPreviewPath.clear();
                    previewDocument(next);
                }
            }, Qt::QueuedConnection);
        };
        QVariantMap result;
        result.insert(QStringLiteral("path"), path);
        QFile file(path);
        if (!file.open(QIODevice::ReadOnly)) {
            result.insert(QStringLiteral("error"), QStringLiteral("无法读取此文档"));
            deliver(result);
            return;
        }
        const qint64 limit = 256 * 1024;
        QByteArray bytes = file.read(limit + 1);
        if (bytes.contains('\0')) {
            result.insert(QStringLiteral("error"), QStringLiteral("此文件不是可预览的文本文档"));
            deliver(result);
            return;
        }
        const bool truncated = bytes.size() > limit;
        if (truncated) bytes.truncate(limit);
        QString text = QString::fromUtf8(bytes);
        if (text.isNull()) text = QString::fromLocal8Bit(bytes);
        if (truncated) text.append(QStringLiteral("\n\n—— 内容过长，仅预览前 256 KB ——"));
        result.insert(QStringLiteral("text"), text);
        deliver(result);
    });
    if (!accepted) {
        m_previewTaskRunning = false;
        m_previewLoading = false;
        m_previewError = QStringLiteral("系统忙，请稍后重试");
        emit previewChanged();
    }
    emit schedulerChanged();
}

void SystemBackend::addFavoriteLocation(const QString &requestedPath, const QString &requestedLabel)
{
    QString path = QDir::cleanPath(requestedPath);
    if (!QDir(path).isAbsolute() || !QFileInfo(path).isDir()) {
        emit operationMessage(QStringLiteral("无法收藏此位置"), false);
        return;
    }
    for (const QVariant &favorite : m_favoriteLocations) {
        if (favorite.toMap().value(QStringLiteral("path")).toString() == path) {
            emit operationMessage(QStringLiteral("此位置已经收藏"), false);
            return;
        }
    }
    QVariantMap favorite;
    const QString fallback = QFileInfo(path).fileName().isEmpty() ? QStringLiteral("系统盘")
                                                                   : QFileInfo(path).fileName();
    favorite.insert(QStringLiteral("path"), path);
    favorite.insert(QStringLiteral("label"), requestedLabel.trimmed().isEmpty() ? fallback
                                                                                  : requestedLabel.trimmed());
    m_favoriteLocations.append(favorite);
    QSettings(QStringLiteral("Meow OS"), QStringLiteral("files"))
            .setValue(QStringLiteral("favorites"), m_favoriteLocations);
    emit favoritesChanged();
    emit operationMessage(QStringLiteral("已加入收藏"), true);
}

void SystemBackend::removeFavoriteLocation(const QString &requestedPath)
{
    const QString path = QDir::cleanPath(requestedPath);
    for (int index = 0; index < m_favoriteLocations.size(); ++index) {
        if (m_favoriteLocations.at(index).toMap().value(QStringLiteral("path")).toString() != path)
            continue;
        m_favoriteLocations.removeAt(index);
        QSettings(QStringLiteral("Meow OS"), QStringLiteral("files"))
                .setValue(QStringLiteral("favorites"), m_favoriteLocations);
        emit favoritesChanged();
        emit operationMessage(QStringLiteral("已移除收藏"), true);
        return;
    }
}

void SystemBackend::transferFile(const QString &requestedSource, const QString &requestedDestination,
                                 bool move)
{
    if (m_fileOperationRunning) return;
    const QString source = QDir::cleanPath(requestedSource);
    const QString destinationDirectory = QDir::cleanPath(requestedDestination);
    if (!isUserFilePath(source) || !isUserFilePath(destinationDirectory)
            || source == QStringLiteral("/home/radxa") || source == QStringLiteral("/data")
            || !QFileInfo::exists(source) || !QFileInfo(destinationDirectory).isDir()) {
        emit operationMessage(QStringLiteral("只能在用户目录和数据盘内复制或移动"), false);
        return;
    }
    if (destinationDirectory == source || destinationDirectory.startsWith(source + QLatin1Char('/'))) {
        emit operationMessage(QStringLiteral("不能粘贴到项目自身内部"), false);
        return;
    }
    m_fileOperationRunning = true;
    m_fileOperationText = move ? QStringLiteral("正在移动…") : QStringLiteral("正在复制…");
    emit fileOperationChanged();
    const bool accepted = m_runtimeScheduler.trySubmit(meow::TaskPriority::Interactive, [this, source, destinationDirectory, move]() {
        const auto deliver = [this](const QVariantMap &result) {
            QMetaObject::invokeMethod(this, [this, result]() {
                const bool ok = result.value(QStringLiteral("ok")).toBool();
                m_fileOperationRunning = false;
                m_fileOperationText.clear();
                emit fileOperationChanged();
                emit schedulerChanged();
                emit operationMessage(result.value(QStringLiteral("message")).toString(), ok);
                if (!m_filePath.isEmpty()) browseDirectory(m_filePath);
            }, Qt::QueuedConnection);
        };
        QVariantMap result;
        const QString destination = availableDestination(destinationDirectory, QFileInfo(source).fileName());
        if (destination.isEmpty()) {
            result.insert(QStringLiteral("ok"), false);
            result.insert(QStringLiteral("message"), QStringLiteral("无法生成目标名称"));
            deliver(result);
            return;
        }
        if (move && QFile::rename(source, destination)) {
            result.insert(QStringLiteral("ok"), true);
            result.insert(QStringLiteral("message"), QStringLiteral("移动完成"));
            deliver(result);
            return;
        }
        QString error;
        if (!copyFileTree(source, destination, &error)) {
            QFileInfo(destination).isDir() ? QDir(destination).removeRecursively() : QFile::remove(destination);
            result.insert(QStringLiteral("ok"), false);
            result.insert(QStringLiteral("message"), error);
            deliver(result);
            return;
        }
        if (move) {
            const bool removed = QFileInfo(source).isDir() ? QDir(source).removeRecursively()
                                                           : QFile::remove(source);
            if (!removed) {
                result.insert(QStringLiteral("ok"), false);
                result.insert(QStringLiteral("message"), QStringLiteral("已复制，但无法删除原项目"));
                deliver(result);
                return;
            }
        }
        result.insert(QStringLiteral("ok"), true);
        result.insert(QStringLiteral("message"), move ? QStringLiteral("移动完成")
                                                       : QStringLiteral("复制完成"));
        deliver(result);
    });
    if (!accepted) {
        m_fileOperationRunning = false;
        m_fileOperationText.clear();
        emit fileOperationChanged();
        emit operationMessage(QStringLiteral("系统忙，请稍后重试"), false);
    }
    emit schedulerChanged();
}

void SystemBackend::saveAppData(const QString &key, const QString &data)
{
    QSettings settings(QStringLiteral("Meow OS"), QStringLiteral("apps"));
    settings.setValue(key, data);
}

QString SystemBackend::loadAppData(const QString &key, const QString &defaultValue) const
{
    QSettings settings(QStringLiteral("Meow OS"), QStringLiteral("apps"));
    return settings.value(key, defaultValue).toString();
}
