import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami
import org.myslowrollos.controlcenter

Kirigami.ScrollablePage {
    id: root
    title: qsTr("Dashboard")

    signal openSectionRequested(int sectionIndex, int subTabIndex)

    property int slowTickCounter: 0

    Timer {
        interval: 3000
        running: root.StackLayout.isCurrentItem && Qt.application.state === Qt.ApplicationActive
        repeat: true
        onTriggered: {
            DesktopBackend.refreshResources()
            SlowrollBackend.refreshAtomicState()
            root.slowTickCounter = (root.slowTickCounter + 1) % 10
            if (root.slowTickCounter === 0) {
                SlowrollBackend.refreshServices()
                DesktopBackend.refreshNetworkStatus()
                DesktopBackend.refreshWifiStatus()
            }
        }
    }

    StackLayout.onIsCurrentItemChanged: {
        if (root.StackLayout.isCurrentItem) {
            DesktopBackend.refreshResources()
            SlowrollBackend.refreshAtomicState()
            SlowrollBackend.refreshServices()
            DesktopBackend.refreshNetworkStatus()
            DesktopBackend.refreshWifiStatus()
        }
    }

    Component.onCompleted: {
        DesktopBackend.refreshResources()
        SlowrollBackend.refreshAtomicState()
    }

    ColumnLayout {
        width: parent.width
        spacing: UiMetrics.cardSpacing

        // 1. Transaction & System Health Alerts
        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: SlowrollBackend.pendingReboot
            type: Kirigami.MessageType.Positive
            showCloseButton: false
            text: SlowrollBackend.defaultSnapshot > 0
                  ? qsTr("Aggiornamento atomico pronto: riavviare il sistema per attivare lo snapshot #%1.").arg(SlowrollBackend.defaultSnapshot)
                  : qsTr("Aggiornamento atomico pronto: riavviare il sistema per attivare il nuovo snapshot.")
            actions: [
                Kirigami.Action {
                    text: qsTr("Vai a Backup & Recovery")
                    icon.name: "document-save-all"
                    onTriggered: root.openSectionRequested(4, 0)
                }
            ]
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: SlowrollBackend.needsInspection
            type: Kirigami.MessageType.Warning
            showCloseButton: false
            text: qsTr("Attenzione: la transazione atomica precedente richiede ispezione manuale.")
            actions: [
                Kirigami.Action {
                    text: qsTr("Verifica")
                    icon.name: "tools-wizard"
                    onTriggered: root.openSectionRequested(4, 0)
                }
            ]
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: SlowrollBackend.failedUnits.length > 0
            type: Kirigami.MessageType.Error
            showCloseButton: false
            text: qsTr("Rilevate %1 unità di sistema fallite.").arg(SlowrollBackend.failedUnits.length)
            actions: [
                Kirigami.Action {
                    text: qsTr("Ispeziona Servizi")
                    icon.name: "system-error"
                    onTriggered: root.openSectionRequested(2, 0)
                }
            ]
        }

        // 2. System Status Overview Card
        Kirigami.AbstractCard {
            Layout.fillWidth: true

            contentItem: ColumnLayout {
                spacing: Kirigami.Units.largeSpacing

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    Controls.Label {
                        text: SlowrollBackend.atomicStateDescription
                        opacity: UiMetrics.secondaryOpacity
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }

                    Controls.Button {
                        text: qsTr("Aggiorna Stato")
                        icon.name: "view-refresh"
                        enabled: !DesktopBackend.busy && !SlowrollBackend.busy
                        onClicked: SlowrollBackend.refreshAtomicState()
                    }
                }

                Kirigami.Separator { Layout.fillWidth: true }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    ColumnLayout {
                        spacing: 2
                        Controls.Label { text: qsTr("Snapshot Attivo"); font.bold: true; opacity: UiMetrics.secondaryOpacity }
                        Controls.Label {
                            text: SlowrollBackend.activeSnapshot > 0 ? "#" + SlowrollBackend.activeSnapshot : qsTr("Nominale")
                            font.bold: true
                        }
                    }

                    Item { Layout.preferredWidth: Kirigami.Units.largeSpacing }

                    ColumnLayout {
                        spacing: 2
                        Controls.Label { text: qsTr("Snapshot Predefinito (Boot)"); font.bold: true; opacity: UiMetrics.secondaryOpacity }
                        Controls.Label {
                            text: SlowrollBackend.defaultSnapshot > 0 ? "#" + SlowrollBackend.defaultSnapshot : qsTr("Nominale")
                            font.bold: true
                            color: SlowrollBackend.pendingReboot ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.textColor
                        }
                    }

                    Item {
                        Layout.fillWidth: true
                    }

                    ColumnLayout {
                        Layout.alignment: Qt.AlignRight
                        spacing: 2
                        Controls.Label {
                            text: qsTr("Profilo Energetico")
                            font.bold: true
                            opacity: UiMetrics.secondaryOpacity
                            Layout.alignment: Qt.AlignRight
                        }
                        Controls.Label {
                            text: DesktopBackend.powerProfile.toUpperCase()
                            font.bold: true
                            Layout.alignment: Qt.AlignRight
                        }
                    }
                }

                Kirigami.Separator { Layout.fillWidth: true }

                // Voce Dedicata: Stato & Selezione Avvio UEFI (efibootmgr)
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.mediumSpacing
                    visible: SlowrollBackend.uefiAvailable

                    Kirigami.Icon {
                        source: "system-run"
                        Layout.preferredWidth: 24
                        Layout.preferredHeight: 24
                        color: SlowrollBackend.uefiNextBootCode.length > 0 ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.highlightColor
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2

                        Controls.Label {
                            text: qsTr("Sequenza avvio BIOS")
                            font.bold: true
                            opacity: UiMetrics.secondaryOpacity
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.largeSpacing * 2

                            Controls.Label {
                                text: qsTr("Avvio Corrente: %1").arg(SlowrollBackend.uefiCurrentBootLabel.length > 0
                                      ? (SlowrollBackend.uefiCurrentBootCode.length > 0 ? "[#" + SlowrollBackend.uefiCurrentBootCode + "] " : "") + SlowrollBackend.uefiCurrentBootLabel
                                      : qsTr("Predefinito"))
                                font.bold: true
                                elide: Text.ElideRight
                            }

                            Controls.Label {
                                text: "·"
                                opacity: UiMetrics.secondaryOpacity
                            }

                            Controls.Label {
                                text: SlowrollBackend.uefiNextBootCode.length > 0
                                      ? qsTr("Prossimo Riavvio (BootNext): [#%1] %2").arg(SlowrollBackend.uefiNextBootCode).arg(SlowrollBackend.uefiNextBootLabel)
                                      : qsTr("Prossimo Avvio: Sequenza Standard")
                                font.bold: true
                                color: SlowrollBackend.uefiNextBootCode.length > 0 ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.textColor
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }
                        }
                    }

                    Controls.Button {
                        text: qsTr("Gestisci Avvio")
                        icon.name: "system-reboot"
                        onClicked: root.openSectionRequested(3, 0)
                    }
                }

                Kirigami.Separator { Layout.fillWidth: true; visible: SlowrollBackend.uefiAvailable }

                // Connessione di Rete Attiva & Wi-Fi
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.mediumSpacing

                    Kirigami.Icon {
                        source: DesktopBackend.networkConnected ? "network-connect" : "network-disconnect"
                        Layout.preferredWidth: 26
                        Layout.preferredHeight: 26
                        color: DesktopBackend.networkConnected ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.negativeTextColor
                    }

                    Controls.Label {
                        text: DesktopBackend.networkConnected
                              ? qsTr("Rete Attiva: %1 (%2) · IP: %3").arg(DesktopBackend.networkActiveConnection).arg(DesktopBackend.networkInterface).arg(DesktopBackend.networkIpAddress.length > 0 ? DesktopBackend.networkIpAddress : qsTr("DHCP / Assegnato"))
                              : qsTr("Rete: Disconnessa o non gestita")
                        textFormat: Text.PlainText
                        font.pointSize: Kirigami.Theme.defaultFont.pointSize + 1
                        font.weight: Font.DemiBold
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                    }

                    // Tasto Stato Wi-Fi (Attivo / Disattivato / Blocco Hardware)
                    Controls.Button {
                        visible: DesktopBackend.hasWifiHardware
                        enabled: !DesktopBackend.busy && !SlowrollBackend.busy && !DesktopBackend.wifiHardwareBlocked
                        text: DesktopBackend.wifiHardwareBlocked
                              ? qsTr("Wi-Fi: Blocco HW")
                              : (DesktopBackend.wifiEnabled ? qsTr("Wi-Fi: Attivo") : qsTr("Wi-Fi: Disattivato"))
                        icon.name: DesktopBackend.wifiHardwareBlocked
                                   ? "network-wireless-hardware-disabled"
                                   : (DesktopBackend.wifiEnabled ? "network-wireless-connected" : "network-wireless-disconnected")
                        display: Controls.AbstractButton.TextBesideIcon
                        highlighted: DesktopBackend.wifiEnabled && !DesktopBackend.wifiHardwareBlocked
                        onClicked: DesktopBackend.toggleWifi()
                    }

                    // Tasto Stato Bluetooth (Attivo / Disattivato / Blocco Hardware)
                    Controls.Button {
                        visible: DesktopBackend.hasBluetoothHardware
                        enabled: !DesktopBackend.busy && !SlowrollBackend.busy && !DesktopBackend.bluetoothHardwareBlocked && !DesktopBackend.privacyActive
                        text: DesktopBackend.bluetoothHardwareBlocked
                              ? qsTr("Bluetooth: Blocco HW")
                              : (DesktopBackend.bluetoothEnabled ? qsTr("Bluetooth: Attivo") : qsTr("Bluetooth: Disattivato"))
                        icon.name: DesktopBackend.bluetoothHardwareBlocked
                                   ? "preferences-system-bluetooth"
                                   : (DesktopBackend.bluetoothEnabled ? "preferences-system-bluetooth" : "network-wireless-disconnected")
                        display: Controls.AbstractButton.TextBesideIcon
                        highlighted: DesktopBackend.bluetoothEnabled && !DesktopBackend.bluetoothHardwareBlocked
                        onClicked: DesktopBackend.toggleBluetooth()
                    }
                }
            }
        }

        // 3. Hardware Resource Cards
        Kirigami.Heading {
            level: 2
            text: qsTr("Stato Risorse Hardware")
            font.bold: true
            Layout.topMargin: Kirigami.Units.smallSpacing
        }

        GridLayout {
            Layout.fillWidth: true
            columns: root.width > 1050 ? 6 : (root.width > 680 ? 3 : (root.width > 460 ? 2 : 1))
            columnSpacing: UiMetrics.cardSpacing
            rowSpacing: UiMetrics.cardSpacing

            StatCard {
                iconName: "cpu"
                iconColor: DesktopBackend.cpuUsagePercent > 85 ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.highlightColor
                title: qsTr("CPU")
                value: DesktopBackend.cpuUsagePercent + "%"
                detail: qsTr("Carico istantaneo")
            }

            StatCard {
                iconName: "media-flash"
                iconColor: DesktopBackend.memoryPercent > 85 ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.positiveTextColor
                title: qsTr("RAM (In Uso Reale)")
                value: DesktopBackend.memoryTotalMiB > 0
                       ? (DesktopBackend.memoryUsedMiB / 1024.0).toFixed(1) + " / " + (DesktopBackend.memoryTotalMiB / 1024.0).toFixed(1) + " GiB"
                       : qsTr("Rilevamento...")
                detail: DesktopBackend.memoryTotalMiB > 0
                        ? qsTr("%1% (esclusi cache e buffer)").arg(DesktopBackend.memoryPercent)
                        : qsTr("Memoria di sistema")
            }

            StatCard {
                iconName: "sensors-temperature"
                iconColor: DesktopBackend.cpuTemperatureC > 80 ? Kirigami.Theme.negativeTextColor : (DesktopBackend.cpuTemperatureC > 65 ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.positiveTextColor)
                title: qsTr("Temperatura CPU")
                value: DesktopBackend.cpuTemperatureC > 0 ? DesktopBackend.cpuTemperatureC.toFixed(1) + " °C" : qsTr("N/D")
                detail: DesktopBackend.cpuTemperatureC > 0 ? (DesktopBackend.cpuTemperatureC > 75 ? qsTr("Carico termico elevato") : qsTr("Termica nominale")) : qsTr("Sensore non rilevato")
            }

            StatCard {
                iconName: "drive-harddisk"
                iconColor: DesktopBackend.diskRootPercent > 90 ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.neutralTextColor
                title: qsTr("Disco Root (/)")
                value: (DesktopBackend.diskRootTotalGiB - DesktopBackend.diskRootAvailableGiB) + " / " + DesktopBackend.diskRootTotalGiB + " GiB"
                detail: qsTr("%1 GiB liberi (%2% occupato)").arg(DesktopBackend.diskRootAvailableGiB).arg(DesktopBackend.diskRootPercent)
            }

            StatCard {
                iconName: "user-home"
                iconColor: DesktopBackend.diskHomePercent > 90 ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.highlightColor
                title: qsTr("Home (/home)")
                value: (DesktopBackend.diskHomeTotalGiB - DesktopBackend.diskHomeAvailableGiB) + " / " + DesktopBackend.diskHomeTotalGiB + " GiB"
                detail: qsTr("%1 GiB liberi (%2% occupato)").arg(DesktopBackend.diskHomeAvailableGiB).arg(DesktopBackend.diskHomePercent)
            }

            StatCard {
                iconName: DesktopBackend.privacyActive ? "security-high" : "security-medium"
                iconColor: DesktopBackend.privacyActive ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.neutralTextColor
                title: qsTr("Modalità Privacy")
                value: DesktopBackend.privacyActive ? qsTr("ATTIVA") : qsTr("Disattivata")
                detail: DesktopBackend.privacyActive ? qsTr("Isolamento attivo") : qsTr("Stato nominale")
            }
        }

        // 4. Comandi Rapidi (Azioni Rapide & Strumenti Essenziali)
        Kirigami.Heading {
            level: 2
            text: qsTr("Comandi Rapidi & Azioni Frequenti")
            font.bold: true
            Layout.topMargin: Kirigami.Units.smallSpacing
        }

        GridLayout {
            Layout.fillWidth: true
            columns: root.width > 860 ? 3 : (root.width > 540 ? 2 : 1)
            columnSpacing: UiMetrics.cardSpacing
            rowSpacing: UiMetrics.cardSpacing

            Controls.Button {
                Layout.fillWidth: true
                Layout.preferredHeight: 46
                text: qsTr("KDE Discover (Flatpak)")
                icon.name: "plasma-discover"
                enabled: DesktopBackend.isToolAvailable("discover")
                onClicked: DesktopBackend.launchTool("discover")
            }

            Controls.Button {
                Layout.fillWidth: true
                Layout.preferredHeight: 46
                text: qsTr("YaST Gestione Software")
                icon.name: "yast-sw_single"
                enabled: DesktopBackend.isToolAvailable("yast")
                onClicked: DesktopBackend.launchTool("yast-software")
            }

            Controls.Button {
                Layout.fillWidth: true
                Layout.preferredHeight: 46
                text: qsTr("Console Web Cockpit")
                icon.name: "network-server"
                enabled: DesktopBackend.isToolAvailable("cockpit")
                onClicked: DesktopBackend.launchTool("cockpit")
            }

            Controls.Button {
                Layout.fillWidth: true
                Layout.preferredHeight: 46
                text: qsTr("Monitor di Sistema KDE")
                icon.name: "utilities-system-monitor"
                enabled: DesktopBackend.isToolAvailable("systemmonitor")
                onClicked: DesktopBackend.launchTool("systemmonitor")
            }

            Controls.Button {
                Layout.fillWidth: true
                Layout.preferredHeight: 46
                text: DesktopBackend.privacyActive ? qsTr("Disattiva Privacy") : qsTr("Modalità Privacy")
                icon.name: "security-high"
                display: Controls.AbstractButton.TextBesideIcon
                highlighted: DesktopBackend.privacyActive
                enabled: !DesktopBackend.busy && !SlowrollBackend.busy
                onClicked: {
                    if (DesktopBackend.privacyActive) {
                        DesktopBackend.togglePrivacy()
                    } else {
                        privacyConfirmDialog.open()
                    }
                }
            }

            Controls.Button {
                Layout.fillWidth: true
                Layout.preferredHeight: 46
                text: DesktopBackend.micMuted ? qsTr("Mic: Disattivato") : qsTr("Mic: Attivo")
                icon.name: DesktopBackend.micMuted ? "microphone-sensitivity-muted" : "audio-input-microphone"
                display: Controls.AbstractButton.TextBesideIcon
                highlighted: !DesktopBackend.micMuted
                onClicked: {
                    if (!DesktopBackend.launchCustomScript("Mic")) {
                        DesktopBackend.toggleMic();
                    }
                }
            }

            Controls.Button {
                Layout.fillWidth: true
                Layout.preferredHeight: 46
                text: qsTr("Svuota Cache DNS")
                icon.name: "network-connect"
                onClicked: DesktopBackend.flushDns()
            }

            Controls.Button {
                Layout.fillWidth: true
                Layout.preferredHeight: 46
                text: qsTr("Svuota Cestino Utente")
                icon.name: "user-trash"
                onClicked: trashConfirmDialog.open()
            }

            Controls.Button {
                Layout.fillWidth: true
                Layout.preferredHeight: 46
                text: qsTr("KDE Connect")
                icon.name: "kdeconnect"
                enabled: DesktopBackend.isToolAvailable("kdeconnect")
                onClicked: DesktopBackend.launchTool("kdeconnect")
            }
        }
    }

    Controls.Dialog {
        id: trashConfirmDialog
        title: qsTr("Conferma Svuotamento Cestino")
        standardButtons: Controls.Dialog.Yes | Controls.Dialog.No
        width: 440
        anchors.centerIn: Controls.Overlay.overlay
        modal: true

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.largeSpacing
            Controls.Label {
                text: qsTr("Sei sicuro di voler svuotare definitivamente il cestino utente?")
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
            Controls.Label {
                text: qsTr("I file eliminati non potranno più essere recuperati.")
                opacity: UiMetrics.secondaryOpacity
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
        }

        onAccepted: DesktopBackend.cleanTrash("home")
    }

    Controls.Dialog {
        id: privacyConfirmDialog
        title: qsTr("Conferma Attivazione Modalità Privacy")
        standardButtons: Controls.Dialog.Yes | Controls.Dialog.No
        width: 460
        anchors.centerIn: Controls.Overlay.overlay
        modal: true

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.largeSpacing
            Controls.Label {
                text: qsTr("Vuoi attivare la Modalità Privacy e Isolamento?")
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
            Controls.Label {
                text: qsTr("Verranno silenziato il microfono, disattivato il Bluetooth, impostato il firewall in zona drop e cancellati in modo irreversibile gli appunti di Klipper, i file recenti e la cache delle miniature.")
                opacity: UiMetrics.secondaryOpacity
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
        }

        onAccepted: DesktopBackend.togglePrivacy()
    }
}
