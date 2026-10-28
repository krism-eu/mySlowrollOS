import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami
import org.myslowrollos.controlcenter

Kirigami.ScrollablePage {
    id: root
    title: qsTr("Strumenti & Fix")

    ColumnLayout {
        width: parent.width
        spacing: UiMetrics.cardSpacing

        // 1. Manutenzione & Recupero Spazio (Pulizia Assistita del Disco)
        Kirigami.Heading {
            level: 2
            text: qsTr("Manutenzione & Recupero Spazio")
            font.bold: true
        }

        Kirigami.AbstractCard {
            Layout.fillWidth: true

            contentItem: ColumnLayout {
                spacing: Kirigami.Units.largeSpacing

                RowLayout {
                    spacing: Kirigami.Units.largeSpacing
                    Kirigami.Icon { source: "edit-clear-history"; Layout.preferredWidth: 32; Layout.preferredHeight: 32 }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        Kirigami.Heading { level: 3; text: qsTr("Pulizia Assistita del Disco"); font.bold: true }
                        Controls.Label {
                            text: qsTr("Operazioni controllate per eliminare file temporanei e log obsoleti in sicurezza.")
                            opacity: UiMetrics.secondaryOpacity
                        }
                    }
                }

                Kirigami.Separator { Layout.fillWidth: true }

                GridLayout {
                    Layout.fillWidth: true
                    columns: root.width > 700 ? 3 : (root.width > 480 ? 2 : 1)
                    columnSpacing: UiMetrics.cardSpacing
                    rowSpacing: UiMetrics.cardSpacing

                    Controls.Button {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 46
                        text: qsTr("Svuota Cestino Utente")
                        icon.name: "user-trash"
                        enabled: !DesktopBackend.busy && !SlowrollBackend.busy
                        onClicked: trashConfirmDialog.open()
                    }

                    Controls.Button {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 46
                        text: qsTr("Pulisci Journal Vecchi (16M)")
                        icon.name: "document-cleanup"
                        enabled: !DesktopBackend.busy && !SlowrollBackend.busy
                        onClicked: journalConfirmDialog.open()
                    }

                    Controls.Button {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 46
                        text: qsTr("Pulisci Runtime Flatpak")
                        icon.name: "plasma-discover"
                        enabled: !DesktopBackend.busy && !SlowrollBackend.busy
                        onClicked: flatpakConfirmDialog.open()
                    }

                    Controls.Button {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 46
                        text: qsTr("Pulisci Miniature (~/.cache)")
                        icon.name: "edit-clear"
                        enabled: !DesktopBackend.busy && !SlowrollBackend.busy
                        onClicked: thumbnailsConfirmDialog.open()
                    }

                    Controls.Button {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 46
                        text: qsTr("Pulisci Cache Zypper")
                        icon.name: "package-x-generic"
                        enabled: !DesktopBackend.busy && !SlowrollBackend.busy
                        onClicked: zypperCleanConfirmDialog.open()
                    }

                    Controls.Button {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 46
                        text: qsTr("Analizza Spazio (QDirStat)")
                        icon.name: "folder-chart"
                        enabled: DesktopBackend.isToolAvailable("qdirstat")
                        onClicked: DesktopBackend.launchTool("qdirstat")
                    }
                }
            }
        }

        // 2. Riparazioni & Fix del Desktop
        Kirigami.Heading {
            level: 2
            text: qsTr("Riparazioni & Fix del Desktop")
            font.bold: true
            Layout.topMargin: Kirigami.Units.smallSpacing
        }

        Kirigami.AbstractCard {
            Layout.fillWidth: true

            contentItem: ColumnLayout {
                spacing: Kirigami.Units.largeSpacing

                RowLayout {
                    spacing: Kirigami.Units.largeSpacing
                    Kirigami.Icon { source: "tools-wizard"; Layout.preferredWidth: 32; Layout.preferredHeight: 32 }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        Kirigami.Heading { level: 3; text: qsTr("Riparazioni & Fix Rapidi"); font.bold: true }
                        Controls.Label {
                            text: qsTr("Interventi immediati per risolvere blocchi o problemi comuni senza riavviare.")
                            opacity: UiMetrics.secondaryOpacity
                        }
                    }
                }

                Kirigami.Separator { Layout.fillWidth: true }

                GridLayout {
                    Layout.fillWidth: true
                    columns: root.width > 700 ? 2 : 1
                    columnSpacing: UiMetrics.cardSpacing
                    rowSpacing: UiMetrics.cardSpacing

                    // Riparazione Audio
                    Kirigami.AbstractCard {
                        Layout.fillWidth: true
                        contentItem: RowLayout {
                            spacing: Kirigami.Units.largeSpacing
                            Kirigami.Icon { source: "audio-volume-high"; Layout.preferredWidth: 28; Layout.preferredHeight: 28 }
                            ColumnLayout {
                                Layout.fillWidth: true
                                Controls.Label { text: qsTr("Riparazione Stack Audio (PipeWire)"); font.bold: true }
                                Controls.Label {
                                    text: qsTr("Riavvia PipeWire, PipeWire-Pulse e WirePlumber nella sessione utente.")
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    opacity: UiMetrics.secondaryOpacity
                                    wrapMode: Text.WordWrap
                                    Layout.fillWidth: true
                                }
                            }
                            Controls.Button {
                                text: qsTr("Riavvia Audio")
                                icon.name: "view-refresh"
                                enabled: !DesktopBackend.busy && !SlowrollBackend.busy
                                onClicked: DesktopBackend.restartAudio()
                            }
                        }
                    }

                    // Ricostruzione Cache Icone e Font
                    Kirigami.AbstractCard {
                        Layout.fillWidth: true
                        contentItem: RowLayout {
                            spacing: Kirigami.Units.largeSpacing
                            Kirigami.Icon { source: "preferences-desktop-icons"; Layout.preferredWidth: 28; Layout.preferredHeight: 28 }
                            ColumnLayout {
                                Layout.fillWidth: true
                                Controls.Label { text: qsTr("Ricostruisci Cache Desktop & Font"); font.bold: true }
                                Controls.Label {
                                    text: qsTr("Aggiorna la cache dei file desktop (kbuildsycoca6) e la cache dei font.")
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    opacity: UiMetrics.secondaryOpacity
                                    wrapMode: Text.WordWrap
                                    Layout.fillWidth: true
                                }
                            }
                            Controls.Button {
                                text: qsTr("Ricostruisci")
                                icon.name: "view-refresh"
                                enabled: !DesktopBackend.busy && !SlowrollBackend.busy
                                onClicked: DesktopBackend.rebuildDesktopCache()
                            }
                        }
                    }
                }
            }
        }

        // 3. Sviluppo & Controllo Versione (Git)
        Kirigami.Heading {
            level: 2
            text: qsTr("Sviluppo & Controllo Versione (Git)")
            font.bold: true
            Layout.topMargin: Kirigami.Units.smallSpacing
        }

        Kirigami.AbstractCard {
            Layout.fillWidth: true

            contentItem: ColumnLayout {
                spacing: Kirigami.Units.largeSpacing

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    Kirigami.Icon {
                        Layout.preferredWidth: 32
                        Layout.preferredHeight: 32
                        source: "preferences-git"
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        Kirigami.Heading { level: 3; text: qsTr("Configurazione Ambiente Git"); font.bold: true }
                        Controls.Label {
                            text: qsTr("Interfaccia grafica integrata per la configurazione dell'ambiente Git (identità, credenziali, preferenze).")
                            opacity: UiMetrics.secondaryOpacity
                        }
                    }
                }

                Kirigami.Separator { Layout.fillWidth: true }

                Flow {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    Controls.Button {
                        Layout.preferredHeight: 46
                        text: qsTr("Configurazione Git")
                        icon.name: "preferences-git"
                        enabled: DesktopBackend.isToolAvailable("git-config")
                        onClicked: DesktopBackend.launchTool("git-config")
                    }
                }
            }
        }

        // 4. Dispositivi & Debug Hardware (Android ADB)
        Kirigami.Heading {
            level: 2
            text: qsTr("Dispositivi & Debug Hardware (ADB)")
            font.bold: true
            Layout.topMargin: Kirigami.Units.smallSpacing
        }

        Kirigami.AbstractCard {
            Layout.fillWidth: true

            contentItem: ColumnLayout {
                spacing: Kirigami.Units.largeSpacing

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    Kirigami.Icon {
                        Layout.preferredWidth: 32
                        Layout.preferredHeight: 32
                        source: "smartphone"
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        Kirigami.Heading { level: 3; text: qsTr("Gestione Dispositivi Android (ADB)"); font.bold: true }
                        Controls.Label {
                            text: qsTr("Interfaccia grafica avanzata per il rilevamento, debug, gestione app e file per dispositivi Android collegati via USB o Wi-Fi.")
                            opacity: UiMetrics.secondaryOpacity
                        }
                    }
                }

                Kirigami.Separator { Layout.fillWidth: true }

                Flow {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    Controls.Button {
                        Layout.preferredHeight: 46
                        text: qsTr("Gestione Dispositivi Android (ADB)")
                        icon.name: "smartphone"
                        enabled: DesktopBackend.isToolAvailable("android-manager")
                        onClicked: DesktopBackend.launchTool("android-manager")
                    }
                }
            }
        }
    }

    // Confirmation dialog for emptying trash
    Controls.Dialog {
        id: trashConfirmDialog
        title: qsTr("Conferma Svuotamento Cestino")
        standardButtons: Controls.Dialog.Yes | Controls.Dialog.No
        width: 480
        anchors.centerIn: Controls.Overlay.overlay
        modal: true

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.largeSpacing
            Controls.Label {
                text: qsTr("Sei sicuro di voler svuotare il cestino utente? I file eliminati non potranno essere recuperati.")
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
        }

        onAccepted: {
            DesktopBackend.cleanTrash()
        }
    }

    // Confirmation dialog for journal vacuum
    Controls.Dialog {
        id: journalConfirmDialog
        title: qsTr("Conferma Pulizia Journal")
        standardButtons: Controls.Dialog.Yes | Controls.Dialog.No
        width: 480
        anchors.centerIn: Controls.Overlay.overlay
        modal: true

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.largeSpacing
            Controls.Label {
                text: qsTr("Verranno rimossi i registri Journal archiviati più vecchi preservando gli ultimi 16 MB (richiede autenticazione PolKit). Vuoi procedere?")
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
        }

        onAccepted: {
            DesktopBackend.cleanJournal(16)
        }
    }

    // Confirmation dialog for unused Flatpaks
    Controls.Dialog {
        id: flatpakConfirmDialog
        title: qsTr("Conferma Disinstallazione Runtime")
        standardButtons: Controls.Dialog.Yes | Controls.Dialog.No
        width: 480
        anchors.centerIn: Controls.Overlay.overlay
        modal: true

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.largeSpacing
            Controls.Label {
                text: qsTr("Verranno rimossi tutti i runtime e le librerie Flatpak non più utilizzati dalle applicazioni installate. Vuoi procedere?")
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
        }

        onAccepted: {
            DesktopBackend.cleanFlatpakUnused()
        }
    }

    // Confirmation dialog for Zypper cache clean
    Controls.Dialog {
        id: zypperCleanConfirmDialog
        title: qsTr("Conferma Pulizia Cache Zypper")
        standardButtons: Controls.Dialog.Yes | Controls.Dialog.No
        width: 440
        anchors.centerIn: Controls.Overlay.overlay
        modal: true

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.largeSpacing
            Controls.Label {
                text: qsTr("Sei sicuro di voler ripulire completamente la cache dei pacchetti Zypper?")
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
            Controls.Label {
                text: qsTr("L'operazione richiede privilegi di amministrazione (pkexec). I metadati dei repository verranno riscaricati al prossimo aggiornamento.")
                opacity: UiMetrics.secondaryOpacity
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
        }

        onAccepted: DesktopBackend.cleanZypperCache()
    }

    // Confirmation dialog for thumbnail cache clean
    Controls.Dialog {
        id: thumbnailsConfirmDialog
        title: qsTr("Conferma Pulizia Miniature")
        standardButtons: Controls.Dialog.Yes | Controls.Dialog.No
        width: 440
        anchors.centerIn: Controls.Overlay.overlay
        modal: true

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.largeSpacing
            Controls.Label {
                text: qsTr("Vuoi davvero eliminare la cache delle miniature (~/.cache/thumbnails)?<br><br>Le miniature verranno ricreate automaticamente quando visualizzerai nuovamente i file multimediali.")
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
        }

        onAccepted: DesktopBackend.cleanThumbnailCache()
    }
}
