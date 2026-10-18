#include "../src/power_snapshot_reader.h"
#include <QCoreApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <cstdio>
int main(int argc, char **argv) {
 QCoreApplication app(argc, argv);
 QJsonObject pm{{"available",true},{"currentValid",true},{"voltageValid",true},{"externalPowerKnown",true},{"status","normal"}};
 QJsonObject obj{{"schemaVersion",1},{"bootId","boot"},{"sampleUptimeSeconds",100.0},{"batteryAvailable",true},{"batteryPercent",53},{"batteryVoltageMv",3800},{"batteryCurrentMa",-400},{"batteryRawCurrentMa",-400},{"powerManagement",pm}};
 int failures=0;
 auto check=[&](bool value,const char *name){if(!value){std::fprintf(stderr,"FAIL %s\n",name);++failures;}};
 auto read=[&](double now){return PowerSnapshot::parse(QJsonDocument(obj).toJson(),"boot",now);};
 check(read(100).value("batteryPercent").toInt()==53,"age zero");
 check(read(106).value("powerManagement").toMap().value("fresh").toBool(),"age six");
 for(double now: {99.0,106.1}) { auto r=read(now); check(!r.value("batteryAvailable").toBool() && r.value("batteryPercent").toInt()==-1 && !r.value("gaugeError").toString().isEmpty(),"stale clears telemetry"); }
 check(!PowerSnapshot::parse(QJsonDocument(obj).toJson(),"other",102).value("batteryAvailable").toBool(),"boot mismatch");
 obj["schemaVersion"]=2; check(!read(102).value("batteryAvailable").toBool(),"schema mismatch");obj["schemaVersion"]=1;
 check(!PowerSnapshot::parse("broken","boot",102).value("batteryAvailable").toBool(),"malformed JSON");
 obj.remove("batteryCurrentMa");check(!read(102).value("powerManagement").toMap().value("currentValid").toBool(),"missing current cannot claim valid");
 obj["batteryPercent"]=150;check(read(102).value("batteryPercent").toInt()==-1,"invalid percent is unknown");
 obj.remove("sampleUptimeSeconds");check(!read(102).value("batteryAvailable").toBool(),"missing timestamp");
 check(!PowerSnapshot::parse("{}","",-1).value("batteryAvailable").toBool(),"clock unavailable");
 return failures?1:0;
}
