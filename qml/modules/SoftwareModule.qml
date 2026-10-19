import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami
import org.myslowrollos.controlcenter

Kirigami.ScrollablePage {
    id: root
    title: qsTr("Software RPM")

    property bool showRepositories: false

    ColumnLayout {
        width: parent.width
        spacing: UiMetrics.cardSpacing

        // 1. Strumenti Gestione Pacchetti RPM & Flatpak
        Kirigami.Heading {
            level: 2
            text: qsTr("Gestione Pacchetti & Applicazioni")
            font.bold: true
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
                        source: "package-x-generic"
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        Kirigami.Heading { level: 3; text: qsTr("Software Nativo openSUSE & Flatpak"); font.bold: true }
                        Controls.Label {
                            text: qsTr("Lanciatore diretto degli strumenti grafici ufficiali di sistema per RPM e Flatpak.")
                            opacity: UiMetrics.secondaryOpacity
                        }
                    }
                }

                Kirigami.Separator { Layout.fillWidth: true }

                Flow {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    Controls.Button {
                        text: qsTr("YaST Gestione Software (RPM)")
                        icon.name: "yast-sw_single"
                        enabled: DesktopBackend.isToolAvailable("yast")
                        onClicked: DesktopBackend.launchTool("yast-software")
                    }

                    Controls.Button {
                        text: qsTr("KDE Discover (Flatpak)")
                        icon.name: "plasma-discover"
                        enabled: DesktopBackend.isToolAvailable("discover")
                        onClicked: DesktopBackend.launchTool("discover")
                    }

                    Controls.Button {
                        text: qsTr("Pulisci Cache Zypper")
                        icon.name: "edit-clear"
                        enabled: !DesktopBackend.busy && !SlowrollBackend.busy
                        onClicked: zypperCleanConfirmDialog.open()
                    }
                }
            }
        }


        // 2. Ambienti Isolati & Container (Distrobox)
        Kirigami.Heading {
            level: 2
            text: qsTr("Ambienti Isolati & Container (Distrobox)")
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
                        source: "distribute-horizontal-margin"
                    }

                    Kirigami.Heading {
                        level: 3
                        text: qsTr("Container (distrobox)")
                        font.bold: true
                        Layout.fillWidth: true
                    }
                }

                Kirigami.Separator { Layout.fillWidth: true }

                Flow {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    // Nota architetturale: Il pulsante rimane abilitato anche se Kontainer non è installato
                    // per consentire all'utente di avviare il percorso guidato di installazione tramite Discover.
                    Controls.Button {
                        text: DesktopBackend.isToolAvailable("kontainer")
                              ? qsTr("Avvia Kontainer")
                              : qsTr("Installa Kontainer")
                        icon.name: DesktopBackend.isToolAvailable("kontainer")
                                   ? "system-run"
                                   : "get-hot-new-stuff"
                        onClicked: DesktopBackend.launchTool("kontainer")
                    }
                }
            }
        }

        // 3. Repository Configurati (Vista Compatta)
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.smallSpacing

            Kirigami.Heading {
                level: 2
                text: qsTr("Repository Configurati nel Sistema")
                font.bold: true
                Layout.fillWidth: true
            }

            Controls.Label {
                visible: root.showRepositories && SlowrollBackend.repositories.length > 0
                text: qsTr("%1 repository").arg(SlowrollBackend.repositories.length)
                opacity: UiMetrics.secondaryOpacity
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
        }

        Kirigami.AbstractCard {
            Layout.fillWidth: true

            contentItem: ColumnLayout {
                spacing: Kirigami.Units.largeSpacing

                Flow {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    Controls.Button {
                        text: root.showRepositories ? qsTr("Nascondi Repository") : qsTr("Mostra Repository")
                        icon.name: root.showRepositories ? "view-hidden" : "view-visible"
                        onClicked: {
                            root.showRepositories = !root.showRepositories
                            if (root.showRepositories && SlowrollBackend.repositories.length === 0) {
                                SlowrollBackend.refreshRepositories()
                            }
                        }
                    }

                    Controls.Button {
                        text: qsTr("Aggiorna Elenco Repo")
                        icon.name: "view-refresh"
                        visible: root.showRepositories
                        enabled: !DesktopBackend.busy && !SlowrollBackend.busy
                        onClicked: SlowrollBackend.refreshRepositories()
                    }

                    Controls.Button {
                        text: qsTr("YaST Gestione Repository")
                        icon.name: "yast-repositories"
                        enabled: DesktopBackend.isToolAvailable("yast")
                        onClicked: DesktopBackend.launchTool("yast-repos")
                    }
                }

                Controls.Label {
                    visible: !root.showRepositories
                    text: qsTr("L'elenco dei repository è nascosto per ottimizzare le risorse di sistema. Fai clic su 'Mostra Repository' per consultarlo.")
                    opacity: UiMetrics.secondaryOpacity
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                }

                ColumnLayout {
                    visible: root.showRepositories
                    Layout.fillWidth: true
                    spacing: 0

                    Kirigami.Separator { Layout.fillWidth: true; Layout.bottomMargin: Kirigami.Units.smallSpacing }

                    Controls.Label {
                        visible: SlowrollBackend.repositories.length === 0
                        text: qsTr("Caricamento repository in corso...")
                        opacity: UiMetrics.secondaryOpacity
                        Layout.margins: Kirigami.Units.smallSpacing
                    }

                    Repeater {
                        model: SlowrollBackend.repositories
                        delegate: ColumnLayout {
                            required property var modelData
                            required property int index
                            Layout.fillWidth: true
                            spacing: 0

                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 38
                                color: index % 2 === 0 ? "transparent" : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.03)

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: Kirigami.Units.smallSpacing
                                    anchors.rightMargin: Kirigami.Units.smallSpacing
                                    spacing: Kirigami.Units.smallSpacing

                                    Rectangle {
                                        Layout.preferredWidth: 8
                                        Layout.preferredHeight: 8
                                        radius: 4
                                        color: modelData.enabled ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.neutralTextColor
                                    }

                                    Controls.Label {
                                        text: modelData.name
                                        font.bold: true
                                        font.pointSize: Kirigami.Theme.defaultFont.pointSize
                                        Layout.preferredWidth: 220
                                        elide: Text.ElideRight
                                    }

                                    Rectangle {
                                        Layout.preferredWidth: compactBadge.width + 8
                                        Layout.preferredHeight: 16
                                        radius: 3
                                        color: modelData.enabled ? Qt.rgba(Kirigami.Theme.positiveTextColor.r, Kirigami.Theme.positiveTextColor.g, Kirigami.Theme.positiveTextColor.b, 0.15) : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.1)
                                        Controls.Label {
                                            id: compactBadge
                                            anchors.centerIn: parent
                                            text: modelData.enabled ? qsTr("ATTIVO") : qsTr("DISATTIVO")
                                            font.pixelSize: 9
                                            font.bold: true
                                            color: modelData.enabled ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.textColor
                                        }
                                    }

                                    Controls.Label {
                                        text: modelData.url
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                        opacity: UiMetrics.secondaryOpacity
                                        elide: Text.ElideMiddle
                                        Layout.fillWidth: true
                                    }
                                }
                            }

                            Kirigami.Separator {
                                Layout.fillWidth: true
                                visible: index < SlowrollBackend.repositories.length - 1
                            }
                        }
                    }
                }
            }
        }
    }

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
}
