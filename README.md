# Meow OS

一个面向 Radxa Cubie A5E 的轻量 Qt Quick 设备系统。第一版将显示、触摸、开机界面、系统设置和背板硬件服务固定下来，应用层可以继续扩展。

## 当前能力

- 1280×800 原生横屏 Qt Quick UI，逆时针 90° 映射到 800×1280 物理面板
- A5E Mali-G57/Panfrost + EGLFS 硬件渲染，保留 Linux framebuffer 软件回退
- JD9366T + Linux evdev/libinput 触摸输入
- 读取并调节真实 PWM 背光亮度，设置页限制最低 10% 防止黑屏
- 无动画的圆形 MeowKJ 头像启动画面与“关于本机”资料卡
- 模型驱动的可扩展应用主页、点击测试、离线“喵喵反应”小游戏、双栏系统设置
- 不可触摸的系统状态栏与紧凑返回组件
- NetworkManager Wi-Fi 扫描、连接、忘记网络、信号/信道/频段/速率显示与 iPadOS 风格英文触摸键盘（两级数字/符号页）
- 为设备用户配置最小化 NetworkManager 授权；扫描和连接失败会显示可执行的中文原因
- Wi-Fi 连接/忘记期间显示阻断式进度提示；已保存网络可长按重新输入密码或忘记
- 双有线网口状态页：分别显示 eth0/eth1 的链路、地址、协商速率、双工、MAC 与 MTU
- 系统盘与 NVMe 的真实容量、挂载状态和 macOS 风格彩色使用量条
- 非阻塞电池状态采集：电量、精确温度、充电安全温区与外部电源状态
- 通用硬件能力探测：A5E 现有 profile 与未绑定具体板卡的 A733 capability profile
- BQ27220 只读诊断与 1S/4.2V/10000mAh 两点校准记录；未确认手册命令前不写电量计数据区
- 电池共享I²C使用100kHz engine mode，兼容电量计的时钟拉伸
- “隔空喵传”入口、A5E I²S 内置扬声器设备树覆盖层、ALSA 软件音量与短促猫咪提示音
- 设置页按需创建并缓存；性能采样只在性能页前台运行，Wi-Fi、音量与硬件状态查询均在工作线程执行
- 本地打包的 Lucide SVG 图标
- systemd 图形模式启动、关闭 tty 光标

完整产品目标、页面结构、硬件数据边界和验收标准见 [docs/MEOW_OS_DESIGN.md](docs/MEOW_OS_DESIGN.md)。

## 构建

在 A5E Debian 11 上安装 Qt 5 开发包后：

```sh
qmake meow-os.pro
make -j2
./build/meow-os
```

`MEOW_QPA_PLATFORM` 可覆盖显示后端：`linuxfb:fb=/dev/fb0`、`eglfs`、`wayland` 或 `xcb`。

主页打开“喵喵反应”即可开始一局 30 秒的触摸测试游戏：点击随机出现的绿色喵爪累计得分，结束后显示本轮和历史最佳分数；游戏不依赖网络，也不会启动后台采样任务。

## 内置草坪塔防小游戏

桌面点击“植物大战僵尸”启动独立的 PvZ-Portable 社区开源引擎，
或运行 `meow-os --pvz`。引擎位置为 `/home/radxa/games/pvz/pvz-portable`，
游戏所有者需在同目录提供 GOTY 资源 `main.pak` 和 `properties/`。
游戏通过 `meow-pvz.service` 独占 X11 会话，退出后恢复 MeowOS 桌面。
提供会话内的触摸转鼠标适配、左旋横屏、屏幕键盘入口和原生存档。
存档沿用 `~/.local/share/io.github.wszqkzqk/PvZPortable/`。
旧 QML 小游戏源码保留用于回归和回退，桌面入口已切换到原生游戏。

测试：`python3 tools/test-pvz-launcher.py`、`python3 tools/test-pvz-touch.py`；
旧 QML 游戏回归：`qmltestrunner -input tools/qml-tests`。
Windows 可编译桌面，原生游戏入口需要目标 Linux 的游戏资源和服务。

## 版本更新规则

每次功能或界面更新前先递增版本号：

```sh
./scripts/bump-version patch
```

也可使用 `minor`、`major` 或明确的三段式版本号。正式安装会比较源码指纹与设备上一次安装的指纹；源码发生变化但版本号未递增时，部署会直接失败。

内部质量报告：

```sh
./scripts/quality-gate.sh
```

开发完成一轮修改后，先递增版本并通过 `./scripts/test.sh`，随后创建一个独立 Git 提交。提交默认保留在本地；推送 GitHub 或发布 Release 需要单独执行。

## 项目边界

仓库只保存 Meow OS 层的代码、启动配置和镜像装配脚本。Radxa 内核、U-Boot 和芯片厂商驱动仍由上游发行版提供；A5E 的 WX101/JD9366T 覆盖层及 Jadard 模块作为板级 profile 注入，不把供应商内核树复制进仓库。

## 许可

本仓库代码使用 MIT。Lucide 图标声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)；Radxa、Qt、字体和面板厂商文件分别遵循其原始许可。
