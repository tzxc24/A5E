import QtQuick 2.15
import QtQuick.Window 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import "components"
import "apps"

ApplicationWindow {
    id: window
    visible: true
    width: uiRotation === 0 ? 1280 : 800
    height: uiRotation === 0 ? 800 : 1280
    title: "Meow OS"
    color: "#000000"

    property int uiRotation: systemBackend.displayRotation
    property int statusBarHeight: 50
    property color canvas: "#F5F4F8"
    property color card: "#FFFFFF"
    property color ink: "#27222D"
    property color secondary: "#77717D"
    property color separator: "#E7E3EA"
    property color pink: "#FF7FA7"
    property color purple: "#7B6DF0"
    property color mint: "#49B990"
    property string uiFont: "Noto Sans CJK SC"
    property int tapCount: 0
    property string operationText: ""
    property bool operationSuccess: true
    property var passwordDialog: passwordDialog
    property var ethernetDialog: ethernetDialog
    property bool screenDimmed: false
    property double pendingUiFrameStartedAt: 0
    property string pendingUiFrameSection: ""
    readonly property bool settingsForeground: stack.currentItem
                                               && (stack.currentItem.objectName === "settings"
                                                   || stack.currentItem.objectName === "meow-settings-page")
    property int brightnessBeforeDim: -1
    property int idleDimDelayMs: 90000
    property string lastSettingsSection: initialSettingsSection
    property string initialSettingsSection: Qt.application.arguments.indexOf("--ethernet") >= 0
                                            || Qt.application.arguments.indexOf("--ethernet-config") >= 0
                                            ? "ethernet"
                                            : (Qt.application.arguments.indexOf("--wifi") >= 0
                                            || Qt.application.arguments.indexOf("--wifi-keyboard") >= 0
                                            || Qt.application.arguments.indexOf("--wifi-keyboard-symbols") >= 0
                                            ? "wifi"
                                            : (Qt.application.arguments.indexOf("--performance") >= 0
                                               ? "performance"
                                            : (Qt.application.arguments.indexOf("--sound") >= 0
                                               ? "sound"
                                            : (Qt.application.arguments.indexOf("--display") >= 0
                                               || Qt.application.arguments.indexOf("--display-scroll") >= 0
                                               ? "display"
                                               : (Qt.application.arguments.indexOf("--storage") >= 0 ? "storage" : "battery")))))
    property bool startInSettings: Qt.application.arguments.indexOf("--settings") >= 0
                                   || Qt.application.arguments.indexOf("--sound") >= 0
                                   || Qt.application.arguments.indexOf("--display") >= 0
                                   || Qt.application.arguments.indexOf("--display-scroll") >= 0
                                   || Qt.application.arguments.indexOf("--storage") >= 0
                                   || Qt.application.arguments.indexOf("--wifi") >= 0
                                   || Qt.application.arguments.indexOf("--wifi-keyboard") >= 0
                                   || Qt.application.arguments.indexOf("--wifi-keyboard-symbols") >= 0
                                   || Qt.application.arguments.indexOf("--performance") >= 0
                                   || Qt.application.arguments.indexOf("--ethernet") >= 0
                                   || Qt.application.arguments.indexOf("--ethernet-config") >= 0
    readonly property bool startInFiles: Qt.application.arguments.indexOf("--files") >= 0
                                         || Qt.application.arguments.indexOf("--qa-file-copy") >= 0
                                         || Qt.application.arguments.indexOf("--qa-file-move") >= 0
    readonly property bool qaFileCopy: Qt.application.arguments.indexOf("--qa-file-copy") >= 0
    readonly property bool qaFileMove: Qt.application.arguments.indexOf("--qa-file-move") >= 0
    readonly property bool startInMindustry: Qt.application.arguments.indexOf("--mindustry") >= 0
    readonly property bool settingsQaMetrics: Qt.application.arguments.indexOf("--qa") >= 0
    readonly property bool settingsQaSwitch: Qt.application.arguments.indexOf("--qa-switch") >= 0

    property var cachedTouchTest: null
    property var cachedReactionGame: null
    property var cachedFileManager: null
    property var cachedSettings: null

    function getAppObject(appId) {
        if (appId === "touch-test") {
            if (!cachedTouchTest || !cachedTouchTest.parent) {
                cachedTouchTest = touchTestComponent.createObject(stack)
                if (cachedTouchTest) cachedTouchTest.StackView.destroyOnPop = true
            }
            return cachedTouchTest
        } else if (appId === "reaction-game") {
            if (!cachedReactionGame || !cachedReactionGame.parent) {
                cachedReactionGame = reactionGameComponent.createObject(stack)
                if (cachedReactionGame) cachedReactionGame.StackView.destroyOnPop = true
            }
            return cachedReactionGame
        } else if (appId === "files") {
            if (!cachedFileManager || !cachedFileManager.parent) {
                cachedFileManager = fileManagerComponent.createObject(stack)
                if (cachedFileManager) cachedFileManager.StackView.destroyOnPop = true
            }
            return cachedFileManager
        } else if (appId === "settings") {
            if (!cachedSettings || !cachedSettings.parent) {
                cachedSettings = settingsComponent.createObject(stack)
                // Settings owns expensive page trees. Keep them dormant after
                // pop; page timers are foreground-gated, so caching does not
                // retain background sampling or power use.
                if (cachedSettings) cachedSettings.StackView.destroyOnPop = false
            }
            return cachedSettings
        }
        return null
    }

    function openApp(appId, immediate) {
        if (appId === "pvz") { systemBackend.launchPvZ(); return }
        if (stack.depth > 1) {
            window.showOperationMessage("已有应用正在运行，请先退出", false)
            return
        }
        systemBackend.boostInteractivePerformance()
        if (!systemBackend.beginForegroundApp(appId)) {
            window.showOperationMessage("应用会话启动失败", false)
            return
        }
        var appObj = getAppObject(appId)
        if (appObj) {
            appObj.visible = true
            if (immediate) stack.push(appObj, StackView.Immediate)
            else stack.push(appObj)
        } else {
            systemBackend.endForegroundApp(appId)
        }
    }

    function closeForegroundApp() {
        var appId = stack.currentItem ? stack.currentItem.objectName : ""
        if (stack.depth > 1) stack.pop()
        if (appId.length) systemBackend.endForegroundApp(appId)
    }

    function measureNextUiFrame(sectionName, startedAt) {
        pendingUiFrameSection = sectionName
        pendingUiFrameStartedAt = startedAt
    }

    onFrameSwapped: {
        if (pendingUiFrameStartedAt <= 0) return
        var completedItem = stack.currentItem
        if (settingsQaMetrics)
            console.log("[MeowOS] settings-frame", pendingUiFrameSection,
                        Date.now() - pendingUiFrameStartedAt, "ms")
        pendingUiFrameStartedAt = 0
        pendingUiFrameSection = ""
        if (completedItem && completedItem.uiFrameCompleted)
            completedItem.uiFrameCompleted()
    }

    function launchMindustryDirect() {
        systemBackend.launchMindustry()
    }

    function checkIdleState() {
        if (systemBackend.screenSleeping) return

        // App-level Keep Screen On / Wake Lock Check
        var currentAppId = stack.currentItem ? stack.currentItem.objectName : ""
        if (systemBackend.wakeLockActive || (currentAppId.length > 0 && systemBackend.isAppKeepScreenOn(currentAppId))) {
            return
        }

        if (systemBackend.sleepTimeoutSeconds > 0) {
            if (systemBackend.idleMs() >= systemBackend.sleepTimeoutSeconds * 1000) {
                systemBackend.setScreenSleeping(true)
                return
            }
        }
        if (screenDimmed) {
            if (systemBackend.idleMs() < 3000) restoreBrightness()
            return
        }
        if (systemBackend.idleMs() > idleDimDelayMs) dimScreen()
    }

    function dimScreen() {
        if (screenDimmed || !systemBackend.brightnessAvailable) return
        screenDimmed = true
        brightnessBeforeDim = systemBackend.displayBrightnessPercent >= 0 ? systemBackend.displayBrightnessPercent : 30
        systemBackend.setActiveScope("idle")
        systemBackend.setDisplayBrightness(30)
    }

    function restoreBrightness() {
        if (!screenDimmed) return
        screenDimmed = false
        if (brightnessBeforeDim > 0) systemBackend.setDisplayBrightness(brightnessBeforeDim)
        brightnessBeforeDim = -1
        systemBackend.setActiveScope(lastSettingsSection.length ? lastSettingsSection : "home")
    }

    function batteryStateText(status) {
        if (status === "Charging") return "正在充电"
        if (status === "Discharging") return "正在使用电池"
        if (status === "Full") return "已充满"
        if (status === "Not charging") return "已暂停充电"
        return status.length ? status : "无法读取"
    }

    function temperatureZoneText(zone) {
        if (zone === "cold") return "过冷"
        if (zone === "cool") return "偏冷"
        if (zone === "normal") return "正常"
        if (zone === "warm") return "偏热"
        if (zone === "hot") return "过热"
        return "等待驱动"
    }

    function wifiSignalColor(signal) {
        if (signal >= 70) return "#10B981"
        if (signal >= 40) return "#F59E0B"
        return "#EF4444"
    }

    function batteryPowerLabel() {
        if (!systemBackend.batteryAvailable || systemBackend.batteryPowerW < 0) return "--"
        var sign = systemBackend.batteryCharging ? "+" : (systemBackend.batteryCurrentMa < 0 || systemBackend.batteryStatus === "Discharging" ? "−" : "")
        return sign + systemBackend.batteryPowerW.toFixed(1) + " W"
    }

    function batteryPowerColor() {
        if (!systemBackend.batteryAvailable || systemBackend.batteryPowerW < 0) return "#8E8993"
        var watts = systemBackend.batteryPowerW
        if (systemBackend.batteryCharging) {
            if (watts >= 8) return "#248A3D"
            if (watts >= 3) return "#34C759"
            return "#5AC8A0"
        }
        if (systemBackend.batteryStatus === "Full") return "#34C759"
        if (watts >= 6) return "#FF3B30"
        if (watts >= 3) return "#FF9F0A"
        if (systemBackend.batteryPercent >= 0 && systemBackend.batteryPercent <= 20) return "#FF3B30"
        if (systemBackend.batteryPercent >= 0 && systemBackend.batteryPercent <= 40) return "#FFCC00"
        return "#6F6A74"
    }

    function batteryFillColor() {
        if (systemBackend.batteryCharging) return "#34C759"
        if (systemBackend.batteryPercent >= 0 && systemBackend.batteryPercent <= 20) return "#FF3B30"
        if (systemBackend.batteryPercent >= 0 && systemBackend.batteryPercent <= 40) return "#FFCC00"
        if (systemBackend.batteryStatus === "Discharging" && systemBackend.batteryPowerW >= 6) return "#FF3B30"
        if (systemBackend.batteryStatus === "Discharging" && systemBackend.batteryPowerW >= 3) return "#FF9F0A"
        return "#4B4650"
    }

    function batteryOutlineColor() {
        if (systemBackend.batteryCharging) return "#34C759"
        if (systemBackend.batteryPercent >= 0 && systemBackend.batteryPercent <= 20) return "#FF3B30"
        if (systemBackend.batteryPercent >= 0 && systemBackend.batteryPercent <= 40) return "#FFCC00"
        if (systemBackend.batteryStatus === "Discharging" && systemBackend.batteryPowerW >= 3) return batteryPowerColor()
        return "#C7C7CC"
    }

    function ethernetDuplexText(duplex) {
        if (duplex === "full") return "全双工"
        if (duplex === "half") return "半双工"
        return "--"
    }

    function wifiDetailText(n) {
        if (!n) return ""
        var parts = []
        if (n.band && String(n.band).length) parts.push(n.band)
        if (n.channel && n.channel > 0) parts.push("信道 " + n.channel)
        if (n.security && String(n.security).length) parts.push(n.security)
        return parts.join(" · ")
    }

    ListModel {
        id: appRegistry
        ListElement { appId: "reaction-game"; appTitle: "喵喵反应"; iconSource: "qrc:/assets/icons/zap-white.svg"; accent: "#F59E0B" }
        ListElement { appId: "touch-test"; appTitle: "点击测试"; iconSource: "qrc:/assets/icons/mouse-pointer-click.svg"; accent: "#FF4D6D" }
        ListElement { appId: "files"; appTitle: "文件"; iconSource: "qrc:/assets/icons/folder.svg"; accent: "#3B82F6" }
        ListElement { appId: "pvz"; appTitle: "植物大战僵尸"; iconSource: "qrc:/assets/icons/pvz.svg"; accent: "#318C45" }
        ListElement { appId: "settings"; appTitle: "设置"; iconSource: "qrc:/assets/icons/settings.svg"; accent: "#8B5CF6" }
        ListElement { appId: "mindustry"; appTitle: "像素工厂"; iconSource: "qrc:/assets/icons/mindustry.png"; accent: "#59616A" }
    }

    Timer {
        interval: 1000
        running: true
        repeat: true
        property int telemetryTick: 0
        onTriggered: {
            window.checkIdleState()
            if (!systemBackend.screenSleeping) {
                telemetryTick++
                if (telemetryTick % 3 === 0) {
                    systemBackend.refreshStatus()
                }
            }
        }
    }

    Connections {
        target: systemBackend
        function onDisplayChanged() {
            window.uiRotation = systemBackend.displayRotation
        }
        function onOperationMessage(message, success) {
            window.operationText = message
            window.operationSuccess = success
            toast.show()
        }
    }

    Item {
        id: scene
        width: 1280
        height: 800
        rotation: window.uiRotation
        transformOrigin: Item.TopLeft
        x: window.uiRotation === -90 ? 0 : 0
        y: window.uiRotation === -90 ? 1280 : 0

        Rectangle {
            anchors.fill: parent
            color: window.canvas
        }

        StatusBar {
            id: statusBar
            anchors { left: parent.left; right: parent.right; top: parent.top }
            z: 1000
            onExitRequested: {
                window.closeForegroundApp()
            }
        }

        StackView {
            id: stack
            anchors { left: parent.left; right: parent.right; top: statusBar.bottom; bottom: parent.bottom }
            initialItem: homeComponent
            focus: true

            pushEnter: Transition {
                PropertyAnimation { property: "opacity"; from: 0; to: 1; duration: 150; easing.type: Easing.OutCubic }
            }
            pushExit: Transition {
                PropertyAnimation { property: "opacity"; from: 1; to: 0; duration: 120; easing.type: Easing.OutCubic }
            }
            popEnter: Transition {
                PropertyAnimation { property: "opacity"; from: 0; to: 1; duration: 130; easing.type: Easing.OutCubic }
            }
            popExit: Transition {
                PropertyAnimation { property: "opacity"; from: 1; to: 0; duration: 120; easing.type: Easing.OutCubic }
            }

            Keys.onEscapePressed: {
                if (passwordDialog.visible) passwordDialog.close()
                else if (ethernetDialog.visible) ethernetDialog.close()
                else if (stack.depth > 1) window.closeForegroundApp()
            }

            Component.onCompleted: {
                if (Qt.application.arguments.indexOf("--pvz") >= 0) systemBackend.launchPvZ()
                else if (window.startInSettings) openApp("settings", true)
                else if (window.startInFiles) openApp("files", true)
                else if (window.startInMindustry) window.launchMindustryDirect()
            }
        }

        MouseArea {
            id: edgeSwipeArea
            anchors { left: parent.left; top: statusBar.bottom; bottom: parent.bottom }
            width: 92
            z: 1500
            enabled: stack.depth > 1 && !passwordDialog.visible && !ethernetDialog.visible
            property real startX: 0
            property real startY: 0
            property bool swiping: false
            onPressed: { startX = mouse.x; startY = mouse.y; swiping = false }
            onPositionChanged: {
                if (!pressed) return
                var dx = mouse.x - startX
                var dy = mouse.y - startY
                if (!swiping && dx > 24 && Math.abs(dx) > Math.abs(dy) * 1.3) {
                    swiping = true
                }
            }
            onReleased: {
                if (swiping && (mouse.x - startX) > 60) {
                    window.closeForegroundApp()
                }
                swiping = false
            }
            onCanceled: { swiping = false }
        }

        Rectangle {
            id: sleepOverlay
            anchors.fill: parent
            z: 9000
            color: "#000000"
            visible: systemBackend.screenSleeping || opacity > 0.01
            opacity: systemBackend.screenSleeping ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

            MouseArea {
                anchors.fill: parent
                enabled: systemBackend.screenSleeping
                onPressed: {
                    systemBackend.wakeScreen()
                    mouse.accepted = true
                }
            }
        }

        Rectangle {
            id: splash
            anchors.fill: parent
            z: 3000
            color: "#FCFBFD"
            visible: !window.startInSettings && !window.startInFiles && !window.startInMindustry
            opacity: 1

            Column {
                anchors.centerIn: parent
                spacing: 16
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 130; height: 130; radius: 65; color: "#FFF0F4"
                    Image {
                        anchors.centerIn: parent
                        width: 108; height: 108
                        source: "qrc:/assets/meowkj-avatar-circle.png"
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                    }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Meow OS " + systemBackend.version
                    color: window.ink
                    font.family: window.uiFont
                    font.pixelSize: 26
                    font.weight: Font.Bold
                }
            }

            SequentialAnimation {
                running: splash.visible
                PauseAnimation { duration: 850 }
                NumberAnimation { target: splash; property: "opacity"; to: 0; duration: 320; easing.type: Easing.OutCubic }
                ScriptAction { script: splash.visible = false }
            }
        }

        Rectangle {
            id: toast
            z: 2200
            anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 28 }
            width: Math.min(parent.width - 60, toastContent.implicitWidth + 36)
            height: 48
            radius: 16
            color: window.operationSuccess ? "#27222D" : "#EB4D5C"
            opacity: 0
            visible: opacity > 0.01

            function show() {
                toastAnim.restart()
            }

            Row {
                id: toastContent
                anchors.centerIn: parent
                spacing: 8
                Text {
                    text: window.operationText
                    color: "white"
                    font.family: window.uiFont
                    font.pixelSize: 16
                    font.weight: Font.Medium
                }
            }

            SequentialAnimation {
                id: toastAnim
                NumberAnimation { target: toast; property: "opacity"; to: 0.95; duration: 160 }
                PauseAnimation { duration: 2400 }
                NumberAnimation { target: toast; property: "opacity"; to: 0; duration: 220 }
            }
        }
    }

    Component {
        id: homeComponent
        Item {
            id: homePage
            objectName: "meow-home-page"

            // Classic 16:10 high-definition nature landscape wallpaper
            Image {
                anchors.fill: parent
                source: "qrc:/assets/wallpaper.jpg"
                fillMode: Image.PreserveAspectCrop
                smooth: true
            }

            // Classic mobile OS desktop app icon grid
            Row {
                anchors {
                    left: parent.left; leftMargin: 64
                    top: parent.top; topMargin: 56
                }
                spacing: 40
                Repeater {
                    model: appRegistry
                    delegate: AppLauncher {
                        title: model.appTitle
                        icon: model.iconSource
                        accentColor: model.accent
                        fullBleedIcon: model.appId === "mindustry"
                        onClicked: model.appId === "mindustry"
                                   ? window.launchMindustryDirect()
                                   : window.openApp(model.appId)
                    }
                }
            }
        }
    }

    Component {
        id: touchTestComponent
        TouchTestApp {
            objectName: "touch-test"
            onExitRequested: window.closeForegroundApp()
            onBackRequested: window.closeForegroundApp()
        }
    }

    Component {
        id: reactionGameComponent
        ReactionGameApp {
            objectName: "reaction-game"
            onExitRequested: window.closeForegroundApp()
            onBackRequested: window.closeForegroundApp()
        }
    }

    Component {
        id: fileManagerComponent
        FileManagerApp {
            objectName: "files"
            onExitRequested: window.closeForegroundApp()
            onBackRequested: window.closeForegroundApp()
        }
    }

    Component {
        id: settingsComponent
        SettingsApp {
            objectName: "settings"
            onExitRequested: window.closeForegroundApp()
            onBackRequested: window.closeForegroundApp()
        }
    }

    Item {
        id: passwordDialog
        property string ssid: ""
        property string securityType: "WPA2"
        property bool shift: false
        property int keyboardPage: 0
        property bool showPassword: false
        property bool opened: false
        function openFor(networkName, sec) {
            ssid = networkName
            securityType = sec ? sec : (networkName.indexOf("Open") >= 0 || networkName.indexOf("开放") >= 0 ? "Open" : "WPA2")
            shift = false
            keyboardPage = 0
            showPassword = false
            wifiPassword.text = ""
            open()
        }
        function typeKey(key) {
            wifiPassword.text += key
            if (shift && keyboardPage === 0) shift = false
        }
        function backspace() {
            if (wifiPassword.text.length > 0) wifiPassword.text = wifiPassword.text.slice(0, -1)
        }
        function open() {
            visible = true
            opened = true
            wifiPassword.forceActiveFocus()
        }
        function close() {
            opened = false
            closeAnimation.restart()
        }
        function submit() {
            if (wifiPassword.text.length === 0) return
            systemBackend.connectWifi(ssid, wifiPassword.text)
            close()
            wifiPassword.text = ""
        }
        parent: scene; anchors.fill: parent; z: 4000; visible: false
        Rectangle {
            anchors.fill: parent
            color: passwordDialog.opened ? "#780E0C1C" : "#00000000"
            opacity: passwordDialog.opened ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 180 } }
            MouseArea { anchors.fill: parent; onClicked: passwordDialog.close() }
        }
        Rectangle {
            id: dialogContent
            width: 880; height: 168
            anchors.horizontalCenter: parent.horizontalCenter
            y: passwordDialog.opened ? 110 : 80
            radius: 24; color: "#FFFFFF"; border.color: "#E2DFEC"; border.width: 1
            opacity: passwordDialog.opened ? 1 : 0
            scale: passwordDialog.opened ? 1.0 : 0.96
            Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

            Column {
                anchors.fill: parent; anchors.margins: 20; spacing: 14

                // Top Header Row
                RowLayout {
                    width: parent.width; height: 40
                    spacing: 12

                    // Icon & Title & Inline SSID
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10

                        Rectangle {
                            Layout.preferredWidth: 36; Layout.preferredHeight: 36; radius: 10
                            color: "#EDE9FE"
                            Image {
                                anchors.centerIn: parent; width: 20; height: 20
                                source: "qrc:/assets/icons/wifi.svg"
                                sourceSize.width: 40; sourceSize.height: 40
                            }
                        }

                        Text {
                            text: "连接 Wi-Fi"
                            color: window.ink; font.family: window.uiFont; font.pixelSize: 20; font.weight: Font.Bold
                            Layout.alignment: Qt.AlignVCenter
                        }

                        Text {
                            visible: passwordDialog.ssid.length > 0
                            text: "·"
                            color: "#A09BA8"
                            font.pixelSize: 18
                            font.weight: Font.Bold
                            Layout.alignment: Qt.AlignVCenter
                        }

                        Rectangle {
                            visible: passwordDialog.ssid.length > 0
                            Layout.maximumWidth: 320
                            Layout.preferredHeight: 30
                            Layout.preferredWidth: Math.min(320, ssidLabel.implicitWidth + 22)
                            Layout.alignment: Qt.AlignVCenter
                            radius: 9
                            color: "#F2EFFB"
                            border.color: "#E3DEF5"
                            border.width: 1

                            Text {
                                id: ssidLabel
                                anchors.centerIn: parent
                                width: Math.min(parent.width - 16, implicitWidth)
                                text: passwordDialog.ssid
                                color: "#5443BA"
                                font.family: window.uiFont
                                font.pixelSize: 15
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                            }
                        }
                    }

                    // Security Tip Badge
                    Rectangle {
                        id: securityBadge
                        readonly property bool isSecure: passwordDialog.securityType.toLowerCase().indexOf("open") < 0
                                                        && passwordDialog.securityType.toLowerCase().indexOf("none") < 0
                                                        && passwordDialog.securityType.toLowerCase().indexOf("wep") < 0
                        Layout.preferredHeight: 30
                        Layout.preferredWidth: securityTipText.implicitWidth + 22
                        Layout.alignment: Qt.AlignVCenter
                        radius: 9
                        color: isSecure ? "#ECFDF5" : "#FFFBEB"
                        border.color: isSecure ? "#A7F3D0" : "#FDE68A"
                        border.width: 1

                        Row {
                            anchors.centerIn: parent
                            spacing: 5
                            Rectangle {
                                width: 7; height: 7; radius: 3.5
                                anchors.verticalCenter: parent.verticalCenter
                                color: securityBadge.isSecure ? "#10B981" : "#F59E0B"
                            }
                            Text {
                                id: securityTipText
                                text: securityBadge.isSecure ? "安全加密网络" : "开放未加密"
                                color: securityBadge.isSecure ? "#059669" : "#B45309"
                                font.family: window.uiFont
                                font.pixelSize: 13
                                font.weight: Font.DemiBold
                            }
                        }
                    }

                    // Close Dialog Button
                    Rectangle {
                        width: 32; height: 32; radius: 16
                        color: closeDialogMouse.pressed ? "#E2DFE7" : "#F1EEF5"
                        Layout.alignment: Qt.AlignVCenter
                        Text { anchors.centerIn: parent; text: "✕"; color: window.secondary; font.pixelSize: 13; font.weight: Font.Bold }
                        MouseArea { id: closeDialogMouse; anchors.fill: parent; onClicked: passwordDialog.close() }
                    }
                }

                // Password Input Field Box
                Item {
                    width: parent.width; height: 54
                    TextField {
                        id: wifiPassword
                        anchors.fill: parent
                        placeholderText: "请输入无线网络密码…"
                        echoMode: passwordDialog.showPassword ? TextInput.Normal : TextInput.Password
                        font.family: window.uiFont; font.pixelSize: 19
                        leftPadding: 18; rightPadding: 104
                        background: Rectangle {
                            radius: 14; color: "#F8F7FC"
                            border.color: wifiPassword.activeFocus ? "#7B6DF0" : "#DCD8E6"
                            border.width: wifiPassword.activeFocus ? 2 : 1
                        }
                        Keys.onReturnPressed: passwordDialog.submit()
                    }

                    // Show / Hide Password Action Button
                    Rectangle {
                        anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                        width: 82; height: 38; radius: 10
                        color: showPasswordMouse.pressed ? "#E1DDF8" : "#EEEAFE"
                        border.color: "#DDD7F8"; border.width: 1
                        Row {
                            anchors.centerIn: parent; spacing: 4
                            Text {
                                text: passwordDialog.showPassword ? "隐藏" : "显示"
                                color: "#6555D5"; font.family: window.uiFont; font.pixelSize: 14; font.weight: Font.DemiBold
                            }
                        }
                        MouseArea { id: showPasswordMouse; anchors.fill: parent; onClicked: passwordDialog.showPassword = !passwordDialog.showPassword }
                    }
                }
            }
        }

        // Modern Pure Flat Virtual Keyboard Shell
        Rectangle {
            id: keyboardShell
            anchors.left: parent.left
            anchors.right: parent.right
            height: 260
            y: passwordDialog.opened ? parent.height - height : parent.height
            color: "#161324"
            border.color: "#2C2646"; border.width: 1
            opacity: passwordDialog.opened ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
            Behavior on y { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

            // Absorb clicks on keyboard shell
            MouseArea {
                anchors.fill: parent
                z: 0
                onClicked: mouse.accepted = true
            }

            Column {
                id: keyboardContent
                z: 1
                anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 18; rightMargin: 18; topMargin: 14 }
                spacing: 8

                // Row 1: 10 Keys (Total: 1232px)
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter; spacing: 8
                    Repeater {
                        model: passwordDialog.keyboardPage === 0
                               ? ["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"]
                               : (passwordDialog.keyboardPage === 1
                                  ? ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
                                  : ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="])
                        delegate: IpadKey {
                            label: passwordDialog.keyboardPage === 0
                                   ? (passwordDialog.shift ? modelData : modelData.toLowerCase())
                                   : modelData
                            keyWidth: 116
                            keyHeight: 52
                            onTapped: passwordDialog.typeKey(label)
                        }
                    }
                }

                // Row 2: 9 Keys (Total: 1108px, centered)
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter; spacing: 8
                    Repeater {
                        model: passwordDialog.keyboardPage === 0
                               ? ["A", "S", "D", "F", "G", "H", "J", "K", "L"]
                               : (passwordDialog.keyboardPage === 1
                                  ? ["@", "#", "$", "%", "&", "*", "(", ")", "\""]
                                  : ["_", "\\", "|", "~", "<", ">", "€", "£", "¥"])
                        delegate: IpadKey {
                            label: passwordDialog.keyboardPage === 0
                                   ? (passwordDialog.shift ? modelData : modelData.toLowerCase())
                                   : modelData
                            keyWidth: 116
                            keyHeight: 52
                            onTapped: passwordDialog.typeKey(label)
                        }
                    }
                }

                // Row 3: Shift(178) + 7 Keys(116) + Backspace(178) (Total: 1232px)
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter; spacing: 8
                    IpadKey {
                        label: passwordDialog.keyboardPage === 0 ? "⇧"
                                                                  : (passwordDialog.keyboardPage === 1 ? "#+=" : "123")
                        keyWidth: 178; keyHeight: 52; functionKey: true; active: passwordDialog.shift
                        onTapped: {
                            if (passwordDialog.keyboardPage === 0) passwordDialog.shift = !passwordDialog.shift
                            else passwordDialog.keyboardPage = passwordDialog.keyboardPage === 1 ? 2 : 1
                        }
                    }
                    Repeater {
                        model: passwordDialog.keyboardPage === 0
                               ? ["Z", "X", "C", "V", "B", "N", "M"]
                               : (passwordDialog.keyboardPage === 1
                                  ? ["-", "_", "=", "+", "/", "\\", "?"]
                                  : [".", ",", ":", ";", "!", "?", "'"])
                        delegate: IpadKey {
                            label: passwordDialog.keyboardPage === 0
                                   ? (passwordDialog.shift ? modelData : modelData.toLowerCase())
                                   : (modelData === "'" ? "’" : modelData)
                            keyWidth: 116
                            keyHeight: 52
                            onTapped: passwordDialog.typeKey(passwordDialog.keyboardPage === 2 && modelData === "'" ? "'" : label)
                        }
                    }
                    IpadKey {
                        icon: "qrc:/assets/icons/delete-cute.svg"
                        keyWidth: 178
                        keyHeight: 52
                        functionKey: true
                        destructive: true
                        onTapped: passwordDialog.backspace()
                    }
                }

                // Row 4: Mode(160) + Comma(90) + Space(526) + Dot(90) + Cancel(140) + Connect(186) (Total: 1232px)
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter; spacing: 8
                    IpadKey {
                        label: passwordDialog.keyboardPage === 0 ? "123" : "ABC"
                        keyWidth: 160
                        keyHeight: 52
                        functionKey: true
                        onTapped: {
                            passwordDialog.keyboardPage = passwordDialog.keyboardPage === 0 ? 1 : 0
                            passwordDialog.shift = false
                        }
                    }
                    IpadKey { label: ","; keyWidth: 90; keyHeight: 52; onTapped: passwordDialog.typeKey(",") }
                    IpadKey {
                        label: "空格  Space"
                        keyWidth: 526
                        keyHeight: 52
                        onTapped: passwordDialog.typeKey(" ")
                    }
                    IpadKey { label: "."; keyWidth: 90; keyHeight: 52; onTapped: passwordDialog.typeKey(".") }
                    IpadKey { label: "取消"; keyWidth: 140; keyHeight: 52; functionKey: true; onTapped: passwordDialog.close() }
                    IpadKey { label: "连接"; keyWidth: 186; keyHeight: 52; returnKey: true; onTapped: passwordDialog.submit() }
                }
            }
        }

        Timer {
            id: closeAnimation
            interval: 220
            onTriggered: passwordDialog.visible = false
        }
    }

    Item {
        id: ethernetDialog
        parent: scene; anchors.fill: parent; z: 4000; visible: false
        property var port: ({})
        property string interfaceName: ""
        property string connectionName: ""
        property bool connected: false
        property string method: "auto"
        property string addressText: ""
        property string prefixText: "24"
        property string gatewayText: ""
        property string dnsText: ""
        property string activeField: "address"
        function openFor(portInfo) {
            port = portInfo || ({})
            interfaceName = port.name || ""
            connectionName = port.connection || ""
            connected = port.connected === true
            method = port.method === "manual" ? "manual" : "auto"
            var ipv4 = String(port.ipv4 || "")
            var slash = ipv4.lastIndexOf("/")
            addressText = slash >= 0 ? ipv4.slice(0, slash) : ipv4
            prefixText = slash >= 0 ? ipv4.slice(slash + 1) : "24"
            gatewayText = String(port.gateway || "")
            dnsText = String(port.dns || "")
            activeField = "address"
            visible = true
        }
        function close() { visible = false }
        function fieldValue() {
            if (activeField === "address") return addressText
            if (activeField === "prefix") return prefixText
            if (activeField === "gateway") return gatewayText
            return dnsText
        }
        function setFieldValue(value) {
            if (activeField === "address") addressText = value
            else if (activeField === "prefix") prefixText = value
            else if (activeField === "gateway") gatewayText = value
            else dnsText = value
        }
        function typeKey(key) {
            var current = fieldValue()
            if (key === "backspace") setFieldValue(current.slice(0, -1))
            else if (key === "清除") setFieldValue("")
            else if (activeField === "prefix" && (key === "." || key === ",")) return
            else setFieldValue(current + key)
        }
        function nextField() {
            if (activeField === "address") activeField = "prefix"
            else if (activeField === "prefix") activeField = "gateway"
            else if (activeField === "gateway") activeField = "dns"
            else activeField = "address"
        }
        function applyConfiguration() {
            systemBackend.configureEthernet(interfaceName, connectionName, method, addressText,
                                            parseInt(prefixText || "0"), gatewayText, dnsText)
            close()
        }

        Rectangle { anchors.fill: parent; color: "#660B0A0D"; MouseArea { anchors.fill: parent; onClicked: ethernetDialog.close() } }
        Rectangle {
            width: 980; height: 590; anchors.centerIn: parent; radius: 28
            color: "#FCFBFD"; border.color: "#D9D5DE"; border.width: 1
            RowLayout {
                anchors.fill: parent; anchors.margins: 24; spacing: 24
                ColumnLayout {
                    Layout.fillWidth: true; Layout.fillHeight: true; spacing: 14
                    RowLayout {
                        Layout.fillWidth: true
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 1
                            Text { text: "配置 " + ethernetDialog.interfaceName; color: window.ink; font.family: window.uiFont; font.pixelSize: 27; font.weight: Font.Bold }
                            Text { text: ethernetDialog.connectionName.length ? ethernetDialog.connectionName : "新建有线连接"; color: window.secondary; font.family: window.uiFont; font.pixelSize: 14 }
                        }
                        Rectangle {
                            Layout.preferredWidth: 92; Layout.preferredHeight: 38; radius: 13
                            color: ethernetDialog.connected ? "#DDF5E7" : "#E8E8ED"
                            Text { anchors.centerIn: parent; text: ethernetDialog.connected ? "已连接" : "未连接"; color: ethernetDialog.connected ? "#20844A" : "#6F6A74"; font.family: window.uiFont; font.pixelSize: 14; font.weight: Font.DemiBold }
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        Rectangle {
                            Layout.fillWidth: true; Layout.preferredHeight: 46; radius: 14
                            color: ethernetDialog.method === "auto" ? window.purple : "#F0EDF3"
                            Text { anchors.centerIn: parent; text: "自动获取 DHCP"; color: ethernetDialog.method === "auto" ? "white" : window.ink; font.family: window.uiFont; font.pixelSize: 15; font.weight: Font.DemiBold }
                            MouseArea { anchors.fill: parent; onClicked: ethernetDialog.method = "auto" }
                        }
                        Rectangle {
                            Layout.fillWidth: true; Layout.preferredHeight: 46; radius: 14
                            color: ethernetDialog.method === "manual" ? window.purple : "#F0EDF3"
                            Text { anchors.centerIn: parent; text: "手动 IPv4"; color: ethernetDialog.method === "manual" ? "white" : window.ink; font.family: window.uiFont; font.pixelSize: 15; font.weight: Font.DemiBold }
                            MouseArea { anchors.fill: parent; onClicked: ethernetDialog.method = "manual" }
                        }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 9; enabled: ethernetDialog.method === "manual"; opacity: enabled ? 1 : 0.35
                        RowLayout {
                            Layout.fillWidth: true; spacing: 9
                            NetworkField { Layout.fillWidth: true; label: "IPv4 地址"; value: ethernetDialog.addressText; placeholder: "192.168.1.20"; selected: ethernetDialog.activeField === "address"; onTapped: ethernetDialog.activeField = "address" }
                            NetworkField { Layout.preferredWidth: 112; label: "前缀"; value: ethernetDialog.prefixText; placeholder: "24"; selected: ethernetDialog.activeField === "prefix"; onTapped: ethernetDialog.activeField = "prefix" }
                        }
                        NetworkField { Layout.fillWidth: true; label: "默认网关"; value: ethernetDialog.gatewayText; placeholder: "192.168.1.1"; selected: ethernetDialog.activeField === "gateway"; onTapped: ethernetDialog.activeField = "gateway" }
                        NetworkField { Layout.fillWidth: true; label: "DNS 服务器"; value: ethernetDialog.dnsText; placeholder: "1.1.1.1, 8.8.8.8"; selected: ethernetDialog.activeField === "dns"; onTapped: ethernetDialog.activeField = "dns" }
                    }
                    Item { Layout.fillHeight: true }
                    RowLayout {
                        Layout.fillWidth: true; spacing: 9
                        Rectangle {
                            Layout.preferredWidth: 112; Layout.preferredHeight: 46; radius: 14; color: "#F0EDF3"
                            Text { anchors.centerIn: parent; text: "取消"; color: window.ink; font.family: window.uiFont; font.pixelSize: 16; font.weight: Font.DemiBold }
                            MouseArea { anchors.fill: parent; onClicked: ethernetDialog.close() }
                        }
                        Rectangle {
                            Layout.preferredWidth: 132; Layout.preferredHeight: 46; radius: 14
                            color: ethernetDialog.connected ? "#FFF0F1" : "#EAF8F2"
                            Text { anchors.centerIn: parent; text: ethernetDialog.connected ? "断开端口" : "连接端口"; color: ethernetDialog.connected ? "#C93646" : "#238C69"; font.family: window.uiFont; font.pixelSize: 15; font.weight: Font.DemiBold }
                            MouseArea { anchors.fill: parent; onClicked: { systemBackend.setEthernetConnected(ethernetDialog.interfaceName, !ethernetDialog.connected); ethernetDialog.close() } }
                        }
                        Item { Layout.fillWidth: true }
                        Rectangle {
                            Layout.preferredWidth: 142; Layout.preferredHeight: 46; radius: 14; color: window.purple
                            Text { anchors.centerIn: parent; text: "应用配置"; color: "white"; font.family: window.uiFont; font.pixelSize: 16; font.weight: Font.DemiBold }
                            MouseArea { anchors.fill: parent; onClicked: ethernetDialog.applyConfiguration() }
                        }
                    }
                }
                Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; color: window.separator }
                ColumnLayout {
                    Layout.preferredWidth: 280; Layout.minimumWidth: 280; Layout.maximumWidth: 280
                    Layout.fillHeight: true; spacing: 10
                    Text { text: "数字键盘"; color: window.ink; font.family: window.uiFont; font.pixelSize: 18; font.weight: Font.DemiBold }
                    GridLayout {
                        columns: 3; columnSpacing: 8; rowSpacing: 8
                        Repeater {
                            model: ["1", "2", "3", "4", "5", "6", "7", "8", "9",
                                    ".", "0", "backspace", ",", "清除", "下一项"]
                            delegate: KeyboardKey {
                                label: modelData === "backspace" ? "" : modelData; keyWidth: 88
                                icon: modelData === "backspace" ? "qrc:/assets/icons/delete.svg" : ""
                                destructive: modelData === "清除"
                                accent: modelData === "下一项"
                                onTapped: modelData === "下一项" ? ethernetDialog.nextField()
                                                                       : ethernetDialog.typeKey(modelData)
                            }
                        }
                    }
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 72; radius: 15; color: "#F4F2F6"
                        Column {
                            anchors.centerIn: parent; spacing: 3
                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: ethernetDialog.activeField === "address" ? "IPv4 地址" : (ethernetDialog.activeField === "prefix" ? "前缀长度" : (ethernetDialog.activeField === "gateway" ? "默认网关" : "DNS 服务器")); color: window.secondary; font.family: window.uiFont; font.pixelSize: 12 }
                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: ethernetDialog.fieldValue().length ? ethernetDialog.fieldValue() : "等待输入"; color: window.ink; font.family: window.uiFont; font.pixelSize: 17; font.weight: Font.DemiBold }
                        }
                    }
                    Item { Layout.fillHeight: true }
                }
            }
        }
    }

    Rectangle {
        parent: scene; z: 2049
        visible: systemBackend.powerManagement.fresh === true
                 && (systemBackend.powerManagement.status !== "normal" || systemBackend.powerManagement.lowBattery === true
                     || (systemBackend.powerManagement.lastEvent || "").length > 0)
        anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 24; rightMargin: 24; topMargin: window.statusBarHeight + 10 }
        height: powerAlert.implicitHeight + 24; radius: 16; color: "#FFF1DC"; border.color: "#F0C782"
        Text {
            id: powerAlert; anchors.fill: parent; anchors.margins: 12
            text: systemBackend.powerManagement.lastEvent || systemBackend.powerManagement.message || "电源保护提示"
            wrapMode: Text.WordWrap; color: "#925515"; font.family: window.uiFont; font.pixelSize: 16
        }
    }

    Item {
        id: wifiOperationBanner
        parent: scene
        z: 2050
        visible: systemBackend.wifiOperating
        anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: window.statusBarHeight + 10 }
        height: 56
        Rectangle {
            anchors { horizontalCenter: parent.horizontalCenter }
            width: Math.min(parent.width - 48, bannerText.implicitWidth + 78)
            height: parent.height
            radius: 18
            color: "#F4F1FF"
            border.color: "#D4CDF5"
            border.width: 1
            Row {
                anchors.centerIn: parent; spacing: 12
                Rectangle {
                    width: 12; height: 12; radius: 6
                    color: window.purple
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    id: bannerText
                    anchors.verticalCenter: parent.verticalCenter
                    text: systemBackend.wifiOperation === "connect"
                          ? "正在连接到 “" + systemBackend.wifiOperationSsid + "”…"
                          : "正在忘记 “" + systemBackend.wifiOperationSsid + "”…"
                    color: "#5A4CC4"
                    font.family: window.uiFont; font.pixelSize: 17; font.weight: Font.DemiBold
                }
            }
        }
    }
}
