import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami
import org.myslowrollos.controlcenter

Kirigami.ScrollablePage {
    id: root
    title: qsTr("Servizi & Rete")

    property string pendingRestartServiceName: ""
    property alias currentSubTab: tabs.currentIndex

    Component.onCompleted: {
        SlowrollBackend.refreshServices()
        DesktopBackend.refreshNetworkStatus()
    }

    Controls.Dialog {
        id: serviceRestartConfirmDialog
        title: qsTr("Conferma Riavvio Servizio")
        standardButtons: Controls.Dialog.Yes | Controls.Dialog.No
        width: 440
        anchors.centerIn: Controls.Overlay.overlay
        modal: true

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.largeSpacing
            Controls.Label {
                text: qsTr("Sei sicuro di voler riavviare il servizio <b>%1</b>?").arg(root.pendingRestartServiceName)
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
            Controls.Label {
                text: qsTr("Il riavvio potrebbe interrompere temporaneamente le connessioni attive o le funzionalità del sistema.")
                opacity: UiMetrics.secondaryOpacity
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
        }

        onAccepted: {
            if (root.pendingRestartServiceName.length > 0) {
                SlowrollBackend.restartService(root.pendingRestartServiceName)
                root.pendingRestartServiceName = ""
            }
        }
    }

    ColumnLayout {
        width: parent.width
        spacing: UiMetrics.cardSpacing

        Controls.TabBar {
            id: tabs
            Layout.fillWidth: true
            Controls.TabButton { text: qsTr("Servizi e Unità"); font.bold: true }
            Controls.TabButton { text: qsTr("Rete & DNS"); font.bold: true }
        }

        StackLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: children[currentIndex] ? children[currentIndex].implicitHeight : implicitHeight
            currentIndex: tabs.currentIndex

            // TAB 1: Servizi Fondamentali
            ColumnLayout {
                spacing: UiMetrics.cardSpacing

                Kirigami.AbstractCard {
                    Layout.fillWidth: true

                    contentItem: ColumnLayout {
                        spacing: Kirigami.Units.largeSpacing

                        RowLayout {
                            Layout.fillWidth: true
                            Kirigami.Icon { source: "system-run"; Layout.preferredWidth: 28; Layout.preferredHeight: 28 }
                            ColumnLayout {
                                spacing: 2
                                Kirigami.Heading { level: 3; text: qsTr("Stato Servizi Chiave"); font.bold: true }
                                Controls.Label {
                                    text: qsTr("Controllo immediato dei principali demoni di sistema.")
                                    opacity: UiMetrics.secondaryOpacity
                                }
                            }

                            Item { Layout.fillWidth: true }

                            Controls.Button {
                                text: qsTr("Ricarica Stati")
                                icon.name: "view-refresh"
                                onClicked: SlowrollBackend.refreshServices()
                            }
                        }

                        Kirigami.Separator { Layout.fillWidth: true }

                        GridLayout {
                            Layout.fillWidth: true
                            columns: root.width > 700 ? 2 : 1
                            columnSpacing: UiMetrics.cardSpacing
                            rowSpacing: UiMetrics.cardSpacing

                            // Firewalld
                            Kirigami.AbstractCard {
                                Layout.fillWidth: true
                                Layout.preferredWidth: 0
                                contentItem: RowLayout {
                                    spacing: Kirigami.Units.largeSpacing
                                    Kirigami.Icon { source: "security-high"; Layout.preferredWidth: 28; Layout.preferredHeight: 28 }
                                    ColumnLayout {
                                        spacing: 2
                                        Controls.Label { text: qsTr("Firewall (firewalld)"); font.bold: true }
                                        Controls.Label {
                                            text: qsTr("Stato: <b>%1</b>").arg(SlowrollBackend.keyServices["firewalld.service"] || qsTr("verifica..."))
                                            color: SlowrollBackend.keyServices["firewalld.service"] === "active" ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.neutralTextColor
                                        }
                                    }
                                    Item { Layout.fillWidth: true }
                                    Controls.Button {
                                        text: qsTr("Riavvia")
                                        icon.name: "view-refresh"
                                        enabled: !DesktopBackend.busy && !SlowrollBackend.busy
                                        onClicked: {
                                            root.pendingRestartServiceName = "firewalld.service"
                                            serviceRestartConfirmDialog.open()
                                        }
                                    }
                                }
                            }

                            // NetworkManager
                            Kirigami.AbstractCard {
                                Layout.fillWidth: true
                                Layout.preferredWidth: 0
                                contentItem: RowLayout {
                                    spacing: Kirigami.Units.largeSpacing
                                    Kirigami.Icon { source: "network-connect"; Layout.preferredWidth: 28; Layout.preferredHeight: 28 }
                                    ColumnLayout {
                                        spacing: 2
                                        Controls.Label { text: qsTr("Gestore Rete (NetworkManager)"); font.bold: true }
                                        Controls.Label {
                                            text: qsTr("Stato: <b>%1</b>").arg(SlowrollBackend.keyServices["NetworkManager.service"] || qsTr("verifica..."))
                                            color: SlowrollBackend.keyServices["NetworkManager.service"] === "active" ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.neutralTextColor
                                        }
                                    }
                                    Item { Layout.fillWidth: true }
                                    Controls.Button {
                                        text: qsTr("Riavvia")
                                        icon.name: "view-refresh"
                                        enabled: !DesktopBackend.busy && !SlowrollBackend.busy
                                        onClicked: {
                                            root.pendingRestartServiceName = "NetworkManager.service"
                                            serviceRestartConfirmDialog.open()
                                        }
                                    }
                                }
                            }

                            // Bluetooth
                            Kirigami.AbstractCard {
                                Layout.fillWidth: true
                                Layout.preferredWidth: 0
                                contentItem: RowLayout {
                                    spacing: Kirigami.Units.largeSpacing
                                    Kirigami.Icon { source: "preferences-system-bluetooth"; Layout.preferredWidth: 28; Layout.preferredHeight: 28 }
                                    ColumnLayout {
                                        spacing: 2
                                        Controls.Label { text: qsTr("Bluetooth (bluetoothd)"); font.bold: true }
                                        Controls.Label {
                                            text: qsTr("Stato: <b>%1</b>").arg(SlowrollBackend.keyServices["bluetooth.service"] || qsTr("verifica..."))
                                            color: SlowrollBackend.keyServices["bluetooth.service"] === "active" ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.neutralTextColor
                                        }
                                    }
                                    Item { Layout.fillWidth: true }
                                    Controls.Button {
                                        text: qsTr("Riavvia")
                                        icon.name: "view-refresh"
                                        enabled: !DesktopBackend.busy && !SlowrollBackend.busy
                                        onClicked: {
                                            root.pendingRestartServiceName = "bluetooth.service"
                                            serviceRestartConfirmDialog.open()
                                        }
                                    }
                                }
                            }

                            // CUPS Stampa
                            Kirigami.AbstractCard {
                                Layout.fillWidth: true
                                Layout.preferredWidth: 0
                                contentItem: RowLayout {
                                    spacing: Kirigami.Units.largeSpacing
                                    Kirigami.Icon { source: "printer"; Layout.preferredWidth: 28; Layout.preferredHeight: 28 }
                                    ColumnLayout {
                                        spacing: 2
                                        Controls.Label { text: qsTr("Server di Stampa (CUPS)"); font.bold: true }
                                        Controls.Label {
                                            text: qsTr("Stato: <b>%1</b>").arg(SlowrollBackend.keyServices["cups.service"] || qsTr("verifica..."))
                                            color: (SlowrollBackend.keyServices["cups.service"] || "").startsWith("active") ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.neutralTextColor
                                        }
                                    }
                                    Item { Layout.fillWidth: true }
                                    Controls.Button {
                                        text: qsTr("Riavvia")
                                        icon.name: "view-refresh"
                                        enabled: !DesktopBackend.busy && !SlowrollBackend.busy
                                        onClicked: {
                                            root.pendingRestartServiceName = "cups.service"
                                            serviceRestartConfirmDialog.open()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // YaST Services Manager shortcut
                Kirigami.AbstractCard {
                    Layout.fillWidth: true
                    contentItem: RowLayout {
                        spacing: Kirigami.Units.largeSpacing
                        Kirigami.Icon { source: "yast-services-manager"; Layout.preferredWidth: 32; Layout.preferredHeight: 32 }
                        ColumnLayout {
                            spacing: 1
                            Controls.Label { text: qsTr("Gestione Completa Servizi di Sistema (YaST)"); font.bold: true }
                            Controls.Label {
                                text: qsTr("Abilita, disabilita o configura tutti i servizi systemd nativamente.")
                                opacity: UiMetrics.secondaryOpacity
                            }
                        }
                        Item { Layout.fillWidth: true }
                        Controls.Button {
                            text: qsTr("Apri YaST Servizi")
                            icon.name: "yast-services-manager"
                            enabled: DesktopBackend.isToolAvailable("yast")
                            onClicked: DesktopBackend.launchYastModule("services-manager")
                        }
                    }
                }

                // Unità Systemd Fallite

                Kirigami.AbstractCard {
                    Layout.fillWidth: true

                    contentItem: ColumnLayout {
                        spacing: Kirigami.Units.largeSpacing

                        RowLayout {
                            Layout.fillWidth: true
                            Kirigami.Icon {
                                source: SlowrollBackend.failedUnits.length > 0 ? "system-error" : "security-high"
                                color: SlowrollBackend.failedUnits.length > 0 ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.positiveTextColor
                                Layout.preferredWidth: 32
                                Layout.preferredHeight: 32
                            }
                            ColumnLayout {
                                spacing: 2
                                Kirigami.Heading {
                                    level: 3
                                    font.bold: true
                                    text: SlowrollBackend.failedUnits.length > 0
                                          ? qsTr("%1 Unità in Errore Rilevate").arg(SlowrollBackend.failedUnits.length)
                                          : qsTr("Tutti i Servizi Funzionano Correttamente")
                                }
                                Controls.Label {
                                    text: SlowrollBackend.failedUnits.length > 0
                                          ? qsTr("Seleziona un'unità per consultarne il journal o riavviarla.")
                                          : qsTr("Nessuna unità di sistema fallita segnalata da systemd.")
                                    opacity: UiMetrics.secondaryOpacity
                                }
                            }
                            Item { Layout.fillWidth: true }
                            Controls.Button {
                                text: qsTr("Ricarica")
                                icon.name: "view-refresh"
                                onClicked: SlowrollBackend.refreshServices()
                            }
                        }

                        Kirigami.Separator { Layout.fillWidth: true; visible: SlowrollBackend.failedUnits.length > 0 }

                        Repeater {
                            model: SlowrollBackend.failedUnits
                            delegate: Controls.ItemDelegate {
                                required property var modelData
                                Layout.fillWidth: true
                                readonly property string unitName: (typeof modelData === "string") ? modelData.replace(/^[●\*\s]+/, "").trim().split(/\s+/)[0] : ""

                                contentItem: RowLayout {
                                    spacing: Kirigami.Units.largeSpacing

                                    Kirigami.Icon {
                                        source: "dialog-warning"
                                        color: Kirigami.Theme.negativeTextColor
                                        Layout.preferredWidth: 22
                                        Layout.preferredHeight: 22
                                    }

                                    Controls.Label {
                                        text: unitName.length > 0 ? unitName : modelData
                                        font.bold: true
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                    }

                                    Controls.Button {
                                        text: qsTr("Vedi Log")
                                        icon.name: "document-preview"
                                        onClicked: SlowrollBackend.loadServiceJournal(unitName)
                                    }

                                    Controls.Button {
                                        text: qsTr("Riavvia")
                                        icon.name: "view-refresh"
                                        enabled: !DesktopBackend.busy && !SlowrollBackend.busy
                                        onClicked: {
                                            root.pendingRestartServiceName = unitName
                                            serviceRestartConfirmDialog.open()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Journal output for failed unit inspection
                OutputCard {
                    title: qsTr("Registro Log Journal dell'Unità")
                    outputText: SlowrollBackend.serviceJournal
                    onCloseRequested: SlowrollBackend.clearServiceJournal()
                }
            }

            // TAB 2: Rete & DNS
            ColumnLayout {
                spacing: UiMetrics.cardSpacing

                // 1. Stato Attuale della Rete
                Kirigami.AbstractCard {
                    Layout.fillWidth: true

                    contentItem: ColumnLayout {
                        spacing: Kirigami.Units.largeSpacing

                        RowLayout {
                            Layout.fillWidth: true
                            Kirigami.Icon {
                                source: DesktopBackend.networkConnected ? "network-connect" : "network-disconnect"
                                Layout.preferredWidth: 32
                                Layout.preferredHeight: 32
                                color: DesktopBackend.networkConnected ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.negativeTextColor
                            }

                            ColumnLayout {
                                spacing: 2
                                Kirigami.Heading {
                                    level: 3
                                    text: qsTr("Stato Connessione di Rete (NetworkManager)")
                                    font.bold: true
                                }
                                Controls.Label {
                                    text: DesktopBackend.networkConnected
                                          ? qsTr("Connesso tramite %1 (interfaccia %2)").arg(DesktopBackend.networkActiveConnection).arg(DesktopBackend.networkInterface)
                                          : qsTr("Nessuna connessione attiva rilevata.")
                                    textFormat: Text.PlainText
                                    opacity: UiMetrics.secondaryOpacity
                                }
                            }

                            Item { Layout.fillWidth: true }

                            Controls.Button {
                                text: qsTr("Rileva Stato")
                                icon.name: "view-refresh"
                                onClicked: DesktopBackend.refreshNetworkStatus()
                            }

                            Controls.Button {
                                text: qsTr("Svuota Cache DNS")
                                icon.name: "edit-clear"
                                onClicked: DesktopBackend.flushDns()
                            }
                        }

                        Kirigami.Separator { Layout.fillWidth: true }

                        GridLayout {
                            Layout.fillWidth: true
                            columns: root.width > 700 ? 3 : 1
                            columnSpacing: Kirigami.Units.largeSpacing
                            rowSpacing: Kirigami.Units.smallSpacing

                            ColumnLayout {
                                spacing: 2
                                Controls.Label { text: qsTr("Indirizzo IPv4"); font.bold: true; opacity: UiMetrics.secondaryOpacity }
                                Controls.Label {
                                    text: DesktopBackend.networkIpAddress.length > 0 ? DesktopBackend.networkIpAddress : qsTr("Non assegnato")
                                    font.bold: true
                                    font.family: Kirigami.Theme.fixedWidthFont.family
                                    color: Kirigami.Theme.neutralTextColor
                                }
                            }

                            ColumnLayout {
                                spacing: 2
                                Controls.Label { text: qsTr("Gateway Predefinito"); font.bold: true; opacity: UiMetrics.secondaryOpacity }
                                Controls.Label {
                                    text: DesktopBackend.networkGateway.length > 0 ? DesktopBackend.networkGateway : qsTr("Nessuno")
                                    font.bold: true
                                    font.family: Kirigami.Theme.fixedWidthFont.family
                                    color: Kirigami.Theme.neutralTextColor
                                }
                            }

                            ColumnLayout {
                                spacing: 2
                                Controls.Label { text: qsTr("Server DNS Attivi"); font.bold: true; opacity: UiMetrics.secondaryOpacity }
                                Controls.Label {
                                    text: DesktopBackend.networkDns.length > 0 ? DesktopBackend.networkDns : qsTr("Predefiniti DHCP")
                                    font.bold: true
                                    font.family: Kirigami.Theme.fixedWidthFont.family
                                    color: Kirigami.Theme.neutralTextColor
                                }
                            }
                        }
                    }
                }

                // 2. Commutazione Rapida IP & DNS al Volo
                Kirigami.Heading {
                    level: 2
                    text: qsTr("Commutazione Rapida IP & DNS (Profili al Volo)")
                    font.bold: true
                    Layout.topMargin: Kirigami.Units.smallSpacing
                }

                Kirigami.AbstractCard {
                    Layout.fillWidth: true

                    contentItem: ColumnLayout {
                        spacing: Kirigami.Units.largeSpacing

                        Controls.Label {
                            text: qsTr("Seleziona uno dei profili IP e server DNS per applicarli istantaneamente alla connessione attiva <b>%1</b> senza richiedere password.")
                                  .arg(DesktopBackend.networkActiveConnection.length > 0 ? DesktopBackend.networkActiveConnection : qsTr("predefinita"))
                            opacity: UiMetrics.secondaryOpacity
                            wrapMode: Text.WordWrap
                            Layout.fillWidth: true
                        }

                        // Selezione IP
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing

                            Controls.Label {
                                text: qsTr("1. Seleziona Indirizzo IP:")
                                font.bold: true
                            }

                            GridLayout {
                                id: ipGrid
                                Layout.fillWidth: true
                                columns: root.width > 900 ? 4 : (root.width > 560 ? 2 : 1)
                                columnSpacing: UiMetrics.cardSpacing
                                rowSpacing: UiMetrics.cardSpacing

                                Repeater {
                                    model: DesktopBackend.ipPresets
                                    delegate: Controls.Button {
                                        id: ipPresetBtn
                                        required property var modelData
                                        required property int index
                                        Layout.fillWidth: true
                                        Layout.preferredWidth: 1
                                        Layout.preferredHeight: 52
                                        highlighted: DesktopBackend.selectedIpPreset === index

                                        background: Rectangle {
                                            radius: 6
                                            color: ipPresetBtn.highlighted
                                                ? Qt.rgba(Kirigami.Theme.highlightColor.r, Kirigami.Theme.highlightColor.g, Kirigami.Theme.highlightColor.b, 0.12)
                                                : (ipPresetBtn.down ? Kirigami.Theme.alternateBackgroundColor : (ipPresetBtn.hovered ? Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.05) : Kirigami.Theme.backgroundColor))
                                            border.color: ipPresetBtn.highlighted ? Kirigami.Theme.highlightColor : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.2)
                                            border.width: ipPresetBtn.highlighted ? 2 : 1
                                        }

                                        contentItem: ColumnLayout {
                                            spacing: 1
                                            Controls.Label {
                                                text: (index + 1) + ". " + (modelData.name || qsTr("Profilo IP %1").arg(index + 1))
                                                font.bold: true
                                                horizontalAlignment: Text.AlignHCenter
                                                Layout.fillWidth: true
                                                color: ipPresetBtn.highlighted ? Kirigami.Theme.highlightColor : Kirigami.Theme.textColor
                                            }
                                            Controls.Label {
                                                text: (modelData.address && modelData.address.length > 0) ? modelData.address.split('/')[0] : qsTr("DHCP Automatico")
                                                font.family: Kirigami.Theme.fixedWidthFont.family
                                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                                font.bold: ipPresetBtn.highlighted
                                                horizontalAlignment: Text.AlignHCenter
                                                Layout.fillWidth: true
                                                color: ipPresetBtn.highlighted ? Kirigami.Theme.highlightColor : Kirigami.Theme.neutralTextColor
                                            }
                                        }

                                        onClicked: DesktopBackend.selectIpPreset(index)
                                    }
                                }
                            }
                        }

                        // Selezione DNS
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing

                            Controls.Label {
                                text: qsTr("2. Seleziona Server DNS:")
                                font.bold: true
                            }

                            GridLayout {
                                id: dnsGrid
                                Layout.fillWidth: true
                                columns: root.width > 900 ? 4 : (root.width > 560 ? 2 : 1)
                                columnSpacing: UiMetrics.cardSpacing
                                rowSpacing: UiMetrics.cardSpacing

                                Repeater {
                                    model: DesktopBackend.dnsPresets
                                    delegate: Controls.Button {
                                        id: dnsPresetBtn
                                        required property var modelData
                                        required property int index
                                        Layout.fillWidth: true
                                        Layout.preferredWidth: 1
                                        Layout.preferredHeight: 52
                                        highlighted: DesktopBackend.selectedDnsPreset === index

                                        background: Rectangle {
                                            radius: 6
                                            color: dnsPresetBtn.highlighted
                                                ? Qt.rgba(Kirigami.Theme.highlightColor.r, Kirigami.Theme.highlightColor.g, Kirigami.Theme.highlightColor.b, 0.12)
                                                : (dnsPresetBtn.down ? Kirigami.Theme.alternateBackgroundColor : (dnsPresetBtn.hovered ? Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.05) : Kirigami.Theme.backgroundColor))
                                            border.color: dnsPresetBtn.highlighted ? Kirigami.Theme.highlightColor : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.2)
                                            border.width: dnsPresetBtn.highlighted ? 2 : 1
                                        }

                                        contentItem: ColumnLayout {
                                            spacing: 1
                                            Controls.Label {
                                                text: (index + 1) + ". " + (modelData.name || qsTr("Profilo DNS %1").arg(index + 1))
                                                font.bold: true
                                                horizontalAlignment: Text.AlignHCenter
                                                Layout.fillWidth: true
                                                color: dnsPresetBtn.highlighted ? Kirigami.Theme.highlightColor : Kirigami.Theme.textColor
                                            }
                                            Controls.Label {
                                                text: (modelData.dns && modelData.dns.length > 0) ? modelData.dns : qsTr("Predefinito")
                                                font.family: Kirigami.Theme.fixedWidthFont.family
                                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                                font.bold: dnsPresetBtn.highlighted
                                                horizontalAlignment: Text.AlignHCenter
                                                Layout.fillWidth: true
                                                color: dnsPresetBtn.highlighted ? Kirigami.Theme.highlightColor : Kirigami.Theme.neutralTextColor
                                            }
                                        }

                                        onClicked: DesktopBackend.selectDnsPreset(index)
                                    }
                                }
                            }
                        }

                        // Indirizzo HTTPS associato al DNS
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2

                            Controls.Label {
                                text: qsTr("3. Indirizzo HTTPS associato al DNS (URL DoH - solo annotazione / promemoria):")
                                font.bold: true
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing

                                Controls.TextField {
                                    id: httpsField
                                    Layout.fillWidth: true
                                    text: DesktopBackend.httpsAddress
                                    placeholderText: qsTr("https://... (URL DoH o dashboard fornitore - solo annotazione)")
                                    onAccepted: DesktopBackend.setHttpsAddress(text)

                                    Connections {
                                        target: DesktopBackend
                                        function onNetworkPresetsChanged() {
                                            httpsField.text = DesktopBackend.httpsAddress
                                        }
                                    }
                                }

                                Controls.Button {
                                    text: qsTr("Aggiorna URL")
                                    icon.name: "document-save"
                                    onClicked: DesktopBackend.setHttpsAddress(httpsField.text)
                                }
                            }

                            Controls.Label {
                                text: qsTr("Questo indirizzo HTTPS viene salvato e collegato direttamente al profilo DNS selezionato.")
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                opacity: UiMetrics.secondaryOpacity
                            }
                        }

                        Kirigami.Separator { Layout.fillWidth: true }

                        // Barra Azione Applicazione
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.largeSpacing

                            Controls.Button {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 46
                                text: qsTr("Applica Configurazione Rete al Volo")
                                icon.name: "network-connect"
                                highlighted: true
                                enabled: !DesktopBackend.busy && !SlowrollBackend.busy
                                onClicked: applyNetworkConfirmDialog.open()
                            }

                            Controls.Button {
                                Layout.preferredHeight: 46
                                text: qsTr("Modifica Valori dei Profili...")
                                icon.name: "document-edit"
                                onClicked: editNetworkDialog.open()
                            }
                        }
                    }
                }

                // 3. Strumenti Esterni di Rete & Firewall
                Kirigami.Heading {
                    level: 2
                    text: qsTr("Strumenti di Rete & Firewall openSUSE")
                    font.bold: true
                    Layout.topMargin: Kirigami.Units.smallSpacing
                }

                Kirigami.AbstractCard {
                    Layout.fillWidth: true

                    contentItem: ColumnLayout {
                        spacing: Kirigami.Units.largeSpacing

                        Flow {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.largeSpacing

                            Controls.Button {
                                text: qsTr("YaST Configurazione Schede (LAN)")
                                icon.name: "network-wired"
                                enabled: DesktopBackend.isToolAvailable("yast")
                                onClicked: DesktopBackend.launchYastModule("lan")
                            }

                            Controls.Button {
                                text: qsTr("Firewall di Plasma (KDE)")
                                icon.name: "security-high"
                                enabled: DesktopBackend.isToolAvailable("plasma-firewall")
                                onClicked: DesktopBackend.launchTool("plasma-firewall")
                            }
                        }
                    }
                }
            }
        }
    }

    // Modal Confirmation Dialog for Applying Network Settings
    Controls.Dialog {
        id: applyNetworkConfirmDialog
        title: qsTr("Conferma Applicazione Configurazione Rete")
        standardButtons: Controls.Dialog.Yes | Controls.Dialog.No
        anchors.centerIn: Controls.Overlay.overlay
        width: 480
        modal: true

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.largeSpacing

            Controls.Label {
                text: qsTr("Sei sicuro di voler applicare la configurazione selezionata alla connessione attiva <b>%1</b>?<br><br>L'operazione riconfigurerà l'interfaccia di rete e potrebbe causare una momentanea disconnessione.")
                    .arg(DesktopBackend.networkActiveConnection.length > 0 ? DesktopBackend.networkActiveConnection : qsTr("predefinita"))
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
        }

        onAccepted: DesktopBackend.applyActiveNetworkProfile()
    }

    // Modal Dialog per Modificare i Valori dei Profili IP & DNS
    Controls.Dialog {
        id: editNetworkDialog
        title: qsTr("Personalizzazione Profili IP & DNS")
        modal: true
        anchors.centerIn: Controls.Overlay.overlay
        width: Math.min(root.width - 40, 620)
        standardButtons: Controls.Dialog.Close

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.largeSpacing

            Controls.Label {
                text: qsTr("Modifica gli indirizzi IP, Gateway e DNS assegnati ai pulsanti rapidi:")
                font.bold: true
                Layout.fillWidth: true
            }

            // Tabs per i profili
            Controls.TabBar {
                id: profileTabs
                Layout.fillWidth: true
                Controls.TabButton { text: qsTr("Profilo 1"); font.bold: true }
                Controls.TabButton { text: qsTr("Profilo 2"); font.bold: true }
                Controls.TabButton { text: qsTr("Profilo 3"); font.bold: true }
                Controls.TabButton { text: qsTr("Profilo 4"); font.bold: true }
            }

            StackLayout {
                Layout.fillWidth: true
                currentIndex: profileTabs.currentIndex

                Repeater {
                    model: 4
                    delegate: ColumnLayout {
                        required property int index
                        spacing: Kirigami.Units.smallSpacing
                        Layout.fillWidth: true

                        property var ipData: DesktopBackend.ipPresets[index] || {}
                        property var dnsData: DesktopBackend.dnsPresets[index] || {}

                        function resetFields() {
                            var ip = DesktopBackend.ipPresets[index] || {}
                            var dns = DesktopBackend.dnsPresets[index] || {}
                            ipNameField.text = ip.name || ""
                            ipAddrField.text = ip.address || ""
                            ipGwField.text = ip.gateway || ""
                            dnsNameField.text = dns.name || ""
                            dnsServerField.text = dns.dns || ""
                            dnsDohField.text = dns.dohUrl || ""
                        }

                        Connections {
                            target: editNetworkDialog
                            function onOpened() { resetFields() }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Controls.Label { text: qsTr("Nome Profilo IP:"); Layout.preferredWidth: 140 }
                            Controls.TextField {
                                id: ipNameField
                                Layout.fillWidth: true
                                text: ipData.name || ""
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Controls.Label { text: qsTr("Indirizzo IP:"); Layout.preferredWidth: 140 }
                            Controls.TextField {
                                id: ipAddrField
                                Layout.fillWidth: true
                                text: ipData.address || ""
                                placeholderText: "es. 192.168.1.50/24 (vuoto per DHCP)"
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Controls.Label { text: qsTr("Gateway:"); Layout.preferredWidth: 140 }
                            Controls.TextField {
                                id: ipGwField
                                Layout.fillWidth: true
                                text: ipData.gateway || ""
                                placeholderText: "es. 192.168.11.1"
                            }
                        }

                        Kirigami.Separator { Layout.fillWidth: true }

                        RowLayout {
                            Layout.fillWidth: true
                            Controls.Label { text: qsTr("Nome Profilo DNS:"); Layout.preferredWidth: 140 }
                            Controls.TextField {
                                id: dnsNameField
                                Layout.fillWidth: true
                                text: dnsData.name || ""
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Controls.Label { text: qsTr("Server DNS:"); Layout.preferredWidth: 140 }
                            Controls.TextField {
                                id: dnsServerField
                                Layout.fillWidth: true
                                text: dnsData.dns || ""
                                placeholderText: "es. 1.1.1.1 1.0.0.1"
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Controls.Label { text: qsTr("URL DoH (annotazione):"); Layout.preferredWidth: 140 }
                            Controls.TextField {
                                id: dnsDohField
                                Layout.fillWidth: true
                                text: dnsData.dohUrl || ""
                                placeholderText: "es. https://cloudflare-dns.com/dns-query"
                            }
                        }

                        Controls.Button {
                            Layout.alignment: Qt.AlignRight
                            text: qsTr("Salva Profilo %1").arg(index + 1)
                            icon.name: "document-save"
                            highlighted: true
                            onClicked: {
                                var nName = ipNameField.text.trim()
                                var nAddr = ipAddrField.text.trim()
                                var nGw = ipGwField.text.trim()
                                var dName = dnsNameField.text.trim()
                                var dSrv = dnsServerField.text.trim()
                                var dDoh = dnsDohField.text.trim()
                                if (DesktopBackend.saveIpPreset(index, nName, nAddr, nGw)) {
                                    DesktopBackend.saveDnsPreset(index, dName, dSrv, dDoh)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
