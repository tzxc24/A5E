#ifndef POWER_SNAPSHOT_READER_H
#define POWER_SNAPSHOT_READER_H
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QVariantMap>
#include <cmath>
namespace PowerSnapshot {
inline QVariantMap invalid(const QString &reason) {
 QVariantMap pm{{"available",false},{"fresh",false},{"status","sensor-error"},{"message",reason},{"error",reason},{"socConfidence","unavailable"},{"currentValid",false},{"voltageValid",false},{"externalPowerKnown",false},{"temperatureSource",QString()},{"boardTemperatureC",-273.15},{"lowBattery",false},{"lastEvent",QString()},{"events",QStringList()},{"sampleAgeSeconds",-1.0}};
 return {{"batteryAvailable",false},{"batteryPercent",-1},{"batteryStatus","Unknown"},{"batteryCharging",false},{"chargerAvailable",false},{"externalPowerPresent",false},{"batteryTemperatureC",-273.15},{"chargeTemperatureZone",QString()},{"batteryVoltageMv",-1},{"batteryCurrentMa",0},{"batteryRawVoltageMv",-1},{"batteryRawCurrentMa",0},{"batteryRemainingMah",-1},{"batteryFullChargeMah",-1},{"batteryDesignCapacityMah",-1},{"batteryHealth","Unknown"},{"chargerInputLimitMa",-1},{"chargerFastCurrentMa",-1},{"gaugeCommunication",false},{"gaugeError",reason},{"powerManagement",pm}};
}
inline QVariantMap parse(const QByteArray &data,const QString &bootId,double uptime) {
 QJsonParseError error; const auto doc=QJsonDocument::fromJson(data,&error);
 if(error.error!=QJsonParseError::NoError || !doc.isObject()) return invalid(QStringLiteral("电源服务快照损坏"));
 const auto obj=doc.object();
 if(obj.value("schemaVersion").toInt(-1)!=1) return invalid(QStringLiteral("电源服务快照版本不兼容"));
 if(bootId.isEmpty() || uptime<0 || !std::isfinite(uptime)) return invalid(QStringLiteral("无法校验本次启动与运行时间"));
 if(obj.value("bootId").toString()!=bootId) return invalid(QStringLiteral("电源服务快照来自其他启动"));
 if(!obj.value("sampleUptimeSeconds").isDouble()) return invalid(QStringLiteral("电源服务快照缺少采样时间"));
 const double age=uptime-obj.value("sampleUptimeSeconds").toDouble();
 if(!std::isfinite(age) || age<0 || age>6) return invalid(QStringLiteral("电源服务快照过期或时间异常"));
 if(!obj.value("powerManagement").isObject()) return invalid(QStringLiteral("电源服务快照缺少保护状态"));
 QVariantMap result=invalid(QString()); const auto incoming=obj.toVariantMap();
 for(auto it=incoming.cbegin();it!=incoming.cend();++it) result.insert(it.key(),it.value());
 QVariantMap pm=result.value("powerManagement").toMap();
 // A missing or mistyped channel must never become a plausible zero watt reading.
 if (!obj.value("batteryCurrentMa").isDouble() || !obj.value("batteryRawCurrentMa").isDouble()) pm.insert("currentValid", false);
 if (!obj.value("batteryVoltageMv").isDouble() || obj.value("batteryVoltageMv").toDouble() <= 0) pm.insert("voltageValid", false);
 const int percent = obj.value("batteryPercent").toInt(-1);
 if (percent < 0 || percent > 100) result.insert("batteryPercent", -1);
 pm.insert("fresh",true);pm.insert("sampleAgeSeconds",age);pm.insert("error",QString());
 result.insert("powerManagement",pm);
 return result;
}
inline QVariantMap read() {
 QFile state(QStringLiteral("/run/meow-power/state.json"));
 if(!state.open(QIODevice::ReadOnly)) return invalid(QStringLiteral("电源后台服务离线，无法读取快照"));
 QFile boot(QStringLiteral("/proc/sys/kernel/random/boot_id")),clock(QStringLiteral("/proc/uptime"));
 if(!boot.open(QIODevice::ReadOnly)||!clock.open(QIODevice::ReadOnly)) return invalid(QStringLiteral("无法校验电源服务快照"));
 bool ok=false;const double uptime=clock.readAll().split(' ').value(0).toDouble(&ok);
 return parse(state.readAll(),QString::fromUtf8(boot.readAll()).trimmed(),ok?uptime:-1);
}
}
#endif
