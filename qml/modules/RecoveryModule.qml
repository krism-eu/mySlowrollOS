import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami
import org.myslowrollos.controlcenter

Kirigami.ScrollablePage {
    id: root
    title: qsTr("Backup & Recovery")

    StackLayout.onIsCurrentItemChanged: {
        if (root.StackLayout.isCurrentItem) {
            SlowrollBackend.refreshAtomicState()
        }
    }

    Component.onCompleted: {
        SlowrollBackend.refreshAtomicState()
    }

    ColumnLayout {
        width: parent.width
        spacing: UiMetrics.cardSpacing

        // 1. Backup Dati Personali (Back In Time) - In Primo Piano
        Kirigami.Heading {
            level: 2
            text: qsTr("Backup File Personali")
            font.bold: true
        }

        Kirigami.AbstractCard {
            Layout.fillWidth: true

            contentItem: RowLayout {
                spacing: Kirigami.Units.largeSpacing

                Kirigami.Icon {
                    source: "document-save"
                    Layout.preferredWidth: 32
                    Layout.preferredHeight: 32
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Controls.Label { text: qsTr("Applicazione di Backup Dedicata (Back In Time)"); font.bold: true }
                    Controls.Label {
                        text: qsTr("Proteggi la tua cartella /home e i documenti personali con snapshot incrementali sicuri su supporti esterni.")
                        opacity: UiMetrics.secondaryOpacity
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }
                }

                Controls.Button {
                    text: qsTr("Apri Back In Time")
                    icon.name: "document-save"
                    enabled: DesktopBackend.isToolAvailable("backintime")
                    onClicked: DesktopBackend.launchTool("backintime")
                }
            }
        }

        // 2. Snapshot Btrfs del Sistema (Snapper) - Collegamento al Gestore di Sistema
        Kirigami.Heading {
            level: 2
            text: qsTr("Snapshot Btrfs del Sistema (Snapper)")
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
                        Layout.preferredWidth: 36
                        Layout.preferredHeight: 36
                        source: "document-save-all"
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        Kirigami.Heading { level: 3; text: qsTr("Gestore Snapshot Btrfs"); font.bold: true }
                        Controls.Label {
                            text: qsTr("Il sistema operativo gestisce gli snapshot transazionali root in modo automatico. La consultazione, il confronto (diff) e il rollback sono gestiti direttamente dallo strumento ufficiale YaST Snapper.")
                            opacity: UiMetrics.secondaryOpacity
                            wrapMode: Text.WordWrap
                            Layout.fillWidth: true
                        }
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
                        Controls.Label { text: qsTr("Snapshot Attivo (In Uso):"); font.bold: true; opacity: UiMetrics.secondaryOpacity }
                        Controls.Label {
                            text: SlowrollBackend.activeSnapshot > 0 ? "#" + SlowrollBackend.activeSnapshot : qsTr("Nominale")
                            font.bold: true
                        }
                    }

                    ColumnLayout {
                        spacing: 2
                        Controls.Label { text: qsTr("Snapshot Predefinito (Boot):"); font.bold: true; opacity: UiMetrics.secondaryOpacity }
                        Controls.Label {
                            text: SlowrollBackend.defaultSnapshot > 0 ? "#" + SlowrollBackend.defaultSnapshot : qsTr("Nominale")
                            font.bold: true
                            color: SlowrollBackend.pendingReboot ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.textColor
                        }
                    }

                    ColumnLayout {
                        spacing: 2
                        Controls.Label { text: qsTr("Stato Transazione:"); font.bold: true; opacity: UiMetrics.secondaryOpacity }
                        Controls.Label {
                            text: SlowrollBackend.atomicStatus.toUpperCase()
                            font.bold: true
                            color: SlowrollBackend.pendingReboot ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.textColor
                        }
                    }
                }

                Kirigami.Separator { Layout.fillWidth: true }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    Controls.Button {
                        text: qsTr("Apri Gestore Snapshot (YaST Snapper)")
                        icon.name: "yast-snapper"
                        enabled: DesktopBackend.isToolAvailable("yast")
                        onClicked: DesktopBackend.launchYastModule("snapper")
                    }

                    Item { Layout.fillWidth: true }

                    Controls.Button {
                        text: qsTr("Aggiorna Stato")
                        icon.name: "view-refresh"
                        enabled: !DesktopBackend.busy && !SlowrollBackend.busy
                        onClicked: SlowrollBackend.refreshAtomicState()
                    }
                }
            }
        }
    }
}
