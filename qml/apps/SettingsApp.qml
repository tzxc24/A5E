import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import "../components"

Rectangle {
    id: settingsPage
    objectName: "settings"
    property string appId: "settings"
    color: "#F5F4F8"
    signal exitRequested()
    signal backRequested()

    property string section: window.initialSettingsSection
    readonly property int sectionIndex: section === "wifi" ? 0
                                        : section === "ethernet" ? 1
                                        : section === "battery" ? 2
                                        : section === "sound" ? 3
                                        : section === "display" ? 4
                                        : section === "performance" ? 5
                                        : section === "storage" ? 6 : 7
    readonly property var pageLoaders: [wifiPageLoader, ethernetPageLoader,
                                        batteryPageLoader, soundPageLoader,
                                        displayPageLoader, performancePageLoader,
                                        storagePageLoader, aboutPageLoader]
    property int prewarmIndex: 0
    property int displayedSectionIndex: sectionIndex
    property int pendingSectionIndex: -1
    property double pageReadyStartedAt: 0
    property bool qaWaitingForReady: false
    property int qaSwitchIndex: 0
    readonly property var qaSections: ["wifi", "ethernet", "battery", "sound", "display", "performance", "storage", "about"]
    property double sectionSwitchStartedAt: 0
    property int lastSectionSwitchMs: -1

    function ensureCurrentPage() {
        if (!pageLoaders || sectionIndex < 0 || sectionIndex >= pageLoaders.length) return
        var loader = pageLoaders[sectionIndex]
        if (loader) {
            // Keep the click path non-blocking. Already-created pages can be
            // shown immediately; cold pages load asynchronously behind the
            // lightweight loading overlay below.
            loader.asynchronous = !loader.item
            loader.active = true
        }
    }
    function openSection(name, index) {
        if (!pageLoaders || index < 0 || index >= pageLoaders.length) return
        systemBackend.boostInteractivePerformance(2, 650)
        var loader = pageLoaders[index]
        sectionSwitchStartedAt = Date.now()
        pageReadyStartedAt = sectionSwitchStartedAt
        window.measureNextUiFrame(name, sectionSwitchStartedAt)
        if (loader && loader.status === Loader.Ready) {
            displayedSectionIndex = index
            pendingSectionIndex = -1
        } else {
            pendingSectionIndex = index
        }
        section = name
    }
    function commitLoadedPage(index) {
        if (index !== pendingSectionIndex || pageLoaders[index].status !== Loader.Ready) return
        displayedSectionIndex = index
        pendingSectionIndex = -1
        systemBackend.releaseInteractivePerformance()
        if (window.settingsQaMetrics && pageReadyStartedAt > 0)
            console.log("[MeowOS] settings-ready", section, Date.now() - pageReadyStartedAt, "ms")
        pageReadyStartedAt = 0
        if (qaWaitingForReady) {
            qaWaitingForReady = false
            scheduleNextQaSwitch()
        }
    }
    onSectionChanged: {
        window.lastSettingsSection = section
        systemBackend.setActiveScope(section)
        if (sectionSwitchStartedAt > 0) {
            lastSectionSwitchMs = Date.now() - sectionSwitchStartedAt
            if (window.settingsQaMetrics)
                console.log("[MeowOS] settings-switch", section, lastSectionSwitchMs, "ms")
            sectionSwitchStartedAt = 0
        }
    }
    Component.onCompleted: {
        ensureCurrentPage()
        window.lastSettingsSection = section
        systemBackend.setActiveScope(section)
        prewarmTimer.start()
        if (window.settingsQaSwitch)
            qaSwitchTimer.start()
    }

    Timer {
        id: prewarmTimer
        interval: 160
        repeat: true
        triggeredOnStart: false
        onTriggered: {
            if (pendingSectionIndex >= 0) return
            while (settingsPage.prewarmIndex < settingsPage.pageLoaders.length) {
                var loader = settingsPage.pageLoaders[settingsPage.prewarmIndex]
                if (!loader.active) {
                    loader.asynchronous = true
                    loader.active = true
                    return
                } else if (loader.status === Loader.Loading) {
                    return
                }
                settingsPage.prewarmIndex++
            }
            stop()
        }
    }

    Timer {
        id: qaSwitchTimer
        interval: 120
        repeat: false
        onTriggered: {
            if (settingsPage.qaSwitchIndex >= settingsPage.qaSections.length * 2) {
                return
            }
            var index = settingsPage.qaSwitchIndex++ % settingsPage.qaSections.length
            settingsPage.openSection(settingsPage.qaSections[index], index)
        }
    }

    function scheduleNextQaSwitch() {
        // Cold construction leaves render-thread uploads and binding work
        // immediately after Loader.Ready. Give that one-time work a short
        // settle window; the second cached pass remains a rapid-switch test.
        qaSwitchTimer.interval = qaSwitchIndex < qaSections.length ? 280 : 120
        qaSwitchTimer.restart()
    }

    function uiFrameCompleted() {
        if (pendingSectionIndex >= 0) {
            var loader = pageLoaders[pendingSectionIndex]
            if (loader && !loader.active) {
                loader.asynchronous = true
                loader.active = true
            }
        }
        if (!window.settingsQaSwitch
                || settingsPage.qaSwitchIndex >= settingsPage.qaSections.length * 2)
            return
        if (pendingSectionIndex < 0) scheduleNextQaSwitch()
        else qaWaitingForReady = true
    }

    Rectangle {
        id: settingsSidebar
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom; margins: 24 }
        width: 318; radius: 26; color: "#FFFFFF"

        Column {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 5

            AppHeader { width: parent.width; title: "设置"; compact: true; showBack: false; onExitRequested: settingsPage.exitRequested() }

            SettingsNavRow { title: "Wi-Fi"; icon: "qrc:/assets/icons/wifi.svg"; accent: "#10B981"; selected: settingsPage.section === "wifi"; onClicked: settingsPage.openSection("wifi", 0) }
            SettingsNavRow { title: "有线网络"; icon: "qrc:/assets/icons/ethernet-port.svg"; accent: "#3B82F6"; selected: settingsPage.section === "ethernet"; onClicked: settingsPage.openSection("ethernet", 1) }
            SettingsNavRow { title: "电池"; icon: "qrc:/assets/icons/battery-charging.svg"; accent: "#F59E0B"; selected: settingsPage.section === "battery"; onClicked: settingsPage.openSection("battery", 2) }
            SettingsNavRow { title: "声音"; icon: "qrc:/assets/icons/volume-2.svg"; accent: "#EC4899"; selected: settingsPage.section === "sound"; onClicked: settingsPage.openSection("sound", 3) }
            SettingsNavRow { title: "显示与触摸"; icon: "qrc:/assets/icons/monitor.svg"; accent: "#6366F1"; selected: settingsPage.section === "display"; onClicked: settingsPage.openSection("display", 4) }
            SettingsNavRow { title: "性能"; icon: "qrc:/assets/icons/cpu.svg"; accent: "#06B6D4"; selected: settingsPage.section === "performance"; onClicked: settingsPage.openSection("performance", 5) }
            SettingsNavRow { title: "存储空间"; icon: "qrc:/assets/icons/hard-drive.svg"; accent: "#2563EB"; selected: settingsPage.section === "storage"; onClicked: settingsPage.openSection("storage", 6) }
            SettingsNavRow { title: "关于本机"; icon: "qrc:/assets/icons/info.svg"; accent: "#64748B"; selected: settingsPage.section === "about"; onClicked: settingsPage.openSection("about", 7) }
        }
    }

    Rectangle {
        anchors { left: settingsSidebar.right; right: parent.right; top: parent.top; bottom: parent.bottom; leftMargin: 18; rightMargin: 24; topMargin: 24; bottomMargin: 24 }
        radius: 26; color: "#FFFFFF"; clip: true
        StackLayout {
            anchors.fill: parent
            currentIndex: settingsPage.displayedSectionIndex
            Loader { id: wifiPageLoader; active: false; asynchronous: true; sourceComponent: wifiSettings; onStatusChanged: settingsPage.commitLoadedPage(0) }
            Loader { id: ethernetPageLoader; active: false; asynchronous: true; sourceComponent: ethernetSettings; onStatusChanged: settingsPage.commitLoadedPage(1) }
            Loader { id: batteryPageLoader; active: false; asynchronous: true; sourceComponent: batterySettings; onStatusChanged: settingsPage.commitLoadedPage(2) }
            Loader { id: soundPageLoader; active: false; asynchronous: true; sourceComponent: soundSettings; onStatusChanged: settingsPage.commitLoadedPage(3) }
            Loader { id: displayPageLoader; active: false; asynchronous: true; sourceComponent: displaySettings; onStatusChanged: settingsPage.commitLoadedPage(4) }
            Loader { id: performancePageLoader; active: false; asynchronous: true; sourceComponent: performanceSettings; onStatusChanged: settingsPage.commitLoadedPage(5) }
            Loader { id: storagePageLoader; active: false; asynchronous: true; sourceComponent: storageSettings; onStatusChanged: settingsPage.commitLoadedPage(6) }
            Loader { id: aboutPageLoader; active: false; asynchronous: true; sourceComponent: aboutSettings; onStatusChanged: settingsPage.commitLoadedPage(7) }
        }
        Rectangle {
            anchors.fill: parent
            z: 20
            radius: 26
            color: "#F8F7FF"
            visible: settingsPage.pendingSectionIndex >= 0
            Column {
                anchors.centerIn: parent
                spacing: 10
                Text { anchors.horizontalCenter: parent.horizontalCenter; text: "正在准备页面…"; color: "#6366F1"; font.family: "Noto Sans CJK SC"; font.pixelSize: 18; font.weight: Font.DemiBold }
                Rectangle { anchors.horizontalCenter: parent.horizontalCenter; width: 72; height: 4; radius: 2; color: "#E0DBFC"; Rectangle { width: 28; height: parent.height; radius: 2; color: "#6366F1" } }
            }
        }
    }

    Component {
        id: wifiSettings
        Item {
            id: wifiPage
            property string expandedSsid: ""
            property string swipedSsid: ""
            property var currentNetwork: {
                for (var i = 0; i < systemBackend.wifiNetworks.length; ++i) {
                    if (systemBackend.wifiNetworks[i].active) {
                        var network = systemBackend.wifiNetworks[i]
                        if (network.signal <= 0 && systemBackend.wifiSignal > 0)
                            network.signal = systemBackend.wifiSignal
                        return network
                    }
                }
                return systemBackend.wifiConnected ? ({ssid: systemBackend.wifiName, signal: systemBackend.wifiSignal}) : ({})
            }
            function selectNetwork(network) {
                if (systemBackend.wifiOperating) return
                if (network.active) {
                    wifiPage.expandedSsid = ""
                } else if (network.saved || network.security === "开放") {
                    wifiPage.expandedSsid = ""
                    systemBackend.connectWifi(network.ssid, "")
                } else {
                    wifiPage.expandedSsid = ""
                    window.passwordDialog.openFor(network.ssid, network.security)
                }
            }
            Component.onCompleted: {
                systemBackend.scanWifi()
                if (Qt.application.arguments.indexOf("--wifi-keyboard") >= 0)
                    Qt.callLater(function() { window.passwordDialog.openFor("English Keyboard") })
                else if (Qt.application.arguments.indexOf("--wifi-keyboard-symbols") >= 0)
                    Qt.callLater(function() {
                        window.passwordDialog.openFor("Special Symbols")
                        window.passwordDialog.keyboardPage = 2
                    })
            }

            SettingsFlickable {
                anchors.fill: parent
                contentHeight: wifiColumn.height + 60
                Column {
                    id: wifiColumn
                    width: parent.width - 60
                    x: 30; y: 30
                    spacing: 16
                    RowLayout {
                        width: parent.width
                        ColumnLayout {
                            Layout.fillWidth: true
                            Text { text: "Wi-Fi"; color: "#27222D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 34; font.weight: Font.Bold }
                            Text {
                                text: systemBackend.wifiOperating
                                      ? (systemBackend.wifiOperation === "connect"
                                         ? "正在连接到 " + systemBackend.wifiOperationSsid + "…"
                                         : "正在忘记 " + systemBackend.wifiOperationSsid + "…")
                                      : (systemBackend.wifiConnected ? "已连接到 " + systemBackend.wifiName : "未连接")
                                color: systemBackend.wifiOperating ? "#7B6DF0" : "#77717D"
                                font.family: "Noto Sans CJK SC"; font.pixelSize: 18
                            }
                        }
                        Rectangle {
                            Layout.preferredWidth: 128; Layout.preferredHeight: 46; radius: 15
                            color: scanMouse.pressed ? "#6558D9" : "#7B6DF0"
                            opacity: systemBackend.wifiScanning || systemBackend.wifiOperating ? 0.62 : 1
                            Text { anchors.centerIn: parent; text: systemBackend.wifiScanning ? "正在扫描…" : "重新扫描"; color: "white"; font.family: "Noto Sans CJK SC"; font.pixelSize: 16; font.weight: Font.DemiBold }
                            MouseArea { id: scanMouse; anchors.fill: parent; enabled: !systemBackend.wifiScanning && !systemBackend.wifiOperating; onClicked: systemBackend.scanWifi() }
                        }
                    }

                    Rectangle {
                        width: parent.width
                        height: systemBackend.wifiConnected ? 238 : 112
                        radius: 24
                        color: systemBackend.wifiConnected ? "#EAF8F1" : "#F4F2F6"
                        border.color: systemBackend.wifiConnected ? "#BCE8D1" : "#E7E3EA"

                        MouseArea {
                            anchors.fill: parent; enabled: systemBackend.wifiConnected && !systemBackend.wifiOperating
                            onClicked: wifiPage.expandedSsid = ""
                        }

                        Column {
                            anchors.fill: parent; anchors.margins: 18; spacing: 10
                            RowLayout {
                                width: parent.width; spacing: 16
                                Rectangle {
                                    Layout.preferredWidth: 60; Layout.preferredHeight: 60; radius: 18
                                    color: systemBackend.wifiConnected ? window.wifiSignalColor(wifiPage.currentNetwork.signal || 0) : "#B8B4BC"
                                    Image { anchors.centerIn: parent; width: 34; height: 34; source: "qrc:/assets/icons/wifi.svg"; sourceSize.width: 68; sourceSize.height: 68 }
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true; spacing: 3
                                    Text { text: systemBackend.wifiConnected ? systemBackend.wifiName : "Wi-Fi 未连接"; color: "#27222D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 22; font.weight: Font.DemiBold; elide: Text.ElideRight; Layout.fillWidth: true }
                                    Text {
                                        text: systemBackend.wifiConnected
                                              ? window.wifiDetailText(wifiPage.currentNetwork)
                                              : "选择下方网络进行连接"
                                        color: "#77717D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 15
                                    }
                                }
                                ColumnLayout {
                                    visible: systemBackend.wifiConnected; spacing: 2
                                    Text { text: (wifiPage.currentNetwork.signal || 0) + "%"; color: window.wifiSignalColor(wifiPage.currentNetwork.signal || 0); font.family: "Noto Sans CJK SC"; font.pixelSize: 24; font.weight: Font.Bold; Layout.alignment: Qt.AlignRight }
                                    Text { text: wifiPage.currentNetwork.rate || ""; color: "#77717D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 14; Layout.alignment: Qt.AlignRight }
                                }
                            }

                            Rectangle {
                                visible: systemBackend.wifiConnected
                                width: parent.width; height: 1; color: "#BCE8D1"
                            }

                            RowLayout {
                                visible: systemBackend.wifiConnected
                                width: parent.width; height: 62; spacing: 18
                                ColumnLayout {
                                    Layout.fillWidth: true; spacing: 4
                                    Text { text: "IPv4 地址"; color: "#77717D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 13 }
                                    Text {
                                        text: systemBackend.wifiIpv4.length ? systemBackend.wifiIpv4 : "正在获取…"
                                        color: "#27222D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 17; font.weight: Font.DemiBold
                                        elide: Text.ElideRight; Layout.fillWidth: true
                                    }
                                }
                                Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 48; color: "#BCE8D1" }
                                ColumnLayout {
                                    Layout.fillWidth: true; spacing: 5
                                    Text { text: "网关 · " + (systemBackend.wifiDevice.length ? systemBackend.wifiDevice : "wlan0"); color: "#77717D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 13 }
                                    Text {
                                        text: systemBackend.wifiGateway.length ? systemBackend.wifiGateway : "--"
                                        color: "#27222D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 16; font.weight: Font.DemiBold
                                        elide: Text.ElideRight; Layout.fillWidth: true
                                    }
                                }
                            }

                            Rectangle {
                                visible: systemBackend.wifiConnected
                                width: parent.width; height: 1; color: "#BCE8D1"
                            }

                            RowLayout {
                                visible: systemBackend.wifiConnected
                                width: parent.width; height: 46; spacing: 14
                                Text {
                                    text: "已连接到 “" + systemBackend.wifiName + "”"
                                    color: "#3E8F6E"
                                    font.family: "Noto Sans CJK SC"; font.pixelSize: 14
                                    Layout.fillWidth: true; elide: Text.ElideRight
                                }
                                Rectangle {
                                    Layout.preferredWidth: 128; Layout.preferredHeight: 40; radius: 12
                                    color: forgetMouse.pressed ? "#D93645" : "#EB4D5C"
                                    opacity: systemBackend.wifiOperating ? 0.6 : 1
                                    Text { anchors.centerIn: parent; text: "忘记此网络"; color: "white"; font.family: "Noto Sans CJK SC"; font.pixelSize: 15; font.weight: Font.DemiBold }
                                    MouseArea {
                                        id: forgetMouse
                                        anchors.fill: parent
                                        enabled: !systemBackend.wifiOperating
                                        onClicked: systemBackend.forgetWifi(systemBackend.wifiName)
                                    }
                                }
                            }
                        }
                    }

                    Text { text: "附近网络"; color: "#27222D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 19; font.weight: Font.DemiBold }
                    Rectangle {
                        visible: systemBackend.wifiScanError.length > 0
                        width: parent.width; height: visible ? 52 : 0; radius: 15
                        color: "#FFF0F1"; border.color: "#FFD0D4"; border.width: 1
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 16; spacing: 10
                            Rectangle { Layout.preferredWidth: 9; Layout.preferredHeight: 9; radius: 5; color: "#E24B58" }
                            Text {
                                text: "扫描失败 · " + systemBackend.wifiScanError
                                color: "#A92F3B"; font.family: "Noto Sans CJK SC"; font.pixelSize: 15; font.weight: Font.DemiBold
                                Layout.fillWidth: true; elide: Text.ElideRight
                            }
                            Text { text: "请重试"; color: "#B43A46"; font.family: "Noto Sans CJK SC"; font.pixelSize: 14 }
                        }
                    }
                    Column {
                        id: wifiList; width: parent.width; spacing: 8
                        Repeater {
                            model: systemBackend.wifiNetworks
                            delegate: Column {
                                id: networkEntry
                                width: parent.width
                                spacing: 8
                                visible: !modelData.active
                                property real swipeOffset: 0
                                property bool userDragging: false
                                readonly property int actionWidth: 112
                                function openSwipe() { swipeOffset = -actionWidth }
                                function closeSwipe() { swipeOffset = 0 }
                                Connections {
                                    target: wifiPage
                                    function onSwipedSsidChanged() {
                                        if (wifiPage.swipedSsid !== modelData.ssid) networkEntry.closeSwipe()
                                    }
                                }
                                Rectangle {
                                    id: swipeBackdrop
                                    width: parent.width; height: 82; radius: 18
                                    color: "#F9F9FB"; border.color: "#E7E3EA"; border.width: 1
                                    clip: true
                                    Rectangle {
                                        id: forgetAction
                                        anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
                                        width: networkEntry.actionWidth
                                        color: forgetActionMouse.pressed ? "#D93645" : "#EB4D5C"
                                        visible: networkEntry.swipeOffset < -1 && modelData.saved
                                                 && !(systemBackend.wifiOperating && systemBackend.wifiOperationSsid === modelData.ssid)
                                        Text { anchors.centerIn: parent; text: "忘记网络"; color: "white"; font.family: "Noto Sans CJK SC"; font.pixelSize: 15; font.weight: Font.DemiBold }
                                        MouseArea {
                                            id: forgetActionMouse
                                            anchors.fill: parent
                                            enabled: visible && !systemBackend.wifiOperating
                                            onClicked: {
                                                wifiPage.swipedSsid = ""
                                                networkEntry.closeSwipe()
                                                systemBackend.forgetWifi(modelData.ssid)
                                            }
                                        }
                                    }
                                    Rectangle {
                                        x: networkCard.x + networkCard.width - 20
                                        width: 20; height: networkCard.height
                                        color: networkCard.color
                                        visible: networkEntry.swipeOffset < -1
                                    }
                                    Rectangle {
                                        id: networkCard
                                        width: parent.width; height: 82; radius: 18
                                        color: networkMouse.pressed ? "#EEEAFE" : "#F9F9FB"
                                        border.color: "#E7E3EA"
                                        border.width: networkEntry.swipeOffset < -1 ? 0 : 1
                                        opacity: systemBackend.wifiOperating ? 0.72 : 1
                                        x: networkEntry.swipeOffset
                                        Behavior on x {
                                            enabled: !networkEntry.userDragging
                                            NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
                                        }
                                        MouseArea {
                                            id: networkMouse
                                            anchors.fill: parent
                                            enabled: !systemBackend.wifiOperating
                                            property real pressX: 0
                                            property real pressY: 0
                                            property real startOffset: 0
                                            property bool mayDrag: false
                                            property bool hadOpenCard: false
                                            onPressed: {
                                                pressX = mouse.x
                                                pressY = mouse.y
                                                startOffset = networkEntry.swipeOffset
                                                mayDrag = false
                                                hadOpenCard = wifiPage.swipedSsid !== ""
                                                if (hadOpenCard && wifiPage.swipedSsid !== modelData.ssid) wifiPage.swipedSsid = ""
                                            }
                                            onPositionChanged: {
                                                if (!pressed) return
                                                if (!modelData.saved) return
                                                var dx = mouse.x - pressX
                                                var dy = mouse.y - pressY
                                                if (!mayDrag && Math.abs(dx) > 14 && Math.abs(dx) > Math.abs(dy)) {
                                                    mayDrag = true
                                                    networkEntry.userDragging = true
                                                }
                                                if (mayDrag) {
                                                    var w = networkEntry.actionWidth
                                                    var nx = Math.max(-w, Math.min(0, startOffset + (mouse.x - pressX)))
                                                    networkEntry.swipeOffset = nx
                                                }
                                            }
                                            onReleased: {
                                                if (mayDrag) {
                                                    var w = networkEntry.actionWidth
                                                    var open = networkEntry.swipeOffset <= -w / 2
                                                    networkEntry.userDragging = false
                                                    networkEntry.swipeOffset = open ? -w : 0
                                                    wifiPage.swipedSsid = open ? modelData.ssid : ""
                                                } else if (wifiPage.swipedSsid === modelData.ssid) {
                                                    wifiPage.swipedSsid = ""
                                                    networkEntry.closeSwipe()
                                                } else if (hadOpenCard) {
                                                    wifiPage.selectNetwork(modelData)
                                                } else {
                                                    wifiPage.selectNetwork(modelData)
                                                }
                                            }
                                            onCanceled: {
                                                if (mayDrag) {
                                                    var w = networkEntry.actionWidth
                                                    var open = networkEntry.swipeOffset <= -w / 2
                                                    networkEntry.userDragging = false
                                                    networkEntry.swipeOffset = open ? -w : 0
                                                    wifiPage.swipedSsid = open ? modelData.ssid : ""
                                                }
                                            }
                                        }
                                        RowLayout {
                                            anchors.fill: parent; anchors.margins: 13; spacing: 13
                                            Rectangle {
                                                Layout.preferredWidth: 48; Layout.preferredHeight: 48; radius: 14
                                                color: window.wifiSignalColor(modelData.signal)
                                                Image { anchors.centerIn: parent; width: 27; height: 27; source: "qrc:/assets/icons/wifi.svg"; sourceSize.width: 54; sourceSize.height: 54 }
                                            }
                                            ColumnLayout {
                                                Layout.fillWidth: true; spacing: 2
                                                RowLayout {
                                                    Layout.fillWidth: true
                                                    Text { text: modelData.ssid; color: "#27222D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 19; font.weight: Font.DemiBold; elide: Text.ElideRight; Layout.fillWidth: true }
                                                    Text {
                                                        visible: systemBackend.wifiOperating && systemBackend.wifiOperationSsid === modelData.ssid
                                                        text: systemBackend.wifiOperation === "connect" ? "连接中…" : "处理中…"
                                                        color: "#7B6DF0"; font.family: "Noto Sans CJK SC"; font.pixelSize: 13; font.weight: Font.DemiBold
                                                    }
                                                    Rectangle {
                                                        visible: modelData.saved && !(systemBackend.wifiOperating && systemBackend.wifiOperationSsid === modelData.ssid)
                                                        Layout.preferredWidth: 62; Layout.preferredHeight: 30; radius: 10
                                                        color: manageMouse.pressed ? "#DED8FF" : "#EEEAFE"
                                                        Text { anchors.centerIn: parent; text: "已保存"; color: "#6555D5"; font.family: "Noto Sans CJK SC"; font.pixelSize: 13; font.weight: Font.DemiBold }
                                                        MouseArea {
                                                            id: manageMouse
                                                            anchors.fill: parent
                                                            onClicked: wifiPage.expandedSsid = (wifiPage.expandedSsid === modelData.ssid ? "" : modelData.ssid)
                                                        }
                                                    }
                                                }
                                                Text { text: window.wifiDetailText(modelData); color: "#77717D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 14; elide: Text.ElideRight; Layout.fillWidth: true }
                                            }
                                            ColumnLayout {
                                                spacing: 2
                                                Text { text: modelData.signal + "%"; color: window.wifiSignalColor(modelData.signal); font.family: "Noto Sans CJK SC"; font.pixelSize: 18; font.weight: Font.Bold; Layout.alignment: Qt.AlignRight }
                                                Text { text: modelData.rate; color: "#77717D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 13; Layout.alignment: Qt.AlignRight }
                                            }
                                        }
                                    }
                                }
                                WifiManagePanel {
                                    id: managePanel
                                    width: parent.width
                                    expanded: wifiPage.expandedSsid === modelData.ssid
                                    onForget: systemBackend.forgetWifi(modelData.ssid)
                                    onReenter: { wifiPage.expandedSsid = ""; window.passwordDialog.openFor(modelData.ssid, modelData.security) }
                                    onConnect: { wifiPage.expandedSsid = ""; systemBackend.connectWifi(modelData.ssid, "") }
                                }
                            }
                        }
                        Text {
                            visible: !systemBackend.wifiScanning
                                     && systemBackend.wifiScanError.length === 0
                                     && systemBackend.wifiNetworks.length <= (systemBackend.wifiConnected ? 1 : 0)
                            width: parent.width; horizontalAlignment: Text.AlignHCenter
                            text: "没有发现其他网络"
                            color: "#77717D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 16
                            topPadding: 24
                        }
                    }
                }
            }
        }
    }

    Component {
        id: ethernetSettings
        Item {
            id: ethernetPage
            readonly property int connectedCount: {
                var count = 0
                for (var i = 0; i < systemBackend.ethernetPorts.length; ++i) {
                    if (systemBackend.ethernetPorts[i].connected) ++count
                }
                return count
            }
            readonly property string connectionSummary: connectedCount === 0
                                                        ? "两个网口均未连接"
                                                        : (connectedCount === 1
                                                           ? "已连接 1 个网口"
                                                           : "两个网口均已连接")
            property bool openedCaptureDialog: false
            function openFirstPortForCapture() {
                if (!openedCaptureDialog && Qt.application.arguments.indexOf("--ethernet-config") >= 0
                        && systemBackend.ethernetPorts.length > 0) {
                    openedCaptureDialog = true
                    window.ethernetDialog.openFor(systemBackend.ethernetPorts[0])
                }
            }
            Connections {
                target: systemBackend
                function onEthernetChanged() { ethernetPage.openFirstPortForCapture() }
            }
            Component.onCompleted: {
                if (Qt.application.arguments.indexOf("--ethernet-config") >= 0) {
                    openedCaptureDialog = true
                    Qt.callLater(function() {
                        window.ethernetDialog.openFor(systemBackend.ethernetPorts.length > 0
                                               ? systemBackend.ethernetPorts[0]
                                               : ({ name: "eth0", connected: false, method: "auto" }))
                    })
                }
            }

            SettingsFlickable {
                anchors.fill: parent
                contentHeight: ethernetCol.height + 60

                Column {
                    id: ethernetCol
                    width: parent.width - 60
                    x: 30; y: 30
                    spacing: 16

                    RowLayout {
                        width: parent.width
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 2
                            Text { text: "有线网络"; color: "#27222D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 34; font.weight: Font.Bold }
                            Text { text: ethernetPage.connectionSummary; color: "#77717D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 18 }
                        }
                        Rectangle {
                            Layout.preferredWidth: 134; Layout.preferredHeight: 42; radius: 14
                            color: "#EDF5FF"
                            Row {
                                anchors.centerIn: parent; spacing: 8
                                Rectangle { width: 9; height: 9; radius: 5; color: ethernetPage.connectedCount > 0 ? "#34C759" : "#8E98A8"; anchors.verticalCenter: parent.verticalCenter }
                                Text { text: "2 个物理接口"; color: "#41678F"; font.family: "Noto Sans CJK SC"; font.pixelSize: 15; font.weight: Font.DemiBold }
                            }
                        }
                    }

                    Column {
                        width: parent.width; spacing: 14
                        Repeater {
                            model: systemBackend.ethernetPorts
                            delegate: EthernetPortCard {
                                width: parent.width
                                port: modelData
                                portNumber: index + 1
                                accent: index === 0 ? "#438DE5" : "#8B68E8"
                                tint: index === 0 ? "#F0F7FF" : "#F7F2FF"
                                outline: index === 0 ? "#C9E1FA" : "#DED0F8"
                                onConfigureRequested: window.ethernetDialog.openFor(modelData)
                            }
                        }
                        Text {
                            visible: systemBackend.ethernetPorts.length === 0
                            width: parent.width; topPadding: 80
                            horizontalAlignment: Text.AlignHCenter
                            text: "正在读取网口状态…"
                            color: "#77717D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 17
                        }
                    }
                }
            }
        }
    }

    Component {
        id: batterySettings
        SettingsFlickable {
            anchors.fill: parent
            contentHeight: batteryCol.height + 60

            Column {
                id: batteryCol
                width: parent.width - 60
                x: 30; y: 30
                spacing: 16

                RowLayout {
                    width: parent.width
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 2
                        Text { text: "电池"; color: "#27222D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 34; font.weight: Font.Bold }
                        Text {
                            text: systemBackend.batteryAvailable ? window.batteryStateText(systemBackend.batteryStatus)
                                                                  : (systemBackend.chargerAvailable ? "充电管理已连接，电量监测未连接" : "暂未检测到电池硬件")
                            color: "#77717D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 18
                        }
                    }
                }

                RowLayout {
                    width: parent.width
                    spacing: 28
                    Item {
                        Layout.preferredWidth: 238; Layout.preferredHeight: 118
                        Rectangle {
                            id: detailBatteryBody
                            x: 5; y: 7; width: 214; height: 104; radius: 22
                            color: systemBackend.batteryCharging ? "#E5F6EC" : "#E5E5EA"
                            border.width: 5
                            border.color: window.batteryOutlineColor()
                            clip: true
                            Rectangle {
                                id: detailBatteryFill
                                x: 8; y: 8; height: detailBatteryBody.height - 16
                                width: systemBackend.batteryPercent >= 0
                                       ? (detailBatteryBody.width - 16) * systemBackend.batteryPercent / 100 : 0
                                radius: 14
                                color: window.batteryFillColor()
                            }
                            Row {
                                id: detailBatteryLabelBase
                                anchors.centerIn: parent
                                spacing: systemBackend.batteryCharging ? 9 : 0
                                Image {
                                    visible: systemBackend.batteryCharging
                                    width: 26; height: 26
                                    anchors.verticalCenter: parent.verticalCenter
                                    source: systemBackend.batteryCharging
                                            ? "qrc:/assets/icons/zap-green.svg"
                                            : "qrc:/assets/icons/zap-dark.svg"
                                    sourceSize.width: 52; sourceSize.height: 52
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: systemBackend.batteryPercent >= 0 ? systemBackend.batteryPercent + "%" : "--"
                                    color: systemBackend.batteryCharging ? "#16733F" : "#3A3540"
                                    font.family: "Noto Sans CJK SC"; font.pixelSize: 36; font.weight: Font.Bold
                                }
                            }
                            Item {
                                visible: !systemBackend.batteryCharging
                                x: 0; y: 0
                                width: detailBatteryFill.x + detailBatteryFill.width
                                height: detailBatteryBody.height
                                clip: true
                                Row {
                                    x: detailBatteryLabelBase.x
                                    y: detailBatteryLabelBase.y
                                    spacing: detailBatteryLabelBase.spacing
                                    Image {
                                        visible: systemBackend.batteryCharging
                                        width: 26; height: 26
                                        anchors.verticalCenter: parent.verticalCenter
                                        source: "qrc:/assets/icons/zap-white.svg"
                                        sourceSize.width: 52; sourceSize.height: 52
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: systemBackend.batteryPercent >= 0 ? systemBackend.batteryPercent + "%" : "--"
                                        color: !systemBackend.batteryCharging
                                               && systemBackend.batteryPercent > 20
                                               && systemBackend.batteryPercent <= 40
                                               ? "#3A3540" : "white"
                                        font.family: "Noto Sans CJK SC"; font.pixelSize: 36; font.weight: Font.Bold
                                    }
                                }
                            }
                        }
                        Rectangle {
                            x: 223; y: 44; width: 9; height: 30; radius: 4
                            color: window.batteryOutlineColor()
                        }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 7
                        Text { text: window.batteryStateText(systemBackend.batteryStatus); color: "#27222D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 27; font.weight: Font.DemiBold }
                        Text {
                            text: window.batteryPowerLabel() + (systemBackend.batteryTemperatureC > -100
                                  ? "  ·  " + systemBackend.batteryTemperatureC.toFixed(1) + " °C" : "")
                            color: window.batteryPowerColor()
                            font.family: "Noto Sans CJK SC"; font.pixelSize: 18; font.weight: Font.DemiBold
                        }
                    }
                }
                IosGroup {
                    width: parent.width
                    IosInfoRow { height: 50; label: "充放电状态"; value: window.batteryStateText(systemBackend.batteryStatus) }
                    IosInfoRow {
                        height: 50; label: "实时功率"
                        value: systemBackend.batteryPowerW >= 0 ? window.batteryPowerLabel() : "--"
                        valueColor: window.batteryPowerColor()
                        emphasize: true
                    }
                    IosInfoRow { height: 50; label: "当前电压"; value: systemBackend.batteryVoltageMv >= 0 ? (systemBackend.batteryVoltageMv / 1000).toFixed(3) + " V" : "--" }
                    IosInfoRow { height: 50; label: "当前电流"; value: systemBackend.powerManagement.currentValid ? systemBackend.batteryCurrentMa + " mA" : "--" }
                    IosInfoRow { height: 50; label: "外部电源"; value: systemBackend.powerManagement.externalPowerKnown ? (systemBackend.externalPowerPresent ? "已接入" : "未接入") : "--" }
                    IosInfoRow { height: 50; label: "电量计内部温度"; value: systemBackend.batteryTemperatureC > -100 ? systemBackend.batteryTemperatureC.toFixed(1) + " °C" : "--"; last: true }
                }

                Rectangle {
                    width: parent.width; height: powerNotice.implicitHeight + 32; radius: 18
                    color: "#FEF6E9"; border.color: "#F4DCAE"
                    Text {
                        id: powerNotice; anchors.fill: parent; anchors.margins: 16
                        text: (systemBackend.powerManagement.message || "等待电源后台服务")
                              + "\n电量百分比为电量计估算；实际电池容量与配置尚未核实。"
                        wrapMode: Text.WordWrap; color: "#98651B"; font.family: window.uiFont; font.pixelSize: 14
                    }
                }
                IosGroup {
                    width: parent.width
                    IosInfoRow { height: 50; label: "后台保护"; value: systemBackend.powerManagement.fresh ? (systemBackend.powerManagement.status || "未知") : "快照无效 / 服务离线"; emphasize: true }
                    IosInfoRow { height: 50; label: "采样年龄"; value: systemBackend.powerManagement.fresh ? systemBackend.powerManagement.sampleAgeSeconds.toFixed(1) + " 秒" : "--" }
                    IosInfoRow { height: 50; label: "电量估算可信度"; value: systemBackend.powerManagement.socConfidence === "inconsistent" ? "读数不一致" : (systemBackend.powerManagement.socConfidence === "unverified" ? "容量配置未核实" : "不可用") }
                    IosInfoRow { height: 50; label: "板载温控温度"; value: systemBackend.powerManagement.boardTemperatureC > -100 ? systemBackend.powerManagement.boardTemperatureC.toFixed(1) + " °C" : "--" }
                    IosInfoRow { height: 50; label: "温度来源"; value: systemBackend.powerManagement.temperatureSource || "未知"; last: true }
                }
                IosGroup {
                    width: parent.width
                    IosInfoRow { height: 50; label: "电量计通信"; value: systemBackend.gaugeCommunication ? "BQ27220 在线 · 只读" : systemBackend.gaugeError; emphasize: true }
                    IosInfoRow { height: 50; label: "原始电压"; value: systemBackend.powerManagement.voltageValid ? systemBackend.batteryRawVoltageMv + " mV" : "--" }
                    IosInfoRow { height: 50; label: "原始电流"; value: systemBackend.powerManagement.currentValid ? systemBackend.batteryRawCurrentMa + " mA" : "--" }
                    IosInfoRow { height: 50; label: "剩余容量 RM"; value: systemBackend.batteryRemainingMah >= 0 ? systemBackend.batteryRemainingMah + " mAh" : "--" }
                    IosInfoRow { height: 50; label: "满充配置 FCC"; value: systemBackend.batteryFullChargeMah >= 0 ? systemBackend.batteryFullChargeMah + " mAh" : "--" }
                    IosInfoRow { height: 50; label: "电量计设计容量配置"; value: systemBackend.batteryDesignCapacityMah >= 0 ? systemBackend.batteryDesignCapacityMah + " mAh · 未核实" : "未知"; last: true }
                }
                IosGroup {
                    width: parent.width
                    IosInfoRow { height: 50; label: "充电器遥测"; value: systemBackend.chargerAvailable ? "SGM41511 在线 · 只读" : "未知"; emphasize: true }
                    IosInfoRow { height: 50; label: "输入限流寄存器"; value: systemBackend.chargerInputLimitMa >= 0 ? systemBackend.chargerInputLimitMa + " mA" : "--" }
                    IosInfoRow { height: 50; label: "充电电流寄存器"; value: systemBackend.chargerFastCurrentMa >= 0 ? systemBackend.chargerFastCurrentMa + " mA" : "--" }
                    IosInfoRow { height: 50; label: "充电 NTC 状态"; value: window.temperatureZoneText(systemBackend.chargeTemperatureZone); last: true }
                }
                Rectangle {
                    width: parent.width; height: eventText.implicitHeight + 32; radius: 18; color: "#F6F5FC"
                    Text {
                        id: eventText; anchors.fill: parent; anchors.margins: 16
                        text: "后台事件\n" + ((systemBackend.powerManagement.events || []).join("\n") || "暂无事件")
                        wrapMode: Text.WordWrap; color: "#655B76"; font.family: window.uiFont; font.pixelSize: 14
                    }
                }
            }
        }
    }

    Component {
        id: soundSettings
        SettingsFlickable {
            anchors.fill: parent
            contentHeight: soundCol.height + 60

            Column {
                id: soundCol
                width: parent.width - 60
                x: 30; y: 30
                spacing: 16

                RowLayout {
                    width: parent.width
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 2
                        Text { text: "声音"; color: "#27222D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 34; font.weight: Font.Bold }
                        Text { text: systemBackend.audioAvailable ? "内置扬声器与音量调节" : "音频输出尚未就绪"; color: "#77717D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 18 }
                    }
                }

                // Unified Sound & Volume Card
                Rectangle {
                    width: parent.width; height: 168; radius: 22
                    color: "#FFF7FA"; border.color: "#F3D5E1"; border.width: 1

                    Column {
                        anchors.fill: parent; anchors.margins: 20; spacing: 16

                        RowLayout {
                            width: parent.width; spacing: 16
                            Rectangle {
                                Layout.preferredWidth: 48; Layout.preferredHeight: 48; radius: 15
                                color: "#FF7FA7"
                                Image { anchors.centerIn: parent; width: 26; height: 26; source: "qrc:/assets/icons/volume-2.svg"; sourceSize.width: 52; sourceSize.height: 52 }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 2
                                Text { text: "输出设备 · 内置扬声器"; color: "#27222D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 18; font.weight: Font.DemiBold }
                                Text { text: systemBackend.audioAvailable ? "音频输出正常" : "未检测到音频设备"; color: "#B35A78"; font.family: "Noto Sans CJK SC"; font.pixelSize: 14 }
                            }
                            Text {
                                text: systemBackend.volumePercent >= 0 ? systemBackend.volumePercent + "%" : "--"
                                color: "#FF7FA7"; font.family: "Noto Sans CJK SC"; font.pixelSize: 26; font.weight: Font.Bold
                            }
                        }

                        RowLayout {
                            width: parent.width; spacing: 14
                            Image { Layout.preferredWidth: 24; Layout.preferredHeight: 24; source: "qrc:/assets/icons/volume-2.svg"; sourceSize.width: 48; sourceSize.height: 48; opacity: volumeSlider.enabled ? 1 : 0.3 }
                            Slider {
                                id: volumeSlider
                                Layout.fillWidth: true; Layout.preferredHeight: 34
                                from: 0; to: 100; stepSize: 1; live: true
                                enabled: systemBackend.audioAvailable
                                value: systemBackend.volumePercent >= 0 ? systemBackend.volumePercent : 0
                                onMoved: systemBackend.setVolume(Math.round(value))
                                onPressedChanged: if (!pressed && enabled) systemBackend.playVolumeFeedback()
                                background: Rectangle {
                                    x: volumeSlider.leftPadding
                                    y: volumeSlider.topPadding + volumeSlider.availableHeight / 2 - height / 2
                                    width: volumeSlider.availableWidth; height: 7; radius: 4
                                    color: "#F0D5DF"
                                    Rectangle {
                                        width: volumeSlider.visualPosition * parent.width; height: parent.height; radius: parent.radius
                                        color: "#FF7FA7"
                                    }
                                }
                                handle: Rectangle {
                                    x: volumeSlider.leftPadding + volumeSlider.visualPosition * (volumeSlider.availableWidth - width)
                                    y: volumeSlider.topPadding + volumeSlider.availableHeight / 2 - height / 2
                                    width: 26; height: 26; radius: 13
                                    color: "white"; border.color: "#E7B8C8"; border.width: 1
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Component {
        id: displaySettings
        Item {
            id: displayPage
            Component.onCompleted: {
                if (Qt.application.arguments.indexOf("--display-scroll") >= 0)
                    displayFlick.contentY = 240
            }
            SettingsFlickable {
                id: displayFlick
                anchors.fill: parent
                contentHeight: displayCol.height + 60

                Column {
                    id: displayCol
                    width: parent.width - 60; x: 30; y: 30; spacing: 16

                    // 1. Header
                    RowLayout {
                        width: parent.width
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 2
                            Text { text: "显示与触摸"; color: "#27222D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 30; font.weight: Font.Bold }
                            Text { text: "屏幕亮度、自动息屏与低功耗休眠策略"; color: "#77717D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 15 }
                        }
                    }

                    // 2. Screen Info Card
                    Rectangle {
                        width: parent.width; height: 92; radius: 20
                        color: "#F3F0FF"; border.color: "#D9D2FA"; border.width: 1
                        RowLayout {
                            anchors.fill: parent; anchors.margins: 16; spacing: 16
                            Rectangle {
                                Layout.preferredWidth: 56; Layout.preferredHeight: 56; radius: 17
                                color: "#7B6DF0"
                                Image { anchors.centerIn: parent; width: 30; height: 30; source: "qrc:/assets/icons/monitor.svg"; sourceSize.width: 60; sourceSize.height: 60 }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 2
                                Text { text: "屏幕分辨率"; color: "#27222D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 18; font.weight: Font.DemiBold }
                                Text { text: "1280 × 800 (16:10 宽屏)"; color: "#6A5CC4"; font.family: "Noto Sans CJK SC"; font.pixelSize: 14 }
                            }
                            Text {
                                text: systemBackend.brightnessAvailable ? systemBackend.displayBrightnessPercent + "%" : "--"
                                color: "#7B6DF0"; font.family: "Noto Sans CJK SC"; font.pixelSize: 26; font.weight: Font.Bold
                            }
                        }
                    }

                    // 3. Brightness Slider Card
                    Rectangle {
                        width: parent.width; height: 124; radius: 18
                        color: "#F7F5FF"; border.color: "#DDD7F5"; border.width: 1
                        Column {
                            anchors.fill: parent; anchors.margins: 16; spacing: 12
                            RowLayout {
                                width: parent.width
                                Text { text: "亮度调节"; color: "#27222D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 17; font.weight: Font.DemiBold; Layout.fillWidth: true }
                                Text { text: systemBackend.brightnessAvailable ? systemBackend.displayBrightnessPercent + "%" : "--"; color: "#7B6DF0"; font.family: "Noto Sans CJK SC"; font.pixelSize: 17; font.weight: Font.DemiBold }
                            }
                            RowLayout {
                                width: parent.width; spacing: 14
                                Image { Layout.preferredWidth: 24; Layout.preferredHeight: 24; source: "qrc:/assets/icons/sun.svg"; sourceSize.width: 48; sourceSize.height: 48; opacity: brightnessSlider.enabled ? 1 : 0.3 }
                                Slider {
                                    id: brightnessSlider
                                    Layout.fillWidth: true; Layout.preferredHeight: 34
                                    from: 10; to: 100; stepSize: 1; live: true
                                    enabled: systemBackend.brightnessAvailable
                                    value: systemBackend.displayBrightnessPercent >= 0 ? systemBackend.displayBrightnessPercent : 10
                                    onMoved: systemBackend.setDisplayBrightness(Math.round(value))
                                    background: Rectangle {
                                        x: brightnessSlider.leftPadding
                                        y: brightnessSlider.topPadding + brightnessSlider.availableHeight / 2 - height / 2
                                        width: brightnessSlider.availableWidth; height: 7; radius: 4
                                        color: "#DDD8EF"
                                        Rectangle {
                                            width: brightnessSlider.visualPosition * parent.width; height: parent.height; radius: parent.radius
                                            color: "#7B6DF0"
                                        }
                                    }
                                    handle: Rectangle {
                                        x: brightnessSlider.leftPadding + brightnessSlider.visualPosition * (brightnessSlider.availableWidth - width)
                                        y: brightnessSlider.topPadding + brightnessSlider.availableHeight / 2 - height / 2
                                        width: 26; height: 26; radius: 13
                                        color: "white"; border.color: "#C9C1E8"; border.width: 1
                                    }
                                }
                            }
                        }
                    }

                    // 4. Auto Sleep Timeout Card
                    Rectangle {
                        width: parent.width; height: 124; radius: 20
                        color: "#F7F5FF"; border.color: "#DDD7F5"; border.width: 1
                        Column {
                            id: sleepCardCol
                            width: parent.width - 32; x: 16; y: 16
                            spacing: 14

                            RowLayout {
                                width: parent.width
                                ColumnLayout {
                                    Layout.fillWidth: true; spacing: 2
                                    Text { text: "自动息屏休眠"; color: "#27222D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 18; font.weight: Font.DemiBold }
                                    Text { text: "无操作时关闭背光进入低功耗状态，轻触屏幕任意位置唤醒"; color: "#77717D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 13 }
                                }
                                Rectangle {
                                    Layout.preferredWidth: 106; Layout.preferredHeight: 36; radius: 18
                                    color: sleepNowMouse.pressed ? "#6354D4" : "#7B6DF0"
                                    Row {
                                        anchors.centerIn: parent; spacing: 4
                                        Text { text: "立即息屏"; color: "white"; font.family: "Noto Sans CJK SC"; font.pixelSize: 13; font.weight: Font.DemiBold }
                                    }
                                    MouseArea {
                                        id: sleepNowMouse
                                        anchors.fill: parent
                                        onClicked: systemBackend.setScreenSleeping(true)
                                    }
                                }
                            }

                            RowLayout {
                                width: parent.width; spacing: 10
                                Repeater {
                                    model: [
                                        { text: "30 秒", value: 30, index: 0 },
                                        { text: "1 分钟", value: 60, index: 1 },
                                        { text: "3 分钟", value: 180, index: 2 },
                                        { text: "从不", value: 0, index: 3 }
                                    ]
                                    delegate: Rectangle {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 42
                                        radius: 12
                                        readonly property bool selected: systemBackend.sleepTimeoutSeconds === modelData.value
                                        color: selected ? "#7B6DF0" : (pillMouse.pressed ? "#ECE7FC" : "#FFFFFF")
                                        border.color: selected ? "#7B6DF0" : "#D8D2F2"
                                        border.width: 1.5

                                        Text {
                                            anchors.centerIn: parent
                                            text: modelData.text
                                            color: selected ? "white" : "#27222D"
                                            font.family: "Noto Sans CJK SC"
                                            font.pixelSize: 14
                                            font.weight: selected ? Font.Bold : Font.Medium
                                        }

                                        MouseArea {
                                            id: pillMouse
                                            anchors.fill: parent
                                            preventStealing: true
                                            onClicked: systemBackend.setSleepTimeoutSeconds(modelData.value)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // 5. System Sleep Power Level (系统级休眠低功耗等级)
                    Rectangle {
                        width: parent.width; height: 158; radius: 20
                        color: "#F7F5FF"; border.color: "#DDD7F5"; border.width: 1
                        Column {
                            id: sleepLevelCol
                            width: parent.width - 32; x: 16; y: 16
                            spacing: 12

                            ColumnLayout {
                                width: parent.width; spacing: 2
                                Text { text: "息屏节能方式"; color: "#27222D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 18; font.weight: Font.DemiBold }
                                Text { text: "由电源后台统一协调息屏节能与温控限制"; color: "#77717D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 13 }
                            }

                            RowLayout {
                                width: parent.width; spacing: 12

                                // Level 0: Standard Blank
                                Rectangle {
                                    id: cardLevel0
                                    Layout.fillWidth: true; Layout.preferredHeight: 74; radius: 14
                                    readonly property bool selected: systemBackend.sleepPowerLevel === 0
                                    color: cardLevel0.selected ? "#EDE8FF" : (level0Mouse.pressed ? "#F0EEF8" : "#FFFFFF")
                                    border.color: cardLevel0.selected ? "#7B6DF0" : "#DBD5F0"
                                    border.width: cardLevel0.selected ? 2 : 1
                                    RowLayout {
                                        anchors.fill: parent; anchors.margins: 12; spacing: 10
                                        Rectangle {
                                            Layout.preferredWidth: 38; Layout.preferredHeight: 38; radius: 19
                                            color: cardLevel0.selected ? "#7B6DF0" : "#EBE6F8"
                                            Image {
                                                anchors.centerIn: parent; width: 20; height: 20
                                                source: "qrc:/assets/icons/monitor.svg"; sourceSize.width: 40; sourceSize.height: 40
                                            }
                                        }
                                        ColumnLayout {
                                            Layout.fillWidth: true; spacing: 1
                                            Text { text: "标准息屏"; color: "#27222D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 15; font.weight: Font.DemiBold }
                                            Text { text: "仅关闭背光 · 快速毫秒唤醒"; color: "#77717D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 12 }
                                        }
                                    }
                                    MouseArea { id: level0Mouse; anchors.fill: parent; preventStealing: true; onClicked: systemBackend.setSleepPowerLevel(0) }
                                }

                                // Level 1: Deep System Sleep
                                Rectangle {
                                    id: cardLevel1
                                    Layout.fillWidth: true; Layout.preferredHeight: 74; radius: 14
                                    readonly property bool selected: systemBackend.sleepPowerLevel === 1
                                    color: cardLevel1.selected ? "#EDE8FF" : (level1Mouse.pressed ? "#F0EEF8" : "#FFFFFF")
                                    border.color: cardLevel1.selected ? "#7B6DF0" : "#DBD5F0"
                                    border.width: cardLevel1.selected ? 2 : 1
                                    RowLayout {
                                        anchors.fill: parent; anchors.margins: 12; spacing: 10
                                        Rectangle {
                                            Layout.preferredWidth: 38; Layout.preferredHeight: 38; radius: 19
                                            color: cardLevel1.selected ? "#7B6DF0" : "#EBE6F8"
                                            Image {
                                                anchors.centerIn: parent; width: 20; height: 20
                                                source: "qrc:/assets/icons/zap-white.svg"; sourceSize.width: 40; sourceSize.height: 40
                                            }
                                        }
                                        ColumnLayout {
                                            Layout.fillWidth: true; spacing: 1
                                            Text { text: "息屏后台节能"; color: "#27222D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 15; font.weight: Font.DemiBold }
                                            Text { text: "请求 CPU 上限 408MHz · 后台仲裁"; color: "#77717D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 12 }
                                        }
                                    }
                                    MouseArea { id: level1Mouse; anchors.fill: parent; preventStealing: true; onClicked: systemBackend.setSleepPowerLevel(1) }
                                }
                            }
                        }
                    }

                    // 6. App Keep Screen On Whitelist (应用抢占不息屏权限)
                    Rectangle {
                        width: parent.width; height: 340; radius: 20
                        color: "#F7F5FF"; border.color: "#DDD7F5"; border.width: 1
                        Column {
                            id: appWakeLockCol
                            width: parent.width - 32; x: 16; y: 16
                            spacing: 12

                            ColumnLayout {
                                width: parent.width; spacing: 2
                                Text { text: "应用抢占不息屏权限"; color: "#27222D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 18; font.weight: Font.DemiBold }
                                Text { text: "允许指定应用在前台处于活动状态时阻止系统自动息屏"; color: "#77717D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 13 }
                            }

                            Column {
                                width: parent.width; spacing: 8
                                Repeater {
                                    model: [
                                        { appId: "mindustry", title: "像素工厂", icon: "qrc:/assets/icons/mindustry.png", desc: "建造与战斗过程中保持屏幕常亮", accent: "#59616A" },
                                        { appId: "touch-test", title: "点击测试", icon: "qrc:/assets/icons/mouse-pointer-click.svg", desc: "触摸多点测试中保持屏幕常亮", accent: "#FF4D6D" },
                                        { appId: "reaction-game", title: "喵喵反应", icon: "qrc:/assets/icons/zap-white.svg", desc: "极速反应挑战中保持屏幕常亮", accent: "#F59E0B" },
                                        { appId: "files", title: "文件管理", icon: "qrc:/assets/icons/folder.svg", desc: "长文档阅读与文件传输时保持常亮", accent: "#3B82F6" },
                                        { appId: "settings", title: "系统设置", icon: "qrc:/assets/icons/settings.svg", desc: "系统调优与监控中保持常亮", accent: "#8B5CF6" }
                                    ]
                                    delegate: Rectangle {
                                        width: parent.width; height: 58; radius: 14
                                        color: "#FFFFFF"; border.color: "#E5E1F4"; border.width: 1
                                        readonly property bool allowed: systemBackend.keepScreenOnApps.indexOf(modelData.appId) >= 0

                                        RowLayout {
                                            anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 12
                                            Rectangle {
                                                Layout.preferredWidth: 36; Layout.preferredHeight: 36; radius: 10
                                                color: modelData.accent
                                                Image {
                                                    anchors.centerIn: parent; width: 20; height: 20
                                                    source: modelData.icon; sourceSize.width: 40; sourceSize.height: 40
                                                }
                                            }
                                            ColumnLayout {
                                                Layout.fillWidth: true; spacing: 1
                                                Text { text: modelData.title; color: "#27222D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 15; font.weight: Font.DemiBold }
                                                Text { text: modelData.desc; color: "#77717D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 12 }
                                            }
                                             // Decoupled iOS Switch Toggle
                                             IosSwitch {
                                                 checked: allowed
                                                 onToggled: systemBackend.setAppKeepScreenOn(modelData.appId, isChecked)
                                             }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Component {
        id: performanceSettings
        Item {
            id: performancePage
            function historyValues(key) {
                var values = []
                var history = systemBackend.performanceHistory
                for (var i = 0; i < history.length; ++i) {
                    var value = history[i][key]
                    values.push(value >= 0 ? value : 0)
                }
                return values
            }
            readonly property int logicalCoreCount: Math.max(0, systemBackend.cpuUsage.length - 1)

            SettingsFlickable {
                id: performanceFlick
                anchors.fill: parent
                contentHeight: performanceColumn.height + 60

                Column {
                    id: performanceColumn
                    width: parent.width - 60; x: 30; y: 30; spacing: 16

                    // 1. Title Header & Realtime Pulse Badge
                    RowLayout {
                        width: parent.width
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 2
                            Text { text: "性能监控"; color: "#0F172A"; font.family: "Noto Sans CJK SC"; font.pixelSize: 30; font.weight: Font.Bold }
                            Text { text: "中央处理器、图形算力与系统资源动态"; color: "#64748B"; font.family: "Noto Sans CJK SC"; font.pixelSize: 15 }
                        }
                        Rectangle {
                            Layout.preferredHeight: 34
                            Layout.preferredWidth: liveStatusText.implicitWidth + 24
                            radius: 17
                            color: systemBackend.cpuTemperatureC >= 80 ? "#FEF2F2" : "#ECFDF5"
                            border.color: systemBackend.cpuTemperatureC >= 80 ? "#FECACA" : "#A7F3D0"
                            border.width: 1
                            Row {
                                anchors.centerIn: parent; spacing: 6
                                Rectangle {
                                    width: 8; height: 8; radius: 4
                                    color: systemBackend.cpuTemperatureC >= 80 ? "#EF4444" : "#10B981"
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Text {
                                    id: liveStatusText
                                    text: "状态正常 · " + (systemBackend.cpuTemperatureC > -100 ? systemBackend.cpuTemperatureC.toFixed(0) + "°C" : "--")
                                    color: systemBackend.cpuTemperatureC >= 80 ? "#DC2626" : "#059669"
                                    font.family: "Noto Sans CJK SC"; font.pixelSize: 13; font.weight: Font.Bold
                                }
                            }
                        }
                    }

                    // 2. Decoupled Top Resource Cards (CPU Hero & RAM/GPU Compound)
                    RowLayout {
                        width: parent.width; height: 236; spacing: 14

                        PerformanceCpuCard {
                            Layout.fillWidth: true; Layout.fillHeight: true
                            cpuTotal: systemBackend.cpuTotal
                            logicalCoreCount: performancePage.logicalCoreCount
                            cpuSamples: performancePage.historyValues("cpu")
                            frequencyMhz: systemBackend.cpuFrequencyMhz
                            maxFrequencyMhz: systemBackend.cpuMaxFrequencyMhz
                            temperatureC: systemBackend.cpuTemperatureC
                            schedulerPendingTasks: systemBackend.schedulerPendingTasks
                            schedulerRunningTasks: systemBackend.schedulerRunningTasks
                            schedulerSubmittedTasks: systemBackend.schedulerSubmittedTasks
                            schedulerRejectedTasks: systemBackend.schedulerRejectedTasks
                            schedulerPeakPendingTasks: systemBackend.schedulerPeakPendingTasks
                        }

                        PerformanceRamGpuCard {
                            Layout.preferredWidth: 350; Layout.fillHeight: true
                            memoryPercent: systemBackend.memoryPercent
                            memoryUsed: systemBackend.memoryUsed
                            memoryAvailable: systemBackend.memoryAvailable
                            gpuFrequencyMhz: systemBackend.gpuFrequencyMhz
                        }
                    }

                    // 3. Decoupled Multi-Core Load Matrix Card
                    PerformanceCoreMatrix {
                        width: parent.width
                        logicalCoreCount: performancePage.logicalCoreCount
                        cpuUsageList: systemBackend.cpuUsage
                        cpuFrequenciesList: systemBackend.cpuFrequencies
                    }

                    // 4. System Overview Group
                    IosGroup {
                        width: parent.width
                        IosInfoRow { label: "系统平均负载 (1 / 5 / 15 分钟)"; value: systemBackend.loadAverage.length ? systemBackend.loadAverage : "--"; valueColor: "#F59E0B"; emphasize: true }
                        IosInfoRow { label: "系统开机运行时间"; value: systemBackend.uptime.length ? systemBackend.uptime : "--"; valueColor: "#10B981" }
                        IosInfoRow { label: "活跃任务与进程"; value: systemBackend.processCount >= 0 ? systemBackend.processCount + " 个活跃任务" : "--"; valueColor: "#3B82F6" }
                        IosInfoRow { label: "散热与温度状态"; value: systemBackend.cpuTemperatureC > -100 ? (systemBackend.cpuTemperatureC.toFixed(1) + " °C · 散热良好") : "--"; valueColor: "#06B6D4"; last: true }
                    }
                }
            }

            Timer {
                interval: 2000
                running: window.settingsForeground && window.lastSettingsSection === "performance"
                repeat: true
                triggeredOnStart: true
                onTriggered: systemBackend.refreshPerformance()
            }
        }
    }

    Component {
        id: storageSettings
        SettingsFlickable {
            anchors.fill: parent
            contentHeight: storageCol.height + 60

            Column {
                id: storageCol
                width: parent.width - 60
                x: 30; y: 30
                spacing: 16

                RowLayout {
                    width: parent.width
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 2
                        Text { text: "存储空间"; color: "#27222D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 34; font.weight: Font.Bold }
                        Text { text: "系统盘与扩展存储"; color: "#77717D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 18 }
                    }
                }

                StorageDiskCard {
                    width: parent.width
                    title: "系统存储"
                    detail: systemBackend.diskUsed + " 已使用，共 " + systemBackend.diskTotal
                    percent: systemBackend.diskPercent
                    accent: "#7B6DF0"
                    accent2: "#D875D4"
                }
                StorageDiskCard {
                    width: parent.width
                    title: systemBackend.nvmeModel.length ? systemBackend.nvmeModel : "NVMe 固态硬盘"
                    detail: !systemBackend.nvmeAvailable
                            ? "未检测到硬盘，请检查 PCIe 连接"
                            : (systemBackend.nvmeMounted
                               ? systemBackend.nvmeUsed + " 已使用，共 " + systemBackend.nvmeTotal
                                 + (systemBackend.nvmeMountPoint.length ? " · " + systemBackend.nvmeMountPoint : "")
                               : (systemBackend.nvmeTotal.length ? systemBackend.nvmeTotal + " · 未挂载" : "已检测，未挂载"))
                    percent: systemBackend.nvmePercent
                    available: systemBackend.nvmeAvailable
                    mounted: systemBackend.nvmeMounted
                    accent: "#4A90E2"
                    accent2: "#42C7C2"
                }
            }
        }
    }

    Component {
        id: aboutSettings
        SettingsFlickable {
            anchors.fill: parent
            contentHeight: aboutCol.height + 60

            Column {
                id: aboutCol
                width: parent.width - 60
                x: 30; y: 30
                spacing: 16

                RowLayout {
                    width: parent.width
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 2
                        Text { text: "关于本机"; color: "#27222D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 34; font.weight: Font.Bold }
                        Text { text: systemBackend.boardProfile; color: "#77717D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 18 }
                    }
                }

                Rectangle {
                    width: parent.width; height: 116; radius: 22
                    color: "#FFF7FA"; border.color: "#F3D5E1"; border.width: 1
                    RowLayout {
                        anchors.fill: parent; anchors.margins: 18; spacing: 18
                        Image { Layout.preferredWidth: 78; Layout.preferredHeight: 78; source: "qrc:/assets/meowkj-avatar-circle.png"; fillMode: Image.PreserveAspectFit; smooth: true }
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 4
                            Text { text: "Meow OS"; color: "#27222D"; font.family: "Noto Sans CJK SC"; font.pixelSize: 28; font.weight: Font.Bold }
                            Text { text: "版本 " + systemBackend.version + " · 精巧触控操作系统"; color: "#B35A78"; font.family: "Noto Sans CJK SC"; font.pixelSize: 15; elide: Text.ElideRight; Layout.fillWidth: true }
                        }
                    }
                }
                IosGroup {
                    width: parent.width
                    IosInfoRow { label: "系统版本"; value: "Meow OS " + systemBackend.version; valueColor: "#FF7FA7"; emphasize: true }
                    IosInfoRow { label: "硬件平台"; value: systemBackend.boardProfile }
                    IosInfoRow { label: "设备名称"; value: systemBackend.hostname.length ? systemBackend.hostname : "--" }
                    IosInfoRow { label: "Linux 内核"; value: systemBackend.kernel.length ? systemBackend.kernel : "--"; last: true }
                }
            }
        }
    }

}
