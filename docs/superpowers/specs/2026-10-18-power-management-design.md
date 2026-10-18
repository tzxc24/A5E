# 软件电源管理重构

用户已选择完整重构：正确采集与可信度、取消2.4A自动写入、独立温控与低电提示、桌面与游戏切换验证。范围为软件，不改电池OTP、容量配置、充电电压/电流或内核保护。

## 数据与接口

独立Python3标准库服务每2秒采样，原子写入`/run/meow-power/state.json`。Qt只读取该快照，不再直接访问电池I2C，也不套用旧软件校准偏移。

根字段：`schemaVersion=1`、`bootId`（/proc/sys/kernel/random/boot_id）、`sampleUptimeSeconds`（/proc/uptime）、`batteryAvailable`、`gaugeCommunication`、`gaugeError`、`batteryPercent`(-1未知)、`batteryStatus`(Charging/Discharging/Full/Not charging/Unknown)、`batteryCharging`、`chargerAvailable`、`externalPowerPresent`、`batteryTemperatureC`(-273.15未知)、`chargeTemperatureZone`、`batteryVoltageMv`(-1未知)、`batteryCurrentMa`(有符号)、`batteryRawVoltageMv`、`batteryRawCurrentMa`、`batteryRemainingMah`、`batteryFullChargeMah`、`batteryDesignCapacityMah`(后三者-1未知)、`batteryHealth`(Unknown/需检查)、`chargerInputLimitMa`、`chargerFastCurrentMa`。

附加`powerManagement`对象：`available`、`status`(normal/warm/throttled/cooldown/sensor-error)、`message`(中文用户提示)、`socConfidence`(unverified/inconsistent/unavailable)、`currentValid`、`voltageValid`、`externalPowerKnown`、`temperatureSource`、`boardTemperatureC`(-273.15未知)、`lowBattery`、`lastEvent`、`events`(最近事件字符串数组)。未确认物理电池配置，所以SOC只标为电量计估算；不通过电压曲线编造百分比。

BQ27220只读寄存器：Temp06、Voltage08、Flags0A、Current0C、Remaining10、Full12、Average14、SOC2C、SOH2E、Operation3A、Design3C；容量/状态范围检查，SOC与RM/FCC误差>2个百分点标异常。电流正充负放，死区50mA。SGM41511先只读ID0B，再读00/02/08/09；故障快照保留，不写寄存器。外部电源采用SGM输入有效状态，AXP USB online不作为Type-C证据；传感器缺失/冲突显示未知，不猜测。

Qt读取时校验schema/bootId/uptime年龄0..6秒。过期/损坏/服务离线显示未知和原因，不保留旧电量。`powerManagement`作为Q_PROPERTY QVariantMap提供给QML；现有公开属性保持兼容。功率在电流/电压无效时返回未知。

## 独立保护

服务不依赖meow-os，游戏期间持续运行。只对CPU/GPU/DDR具名thermal_zone取最高温度，不把电量计内部温度当作电芯表面温度。

默认温度策略为可配置的软件保守阈值，非芯片额定指标：75℃提示；80℃持续4秒限制CPU最高1008000kHz（不提高已有较低限制）；85℃持续4秒停止meow-pvz.service及meow-mindustry.service并记录中文过热提示；降至75℃以下持续30秒才恢复/解锁。若游戏被过热停止，仍由原单元ExecStopPost恢复桌面。拒绝在cooldown或温度>=85℃时启动游戏。内核温控、充电NTC和安全定时器不变。

CPU原始上限按bootId保存在root所有的状态文件；服务重启继续恢复流程，不覆盖首次快照。恢复时只恢复仍等于本服务设置的上限，避免覆盖其他管理者的改动；失败保留记录并报告。热态停服务不提高频率；重启后不使用上一boot的快照。

审查补充：Qt不再直接写CPU最小/最大频率，包括交互boost和睡眠恢复。深度息屏仅写`/run/meow-os/screen-sleeping`标志，由电源服务统一施加408000kHz上限；醒来时与热限制取更保守值，保留最初正常上限直至恢复。旧启动恢复脚本在新服务安装后不再回放旧max，仅允许降低遗留boost min。过热退出请求必须在发布冷却快照后非阻塞排队，不能阻塞温度采样30秒。

低电量：仅负电流有效且电压<=3400mV连续10秒，或SOC可信（此版不会宣称已确认容量）<=15%时提醒；不按未经确认的SOC执行自动关机，不强迫深放电。

策略模块必须接受模拟时间与温度，硬件写入/停止服务由执行器完成；单元测试禁止调用实机shutdown、写充电器或真实过热。

## 界面与迁移

电池页显示电量估算可信度、原始电压电流、RM/FCC/设计容量（标为电量计配置而非电池标签容量）、充电器输入状态、温度来源、后台状态与事件。移除假容量学习、默认10000mAh、默认2.4A与未经证实的健康Good；旧校准配置保留备份但不再自动应用。旧校准/学习API可保留兼容禁用返回，不允许假成功。

后台通知在桌面可见，过热关闭游戏后解释原因。游戏启动预检要求电源快照新鲜并允许启动。

## 验证与限制

测试寄存器映射、有符号电流、无效读数、充电/放电冲突、阈值持续与滞回、CPU快照恢复、失败恢复、陈旧快照拒绝启动。电脑Qt构建和板卡单核构建；实机只采样正常温度，证明游戏/桌面切换不停止电源服务。备份二进制和服务后部署，保留回滚方案。

软件保护无法替代散热与电源硬件，也不能承诺消除所有整机复位。充电限流实物参数和电池实际容量仍未确认。
