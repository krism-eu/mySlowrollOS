import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami
import org.myslowrollos.controlcenter

Kirigami.ScrollablePage {
    id: root
    title: qsTr("Comandi")

    property string editingActionId: ""
    property string editingActionIcon: "utilities-terminal"
    property string pendingRunActionId: ""
    property string pendingRunActionName: ""
    property string pendingDeleteActionId: ""
    property string pendingDeleteActionName: ""

    readonly property var predefinedCommands: [
        { id: "gpu-driver", title: qsTr("Driver GPU e OpenGL"), command: "glxinfo -B", note: qsTr("Verifica quale scheda video è attiva e quale driver grafico (Mesa/Intel/AMD/NVIDIA) è in uso.") },
        { id: "vulkan-info", title: qsTr("Riepilogo Runtime Vulkan"), command: "vulkaninfo --summary", note: qsTr("Verifica supporto e runtime Vulkan installati per rendering 3D e gaming.") },
        { id: "failed-units", title: qsTr("Unità di sistema fallite"), command: "systemctl --failed --no-pager --plain", note: qsTr("Elenco dei servizi e unità systemd attualmente in stato di errore.") },
        { id: "user-failed-units", title: qsTr("Unità utente fallite"), command: "systemctl --user --failed --no-pager --plain", note: qsTr("Servizi della sessione utente corrente in stato di errore.") },
        { id: "journal-errors", title: qsTr("Errori ultimo avvio"), command: "journalctl -b -p warning --no-pager -n 150", note: qsTr("Warning ed errori recenti registrati nel log di sistema dall'ultimo boot.") },
        { id: "kernel-errors", title: qsTr("Messaggi del Kernel"), command: "journalctl -k -b -p warning --no-pager -n 150", note: qsTr("Warning e messaggi del ring buffer kernel dall'ultimo avvio.") },
        { id: "journal-size", title: qsTr("Spazio occupato dal Journal"), command: "journalctl --disk-usage", note: qsTr("Quantità di spazio su disco occupata dai registri persistenti.") },
        { id: "uptime", title: qsTr("Tempo di attività (Uptime)"), command: "uptime -p", note: qsTr("Tempo trascorso dall'ultimo avvio del sistema.") },
        { id: "boot-time", title: qsTr("Tempo di avvio del sistema"), command: "systemd-analyze time", note: qsTr("Tempo complessivo impiegato dal firmware, bootloader, kernel e userspace.") },
        { id: "blame", title: qsTr("Servizi più lenti all'avvio"), command: "systemd-analyze blame | head -n 30", note: qsTr("Unità di avvio ordinate per tempo impiegato per l'inizializzazione.") },
        { id: "critical-chain", title: qsTr("Catena critica di boot"), command: "systemd-analyze critical-chain", note: qsTr("Albero delle dipendenze che incidono sul percorso critico dell'avvio.") },
        { id: "ports", title: qsTr("Porte di rete in ascolto"), command: "ss -lntu", note: qsTr("Socket TCP e UDP attualmente in ascolto sulle interfacce di rete.") },
        { id: "network", title: qsTr("Interfacce di rete e IP"), command: "ip -brief address", note: qsTr("Indirizzi IPv4/IPv6 e stato delle schede di rete in formato compatto.") },
        { id: "routes", title: qsTr("Tabella di routing"), command: "ip route", note: qsTr("Tabella corrente delle rotte di rete e gateway predefinito.") },
        { id: "dns", title: qsTr("Stato resolver DNS"), command: "resolvectl status", note: qsTr("Configurazione corrente del resolver DNS per interfaccia attiva.") },
        { id: "partitions", title: qsTr("Dischi e partizioni (lsblk)"), command: "lsblk -e 7 -o NAME,PARTN,SIZE,FSTYPE,FSVER,LABEL,UUID,MOUNTPOINTS", note: qsTr("Mappa dettagliata dei dischi, subvolume Btrfs, UUID e punti di mount.") },
        { id: "disk-space", title: qsTr("Spazio filesystem (df -hT)"), command: "df -hT -x tmpfs -x devtmpfs", note: qsTr("Percentuale di utilizzo e spazio libero dei filesystem persistenti.") },
        { id: "inodes", title: qsTr("Inode del filesystem"), command: "df -hi -x tmpfs -x devtmpfs", note: qsTr("Utilizzo degli inode, fondamentale per verificare che il disco non sia saturo.") },
        { id: "timers", title: qsTr("Timer pianificati systemd"), command: "systemctl list-timers --all --no-pager", note: qsTr("Attività pianificate e orari delle prossime esecuzioni.") },
        { id: "sessions", title: qsTr("Sessioni di login"), command: "loginctl list-sessions --no-legend", note: qsTr("Elenco delle sessioni utente riconosciute da systemd-logind.") },
        { id: "shell-path", title: qsTr("Variabile PATH di sessione"), command: "printenv PATH", note: qsTr("Elenco delle cartelle in cui la shell cerca i comandi eseguibili.") }
    ]

    function filteredCommands() {
        var query = searchField.text.trim().toLowerCase()
        if (query.length === 0)
            return root.predefinedCommands
        var result = []
        for (var i = 0; i < root.predefinedCommands.length; ++i) {
            var item = root.predefinedCommands[i]
            var haystack = (item.title + " " + item.command + " " + item.note).toLowerCase()
            if (haystack.indexOf(query) >= 0)
                result.push(item)
        }
        return result
    }

    ColumnLayout {
        width: parent.width
        spacing: UiMetrics.cardSpacing

        Controls.TabBar {
            id: commandTabs
            Layout.fillWidth: true
            Controls.TabButton { text: qsTr("Predefiniti (Diagnostica)"); font.bold: true }
            Controls.TabButton { text: qsTr("Miei Comandi"); font.bold: true }
            Controls.TabButton { text: qsTr("Utility Shell"); font.bold: true }
        }

        StackLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: currentItem ? currentItem.implicitHeight : 0
            currentIndex: commandTabs.currentIndex

            // TAB 1: Comandi Predefiniti
            ColumnLayout {
                spacing: UiMetrics.cardSpacing

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    Controls.TextField {
                        id: searchField
                        Layout.fillWidth: true
                        placeholderText: qsTr("Cerca comando per nome, eseguibile o parola chiave...")
                    }

                    Controls.Button {
                        text: qsTr("Pulisci")
                        icon.name: "edit-clear"
                        enabled: searchField.text.length > 0
                        onClicked: searchField.clear()
                    }
                }

                GridLayout {
                    id: commandsGrid
                    Layout.fillWidth: true
                    columns: root.width > 860 ? 2 : 1
                    columnSpacing: UiMetrics.cardSpacing
                    rowSpacing: UiMetrics.cardSpacing

                    Repeater {
                        model: root.filteredCommands()
                        delegate: Kirigami.AbstractCard {
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.preferredWidth: commandsGrid.columns === 2 ? Math.floor((commandsGrid.width - commandsGrid.columnSpacing) / 2) : commandsGrid.width

                            contentItem: ColumnLayout {
                                spacing: Kirigami.Units.smallSpacing

                                RowLayout {
                                    Layout.fillWidth: true
                                    Kirigami.Heading {
                                        level: 4
                                        font.bold: true
                                        text: modelData.title
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                    }

                                    Controls.Button {
                                        icon.name: "edit-copy"
                                        display: Controls.AbstractButton.IconOnly
                                        Controls.ToolTip.visible: hovered
                                        Controls.ToolTip.text: qsTr("Copia comando negli appunti")
                                        onClicked: DesktopBackend.copyToClipboard(modelData.command)
                                    }

                                    Controls.Button {
                                        text: qsTr("Esegui")
                                        icon.name: "media-playback-start"
                                        onClicked: DesktopBackend.runCommand(modelData.command, modelData.title)
                                    }
                                }

                                Controls.Label {
                                    text: modelData.command
                                    font.family: Kirigami.Theme.fixedWidthFont.family
                                    font.bold: true
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    color: Kirigami.Theme.highlightColor
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }

                                Controls.Label {
                                    text: modelData.note
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    opacity: UiMetrics.secondaryOpacity
                                    wrapMode: Text.WordWrap
                                    Layout.fillWidth: true
                                }
                            }
                        }
                    }
                }

                // Output Viewer Card
                OutputCard {
                    title: DesktopBackend.diagnosticTitle.length > 0 ? DesktopBackend.diagnosticTitle : qsTr("Output Comando")
                    outputText: DesktopBackend.diagnosticOutput
                    onCloseRequested: DesktopBackend.clearDiagnostic()
                }
            }

            // TAB 2: Miei Comandi (Azioni Personali)
            ColumnLayout {
                spacing: UiMetrics.cardSpacing

                Kirigami.AbstractCard {
                    Layout.fillWidth: true

                    contentItem: ColumnLayout {
                        spacing: Kirigami.Units.largeSpacing

                        RowLayout {
                            Layout.fillWidth: true
                            Kirigami.Icon { source: "utilities-terminal"; Layout.preferredWidth: 32; Layout.preferredHeight: 32 }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                Kirigami.Heading { level: 2; text: qsTr("Azioni Personali (Script Bash)"); font.bold: true }
                                Controls.Label {
                                    text: qsTr("Fino a 12 script personali eseguiti nel profilo dell'utente corrente.")
                                    opacity: UiMetrics.secondaryOpacity
                                }
                            }
                            Controls.Button {
                                text: qsTr("Azzera Lista")
                                icon.name: "edit-clear"
                                enabled: !DesktopBackend.busy && !SlowrollBackend.busy
                                onClicked: resetConfirmDialog.open()
                            }
                            Controls.Button {
                                text: qsTr("Nuova Azione")
                                icon.name: "list-add"
                                onClicked: {
                                    root.editingActionId = ""
                                    root.editingActionIcon = "utilities-terminal"
                                    actionNameField.text = ""
                                    actionScriptField.text = ""
                                    actionConfirmCheck.checked = true
                                    actionEditDialog.open()
                                }
                            }
                        }

                        Controls.Label {
                            visible: DesktopBackend.actionError.length > 0
                            text: DesktopBackend.actionError
                            color: Kirigami.Theme.negativeTextColor
                            font.bold: true
                            wrapMode: Text.WordWrap
                            Layout.fillWidth: true
                        }

                        Kirigami.Separator { Layout.fillWidth: true }

                        Controls.Label {
                            visible: DesktopBackend.customActions.length === 0
                            text: qsTr("Nessuna azione personale configurata. Fai clic su 'Nuova Azione' per crearne una.")
                            opacity: UiMetrics.secondaryOpacity
                            font.italic: true
                        }

                        Repeater {
                            model: DesktopBackend.customActions
                            delegate: Controls.ItemDelegate {
                                required property var modelData
                                Layout.fillWidth: true

                                contentItem: RowLayout {
                                    spacing: Kirigami.Units.largeSpacing

                                    Kirigami.Icon {
                                        source: modelData.icon || "utilities-terminal"
                                        Layout.preferredWidth: 24
                                        Layout.preferredHeight: 24
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 1
                                        Controls.Label {
                                            text: modelData.name
                                            font.bold: true
                                        }
                                        Controls.Label {
                                            text: modelData.script.replace(/\n/g, " ; ")
                                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                                            opacity: UiMetrics.secondaryOpacity
                                            elide: Text.ElideRight
                                            Layout.fillWidth: true
                                        }
                                    }

                                    Controls.Button {
                                        text: qsTr("Esegui")
                                        icon.name: "media-playback-start"
                                        enabled: !DesktopBackend.actionRunning && !DesktopBackend.busy && !SlowrollBackend.busy
                                        onClicked: {
                                            if (modelData.confirm) {
                                                root.pendingRunActionId = modelData.id
                                                root.pendingRunActionName = modelData.name
                                                runConfirmDialog.open()
                                            } else {
                                                DesktopBackend.runCustomAction(modelData.id)
                                            }
                                        }
                                    }

                                    Controls.Button {
                                        icon.name: "edit-entry"
                                        onClicked: {
                                            root.editingActionId = modelData.id
                                            root.editingActionIcon = modelData.icon || "utilities-terminal"
                                            actionNameField.text = modelData.name
                                            actionScriptField.text = modelData.script
                                            actionConfirmCheck.checked = modelData.confirm
                                            actionEditDialog.open()
                                        }
                                    }

                                    Controls.Button {
                                        icon.name: "edit-delete"
                                        onClicked: {
                                            root.pendingDeleteActionId = modelData.id
                                            root.pendingDeleteActionName = modelData.name
                                            deleteConfirmDialog.open()
                                        }
                                    }
                                }
                            }
                        }

                        // Custom Action Output
                        OutputCard {
                            title: qsTr("Output Azione Personale")
                            outputText: DesktopBackend.actionOutput + (DesktopBackend.actionError.length > 0 ? "\n[" + DesktopBackend.actionError + "]" : "")
                            onCloseRequested: DesktopBackend.clearActionOutput()
                        }
                    }
                }
            }

            // TAB 3: Utility Shell
            ColumnLayout {
                spacing: UiMetrics.cardSpacing

                // 1. Prompt Presets Card
                Kirigami.AbstractCard {
                    Layout.fillWidth: true

                    contentItem: ColumnLayout {
                        spacing: Kirigami.Units.largeSpacing

                        RowLayout {
                            spacing: Kirigami.Units.largeSpacing
                            Kirigami.Icon { source: "preferences-desktop-font"; Layout.preferredWidth: 28; Layout.preferredHeight: 28 }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                Kirigami.Heading { level: 3; text: qsTr("Preset Bash Prompt"); font.bold: true }
                                Controls.Label {
                                    text: qsTr("Stato attuale nel file ~/.bashrc: <b>%1</b>").arg(DesktopBackend.promptStatus)
                                    opacity: UiMetrics.secondaryOpacity
                                }
                            }
                        }

                        GridLayout {
                            Layout.fillWidth: true
                            columns: root.width > 860 ? 4 : (root.width > 500 ? 2 : 1)
                            columnSpacing: UiMetrics.cardSpacing
                            rowSpacing: UiMetrics.cardSpacing

                            Controls.Button {
                                Layout.fillWidth: true
                                text: qsTr("Prompt Leggibile (2 righe)")
                                icon.name: "format-line-spacing-triple"
                                onClicked: DesktopBackend.applyBashPromptPreset("readable")
                            }

                            Controls.Button {
                                Layout.fillWidth: true
                                text: qsTr("Prompt Compatto")
                                icon.name: "format-line-spacing-normal"
                                onClicked: DesktopBackend.applyBashPromptPreset("compact")
                            }

                            Controls.Button {
                                Layout.fillWidth: true
                                text: qsTr("Prompt Minimal")
                                icon.name: "text-field"
                                onClicked: DesktopBackend.applyBashPromptPreset("minimal")
                            }

                            Controls.Button {
                                Layout.fillWidth: true
                                text: qsTr("Ripristina Predefinito")
                                icon.name: "edit-undo"
                                onClicked: DesktopBackend.applyBashPromptPreset("predefinito")
                            }
                        }
                    }
                }


            }
        }
    }



    // Dialog for Editing Action
    Controls.Dialog {
        id: actionEditDialog
        title: root.editingActionId.length > 0 ? qsTr("Modifica Azione") : qsTr("Crea Nuova Azione")
        standardButtons: Controls.Dialog.Save | Controls.Dialog.Cancel
        width: 480
        anchors.centerIn: Controls.Overlay.overlay
        modal: true

        onOpened: {
            var saveBtn = actionEditDialog.standardButton(Controls.Dialog.Save)
            if (saveBtn) {
                saveBtn.enabled = Qt.binding(function() {
                    return actionNameField.text.trim().length > 0 && actionScriptField.text.trim().length > 0
                })
            }
        }

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.largeSpacing

            Controls.Label { text: qsTr("Nome Azione:"); font.bold: true }
            Controls.TextField {
                id: actionNameField
                Layout.fillWidth: true
                placeholderText: qsTr("Es. Pulisci Cache Locale")
            }

            Controls.Label { text: qsTr("Comando / Script Bash:"); font.bold: true }
            Controls.ScrollView {
                Layout.fillWidth: true
                Layout.preferredHeight: 120
                Controls.TextArea {
                    id: actionScriptField
                    placeholderText: qsTr("Es. echo 'Avvio operazione...' && rm -rf ~/.cache/app_temp/*")
                    font: Kirigami.Theme.fixedWidthFont
                    wrapMode: Text.WrapAnywhere
                }
            }

            Controls.CheckBox {
                id: actionConfirmCheck
                text: qsTr("Chiedi sempre conferma prima di eseguire")
            }
        }

        onAccepted: {
            if (actionNameField.text.trim().length === 0 || actionScriptField.text.trim().length === 0)
                return
            DesktopBackend.saveCustomAction(root.editingActionId,
                                            actionNameField.text.trim(),
                                            actionScriptField.text.trim(),
                                            actionConfirmCheck.checked,
                                            root.editingActionIcon)
        }
    }

    // Confirmation dialog for running action
    Controls.Dialog {
        id: runConfirmDialog
        title: qsTr("Conferma Esecuzione")
        standardButtons: Controls.Dialog.Yes | Controls.Dialog.No
        width: 480
        anchors.centerIn: Controls.Overlay.overlay
        modal: true

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.largeSpacing
            Controls.Label {
                text: qsTr("Vuoi eseguire l'azione <b>%1</b>?").arg(root.pendingRunActionName)
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
        }

        onAccepted: {
            DesktopBackend.runCustomAction(root.pendingRunActionId)
        }
    }

    // Confirmation dialog for deleting action
    Controls.Dialog {
        id: deleteConfirmDialog
        title: qsTr("Conferma Eliminazione")
        standardButtons: Controls.Dialog.Yes | Controls.Dialog.No
        width: 480
        anchors.centerIn: Controls.Overlay.overlay
        modal: true

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.largeSpacing
            Controls.Label {
                text: qsTr("Sei sicuro di voler eliminare l'azione personale <b>%1</b>?").arg(root.pendingDeleteActionName)
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
        }

        onAccepted: {
            DesktopBackend.removeCustomAction(root.pendingDeleteActionId)
        }
    }

    // Confirmation dialog for resetting default actions
    Controls.Dialog {
        id: resetConfirmDialog
        title: qsTr("Conferma Azzeramento Azioni Personali")
        standardButtons: Controls.Dialog.Yes | Controls.Dialog.No
        width: 480
        anchors.centerIn: Controls.Overlay.overlay
        modal: true

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.largeSpacing
            Controls.Label {
                text: qsTr("Sei sicuro di voler azzerare le azioni personali? Il file corrente verrà archiviato come copia di sicurezza (.corrupt-<timestamp>).")
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
        }

        onAccepted: {
            DesktopBackend.resetCustomActionsToDefault()
        }
    }
}
