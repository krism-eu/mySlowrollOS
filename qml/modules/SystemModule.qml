import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami
import org.myslowrollos.controlcenter

Kirigami.ScrollablePage {
    id: root
    title: qsTr("Sistema & Boot")

    Timer {
        interval: 2000
        running: root.StackLayout.isCurrentItem && Qt.application.state === Qt.ApplicationActive
        repeat: true
        onTriggered: {
            DesktopBackend.refreshTopMemoryProcesses()
        }
    }

    StackLayout.onIsCurrentItemChanged: {
        if (root.StackLayout.isCurrentItem) {
            DesktopBackend.refreshTopMemoryProcesses()
            SlowrollBackend.refreshAtomicState()
            SlowrollBackend.refreshUefiEntries()
        }
    }

    property string pendingBootNextCode: ""
    property string pendingBootNextName: ""

    Component.onCompleted: {
        DesktopBackend.refreshPowerProfile()
        SlowrollBackend.refreshAtomicState()
        SlowrollBackend.refreshUefiEntries()
    }

    ColumnLayout {
        width: parent.width
        spacing: UiMetrics.cardSpacing

        // 1. Selezione Prossimo Avvio (UEFI efibootmgr)
        Kirigami.AbstractCard {
            Layout.fillWidth: true
            visible: SlowrollBackend.uefiAvailable

            contentItem: ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.largeSpacing

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    Kirigami.Icon { source: "system-run"; Layout.preferredWidth: 32; Layout.preferredHeight: 32 }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        Kirigami.Heading { level: 2; text: qsTr("Selezione Prossimo Avvio UEFI (efibootmgr)"); font.bold: true }
                        Controls.Label {
                            text: qsTr("Imposta quale sistema o bootloader eseguire al riavvio successivo senza modificare i file EFI permanenti.")
                            opacity: UiMetrics.secondaryOpacity
                        }
                    }

                    Controls.Button {
                        text: qsTr("Aggiorna Voci")
                        icon.name: "view-refresh"
                        Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                        enabled: !DesktopBackend.busy && !SlowrollBackend.busy
                        onClicked: SlowrollBackend.refreshUefiEntries()
                    }
                }

                Kirigami.Separator { Layout.fillWidth: true }

                GridLayout {
                    Layout.fillWidth: true
                    columns: root.width > 700 ? 2 : 1
                    columnSpacing: Kirigami.Units.largeSpacing
                    rowSpacing: Kirigami.Units.smallSpacing

                    ColumnLayout {
                        spacing: 2
                        Controls.Label { text: qsTr("Voce di Avvio Corrente:"); font.bold: true; opacity: UiMetrics.secondaryOpacity }
                        Controls.Label {
                            text: SlowrollBackend.uefiCurrentBootCode.length > 0
                                  ? qsTr("[#%1] %2").arg(SlowrollBackend.uefiCurrentBootCode).arg(SlowrollBackend.uefiCurrentBootLabel)
                                  : qsTr("Non rilevata")
                            font.bold: true
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                    }

                    ColumnLayout {
                        spacing: 2
                        Controls.Label { text: qsTr("Prossimo Avvio Programmato (BootNext):"); font.bold: true; opacity: UiMetrics.secondaryOpacity }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing
                            Controls.Label {
                                text: SlowrollBackend.uefiNextBootCode.length > 0
                                      ? qsTr("[#%1] %2").arg(SlowrollBackend.uefiNextBootCode).arg(SlowrollBackend.uefiNextBootLabel)
                                      : qsTr("Nessuno (avvio predefinito)")
                                font.bold: SlowrollBackend.uefiNextBootCode.length > 0
                                color: SlowrollBackend.uefiNextBootCode.length > 0 ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.textColor
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                            Controls.Button {
                                visible: SlowrollBackend.uefiNextBootCode.length > 0
                                text: qsTr("Annulla")
                                icon.name: "edit-undo"
                                enabled: !DesktopBackend.busy && !SlowrollBackend.busy
                                onClicked: cancelBootNextConfirmDialog.open()
                            }
                        }
                    }
                }

                Kirigami.Separator { Layout.fillWidth: true }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.mediumSpacing

                    Controls.Label {
                        text: qsTr("Seleziona voce per il prossimo boot:")
                        font.bold: true
                    }

                    Controls.ComboBox {
                        id: uefiCombo
                        Layout.fillWidth: true
                        model: SlowrollBackend.uefiEntries
                        textRole: "label"
                    }

                    Controls.Button {
                        text: qsTr("Imposta al Prossimo Riavvio")
                        icon.name: "system-reboot"
                        enabled: !DesktopBackend.busy && !SlowrollBackend.busy && uefiCombo.currentIndex >= 0
                        onClicked: {
                            var currentEntry = SlowrollBackend.uefiEntries[uefiCombo.currentIndex];
                            if (currentEntry) {
                                root.pendingBootNextCode = currentEntry.code;
                                root.pendingBootNextName = currentEntry.name;
                                setBootNextConfirmDialog.open();
                            }
                        }
                    }
                }
            }
        }

        // 2. Monitor Processi ad Alto Consumo RAM (Top 6)
        Kirigami.Heading {
            level: 2
            text: qsTr("Processi ad Alto Consumo RAM (Top 6)")
            font.bold: true
            Layout.topMargin: Kirigami.Units.smallSpacing
        }

        Kirigami.AbstractCard {
            Layout.fillWidth: true

            contentItem: ColumnLayout {
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    Kirigami.Icon {
                        Layout.preferredWidth: 32
                        Layout.preferredHeight: 32
                        source: "media-flash"
                        color: Kirigami.Theme.highlightColor
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        Kirigami.Heading { level: 3; text: qsTr("Monitor Utilizzo Memoria Processi"); font.bold: true }
                        Controls.Label {
                            text: qsTr("Campionamento in tempo reale (ogni 2 sec) dei 6 processi con il maggior consumo di memoria fisica (RSS).")
                            opacity: UiMetrics.secondaryOpacity
                        }
                    }

                    Controls.Button {
                        text: qsTr("Monitor di Sistema KDE")
                        icon.name: "utilities-system-monitor"
                        enabled: DesktopBackend.isToolAvailable("systemmonitor")
                        onClicked: DesktopBackend.launchTool("systemmonitor")
                    }

                    Controls.Button {
                        text: qsTr("Aggiorna")
                        icon.name: "view-refresh"
                        onClicked: DesktopBackend.refreshTopMemoryProcesses()
                    }
                }

                Kirigami.Separator { Layout.fillWidth: true }

                // Header Tabella
                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 8
                    Layout.rightMargin: 24

                    Controls.Label {
                        text: qsTr("PID")
                        Layout.preferredWidth: 70
                        font.bold: true
                        opacity: UiMetrics.secondaryOpacity
                    }
                    Controls.Label {
                        text: qsTr("PROCESSO")
                        Layout.fillWidth: true
                        font.bold: true
                        opacity: UiMetrics.secondaryOpacity
                    }
                    Controls.Label {
                        text: qsTr("MEMORIA RSS")
                        Layout.preferredWidth: 100
                        horizontalAlignment: Text.AlignRight
                        font.bold: true
                        opacity: UiMetrics.secondaryOpacity
                    }
                    Controls.Label {
                        text: qsTr("% RAM")
                        Layout.preferredWidth: 70
                        horizontalAlignment: Text.AlignRight
                        font.bold: true
                        opacity: UiMetrics.secondaryOpacity
                    }
                }

                Kirigami.Separator { Layout.fillWidth: true }

                // Righe Processi
                Repeater {
                    model: DesktopBackend.topMemoryProcesses
                    delegate: Rectangle {
                        required property var modelData
                        required property int index
                        Layout.fillWidth: true
                        Layout.preferredHeight: 28
                        color: index % 2 === 0 ? Qt.rgba(Kirigami.Theme.alternateBackgroundColor.r, Kirigami.Theme.alternateBackgroundColor.g, Kirigami.Theme.alternateBackgroundColor.b, 0.5) : "transparent"
                        radius: 4

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 24

                            Controls.Label {
                                text: modelData.pid
                                Layout.preferredWidth: 70
                                font.family: Kirigami.Theme.fixedWidthFont.family
                                opacity: UiMetrics.secondaryOpacity
                            }

                            Controls.Label {
                                text: modelData.name
                                Layout.fillWidth: true
                                font.bold: true
                                elide: Text.ElideRight
                            }

                            Controls.Label {
                                text: modelData.memRss
                                Layout.preferredWidth: 100
                                horizontalAlignment: Text.AlignRight
                                font.bold: true
                                color: Kirigami.Theme.highlightColor
                            }

                            Controls.Label {
                                text: modelData.memPercent
                                Layout.preferredWidth: 70
                                horizontalAlignment: Text.AlignRight
                                font.bold: true
                            }
                        }
                    }
                }

                Controls.Label {
                    visible: DesktopBackend.topMemoryProcesses.length === 0
                    text: qsTr("Campionamento processi in corso...")
                    opacity: UiMetrics.secondaryOpacity
                    Layout.alignment: Qt.AlignHCenter
                }
            }
        }

        // 3. Controllo Riavvio & Alimentazione (Sempre visibile sia su UEFI che BIOS)
        Kirigami.Heading {
            level: 2
            text: qsTr("Controllo Riavvio & Alimentazione")
            font.bold: true
            Layout.topMargin: Kirigami.Units.smallSpacing
        }

        Kirigami.AbstractCard {
            Layout.fillWidth: true

            contentItem: RowLayout {
                spacing: Kirigami.Units.largeSpacing

                Kirigami.Icon {
                    source: "system-reboot"
                    Layout.preferredWidth: 32
                    Layout.preferredHeight: 32
                    color: Kirigami.Theme.highlightColor
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Kirigami.Heading { level: 3; text: qsTr("Azioni di Riavvio Sistema"); font.bold: true }
                    Controls.Label {
                        text: SlowrollBackend.efiSystem
                              ? qsTr("Esegui il riavvio standard o accedi direttamente alle impostazioni del firmware UEFI.")
                              : qsTr("Esegui il riavvio controllato del sistema operativo.")
                        opacity: UiMetrics.secondaryOpacity
                    }
                }

                Controls.Button {
                    text: qsTr("Riavvia Sistema")
                    icon.name: "system-reboot"
                    enabled: !DesktopBackend.busy && !SlowrollBackend.busy
                    onClicked: rebootConfirmDialog.open()
                }

                Controls.Button {
                    text: qsTr("Riavvia in Firmware UEFI")
                    icon.name: "system-run"
                    enabled: SlowrollBackend.efiSystem && !DesktopBackend.busy && !SlowrollBackend.busy
                    visible: SlowrollBackend.efiSystem
                    onClicked: firmwareConfirmDialog.open()
                }
            }
        }

        Kirigami.AbstractCard {
            Layout.fillWidth: true

            contentItem: ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.largeSpacing

                RowLayout {
                    Layout.fillWidth: true
                    Kirigami.Icon { source: "battery-charging"; Layout.preferredWidth: 32; Layout.preferredHeight: 32 }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        Kirigami.Heading { level: 3; text: qsTr("Profilo Energetico & Sospensione"); font.bold: true }
                        Controls.Label {
                            text: qsTr("Configurazione tempi di inattività monitor e sospensione automatica del sistema (KDE PowerDevil). Profilo attivo: <b>%1</b>").arg(
                                DesktopBackend.powerProfile === "60min" ? qsTr("60 Minuti (Monitor 4m, PC 60m)") :
                                DesktopBackend.powerProfile === "180min" ? qsTr("180 Minuti (Monitor 3m, PC 180m)") :
                                qsTr("Standard (Predefinito)")
                            )
                            opacity: UiMetrics.secondaryOpacity
                        }
                    }
                }

                Kirigami.Separator { Layout.fillWidth: true }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    Controls.Button {
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                        Layout.preferredHeight: 44
                        text: qsTr("Standard")
                        icon.name: "preferences-system-power-management"
                        highlighted: DesktopBackend.powerProfile === "standard"
                        onClicked: DesktopBackend.setPowerProfile("standard")
                    }

                    Controls.Button {
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                        Layout.preferredHeight: 44
                        text: qsTr("60 min")
                        icon.name: "preferences-system-time"
                        highlighted: DesktopBackend.powerProfile === "60min"
                        onClicked: DesktopBackend.setPowerProfile("60min")
                    }

                    Controls.Button {
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                        Layout.preferredHeight: 44
                        text: qsTr("180 min")
                        icon.name: "preferences-system-time"
                        highlighted: DesktopBackend.powerProfile === "180min"
                        onClicked: DesktopBackend.setPowerProfile("180min")
                    }
                }
            }
        }

        // 4. Aggiornamenti Atomici del Sistema
        Kirigami.AbstractCard {
            Layout.fillWidth: true

            contentItem: ColumnLayout {
                spacing: Kirigami.Units.largeSpacing

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    Kirigami.Icon {
                        Layout.preferredWidth: 36
                        Layout.preferredHeight: 36
                        source: "system-software-update"
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        Kirigami.Heading { level: 2; text: qsTr("Aggiornamenti Atomici del Sistema"); font.bold: true }
                        Controls.Label {
                            text: qsTr("Gestiti dal motore atomic-update transazionale su snapshot Btrfs.")
                            opacity: UiMetrics.secondaryOpacity
                        }
                    }

                    Controls.Button {
                        text: qsTr("Aggiorna Stato")
                        icon.name: "view-refresh"
                        enabled: !DesktopBackend.busy && !SlowrollBackend.busy
                        onClicked: SlowrollBackend.refreshAtomicState()
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
                        Controls.Label { text: qsTr("Stato Transazione"); font.bold: true; opacity: UiMetrics.secondaryOpacity }
                        Controls.Label {
                            text: SlowrollBackend.atomicStatus.toUpperCase()
                            font.bold: true
                            color: SlowrollBackend.pendingReboot ? Kirigami.Theme.positiveTextColor : (SlowrollBackend.needsInspection ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor)
                        }
                    }

                    ColumnLayout {
                        spacing: 2
                        Controls.Label { text: qsTr("Ultima Transazione"); font.bold: true; opacity: UiMetrics.secondaryOpacity }
                        Controls.Label {
                            text: SlowrollBackend.lastCheckTime.length > 0 ? SlowrollBackend.lastCheckTime : qsTr("Nessuna registrata")
                        }
                    }

                    ColumnLayout {
                        spacing: 2
                        Controls.Label { text: qsTr("Snapshot Target"); font.bold: true; opacity: UiMetrics.secondaryOpacity }
                        Controls.Label {
                            text: SlowrollBackend.defaultSnapshot > 0 ? "#" + SlowrollBackend.defaultSnapshot : qsTr("Nessuno")
                            font.bold: true
                        }
                    }
                }
            }
        }

        // 5. Moduli di Sistema YaST
        Kirigami.Heading {
            level: 2
            text: qsTr("Amministrazione Sistema openSUSE (YaST)")
            font.bold: true
            Layout.topMargin: Kirigami.Units.smallSpacing
        }

        Kirigami.AbstractCard {
            Layout.fillWidth: true

            contentItem: ColumnLayout {
                spacing: Kirigami.Units.largeSpacing

                RowLayout {
                    Layout.fillWidth: true
                    Kirigami.Icon { source: "yast-control-center"; Layout.preferredWidth: 32; Layout.preferredHeight: 32 }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        Kirigami.Heading { level: 3; text: qsTr("Moduli Amministrativi YaST"); font.bold: true }
                        Controls.Label {
                            text: qsTr("Strumenti integrati di sistema per partizioni (KDE Partition Manager), configurazione e utenti.")
                            opacity: UiMetrics.secondaryOpacity
                        }
                    }
                }

                Kirigami.Separator { Layout.fillWidth: true }

                GridLayout {
                    Layout.fillWidth: true
                    columns: root.width > 700 ? 3 : 1
                    columnSpacing: UiMetrics.cardSpacing
                    rowSpacing: UiMetrics.cardSpacing

                    Controls.Button {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 46
                        text: qsTr("Gestore Partizioni (KDE)")
                        icon.name: "partitionmanager"
                        enabled: DesktopBackend.isToolAvailable("partitionmanager")
                        onClicked: DesktopBackend.launchTool("partitionmanager")
                    }

                    Controls.Button {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 46
                        text: qsTr("Configurazione Sysconfig")
                        icon.name: "preferences-system"
                        enabled: DesktopBackend.isToolAvailable("yast")
                        onClicked: DesktopBackend.launchYastModule("sysconfig")
                    }

                    Controls.Button {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 46
                        text: qsTr("Utenti e Gruppi")
                        icon.name: "system-users"
                        enabled: DesktopBackend.isToolAvailable("yast")
                        onClicked: DesktopBackend.launchYastModule("users")
                    }
                }
            }
        }
    }

    // Modal Confirmation Dialogs for risky reboot operations
    Controls.Dialog {
        id: firmwareConfirmDialog
        title: qsTr("Conferma Riavvio nel Firmware")
        standardButtons: Controls.Dialog.Yes | Controls.Dialog.No
        width: 480
        anchors.centerIn: Controls.Overlay.overlay
        modal: true
        contentItem: ColumnLayout {
            spacing: Kirigami.Units.largeSpacing
            Controls.Label {
                text: qsTr("Il sistema verrà riavviato immediatamente accedendo al menu di configurazione UEFI/BIOS. Continuare?")
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
        }
        onAccepted: DesktopBackend.rebootToFirmware()
    }

    Controls.Dialog {
        id: rebootConfirmDialog
        title: qsTr("Conferma Riavvio")
        standardButtons: Controls.Dialog.Yes | Controls.Dialog.No
        width: 480
        anchors.centerIn: Controls.Overlay.overlay
        modal: true
        contentItem: ColumnLayout {
            spacing: Kirigami.Units.largeSpacing
            Controls.Label {
                text: qsTr("Sei sicuro di voler riavviare il computer adesso?")
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
        }
        onAccepted: DesktopBackend.rebootSystem()
    }

    Controls.Dialog {
        id: setBootNextConfirmDialog
        title: qsTr("Conferma Prossimo Avvio UEFI")
        standardButtons: Controls.Dialog.Yes | Controls.Dialog.No
        width: 480
        anchors.centerIn: Controls.Overlay.overlay
        modal: true
        contentItem: ColumnLayout {
            spacing: Kirigami.Units.largeSpacing
            Controls.Label {
                text: qsTr("Vuoi impostare la voce <b>[#%1] %2</b> per il prossimo riavvio del computer?<br><br>Questa operazione (<code>BootNext</code>) istruisce il firmware UEFI ad avviare questo sistema una sola volta. Ai successivi riavvii tornerà l'ordine di avvio normale.")
                      .arg(root.pendingBootNextCode).arg(root.pendingBootNextName)
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
        }
        onAccepted: SlowrollBackend.setUefiBootNext(root.pendingBootNextCode)
    }

    Controls.Dialog {
        id: cancelBootNextConfirmDialog
        title: qsTr("Annulla Prossimo Avvio")
        standardButtons: Controls.Dialog.Yes | Controls.Dialog.No
        width: 480
        anchors.centerIn: Controls.Overlay.overlay
        modal: true
        contentItem: ColumnLayout {
            spacing: Kirigami.Units.largeSpacing
            Controls.Label {
                text: qsTr("Vuoi rimuovere l'impostazione di BootNext? Il computer utilizzerà l'ordine di avvio predefinito.")
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
        }
        onAccepted: SlowrollBackend.clearUefiBootNext()
    }
}
