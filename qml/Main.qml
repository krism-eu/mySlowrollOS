import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami
import org.myslowrollos.controlcenter

Kirigami.ApplicationWindow {
    id: root
    width: 1280
    height: 820
    minimumWidth: 920
    minimumHeight: 640
    visible: true
    title: qsTr("MSCC · mySlowrollOS Control Center")

    property int currentSection: 0
    property string activeNotification: ""

    Connections {
        target: DesktopBackend
        function onStateChanged() {
            if (DesktopBackend.lastMessage.length > 0)
                root.activeNotification = DesktopBackend.lastMessage
        }
    }

    Connections {
        target: SlowrollBackend
        function onLastMessageChanged() {
            if (SlowrollBackend.lastMessage.length > 0)
                root.activeNotification = SlowrollBackend.lastMessage
        }
    }

    readonly property var navigationModel: [
        { section: 0, label: qsTr("Dashboard"), icon: "go-home" },
        { section: 1, label: qsTr("Software RPM"), icon: "package-x-generic" },
        { section: 2, label: qsTr("Servizi & Rete"), icon: "network-connect" },
        { section: 3, label: qsTr("Sistema & Boot"), icon: "computer" },
        { section: 4, label: qsTr("Backup & Recovery"), icon: "document-save-all" },
        { section: 5, label: qsTr("Comandi"), icon: "utilities-terminal" },
        { section: 6, label: qsTr("Strumenti & Fix"), icon: "tools-wizard" }
    ]

    pageStack.globalToolBar.style: Kirigami.ApplicationHeaderStyle.None

    function sectionTitle(index) {
        for (let i = 0; i < root.navigationModel.length; ++i) {
            if (root.navigationModel[i].section === index)
                return root.navigationModel[i].label
        }
        return qsTr("Control Center")
    }

    pageStack.initialPage: Kirigami.Page {
        padding: 0

        background: Rectangle {
            color: Kirigami.Theme.backgroundColor
        }

        RowLayout {
            anchors.fill: parent
            spacing: 0

            // 1. Barra Verticale Sinistra (Sidebar)
            Rectangle {
                id: sidebar
                Layout.preferredWidth: root.width < 1080 ? 210 : 236
                Layout.fillHeight: true
                color: Kirigami.Theme.alternateBackgroundColor

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.largeSpacing
                    spacing: Kirigami.Units.smallSpacing

                    // Header del Brand
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.bottomMargin: Kirigami.Units.largeSpacing
                        spacing: Kirigami.Units.smallSpacing

                        Kirigami.Icon {
                            Layout.preferredWidth: 38
                            Layout.preferredHeight: 38
                            source: "distributor-logo-opensuse"
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Controls.Label {
                                text: qsTr("MSCC")
                                font.bold: true
                                font.pointSize: Kirigami.Theme.defaultFont.pointSize + 2
                            }
                            Controls.Label {
                                Layout.fillWidth: true
                                text: qsTr("mySlowrollOS · openSUSE")
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                opacity: UiMetrics.secondaryOpacity
                                elide: Text.ElideRight
                            }
                        }
                    }

                    // Voci di Navigazione Principali
                    Repeater {
                        model: root.navigationModel
                        delegate: Controls.ItemDelegate {
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.preferredHeight: 44
                            checkable: false
                            highlighted: root.currentSection === modelData.section
                            hoverEnabled: true
                            leftPadding: Kirigami.Units.largeSpacing
                            rightPadding: Kirigami.Units.largeSpacing
                            onClicked: root.currentSection = modelData.section

                            contentItem: RowLayout {
                                spacing: Kirigami.Units.largeSpacing
                                Kirigami.Icon {
                                    Layout.preferredWidth: 22
                                    Layout.preferredHeight: 22
                                    source: modelData.icon
                                    color: parent.parent.highlighted ? Kirigami.Theme.highlightColor : Kirigami.Theme.textColor
                                }
                                Controls.Label {
                                    Layout.fillWidth: true
                                    text: modelData.label
                                    font.bold: parent.parent.highlighted
                                    font.pointSize: Kirigami.Theme.defaultFont.pointSize + 1
                                    color: parent.parent.highlighted ? Kirigami.Theme.highlightColor : Kirigami.Theme.textColor
                                    elide: Text.ElideRight
                                }
                            }

                            background: Rectangle {
                                radius: 8
                                color: parent.highlighted
                                     ? Qt.rgba(Kirigami.Theme.highlightColor.r,
                                               Kirigami.Theme.highlightColor.g,
                                               Kirigami.Theme.highlightColor.b, 0.12)
                                     : parent.hovered
                                       ? Qt.rgba(Kirigami.Theme.textColor.r,
                                                 Kirigami.Theme.textColor.g,
                                                 Kirigami.Theme.textColor.b, 0.05)
                                       : "transparent"

                                Rectangle {
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 3
                                    height: parent.height - 12
                                    radius: 2
                                    visible: parent.parent.highlighted
                                    color: Kirigami.Theme.highlightColor
                                }
                            }
                        }
                    }

                    Item { Layout.fillHeight: true }

                    // Voci Ripristinate sulla Barra Verticale Sinistra
                    Kirigami.Separator { Layout.fillWidth: true }

                    Controls.ItemDelegate {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 40
                        text: qsTr("Terminale")
                        icon.name: "utilities-terminal"
                        enabled: DesktopBackend.isToolAvailable("konsole")
                        onClicked: DesktopBackend.launchTool("konsole")
                    }

                    Controls.ItemDelegate {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 40
                        text: qsTr("Info Center")
                        icon.name: "hwinfo"
                        enabled: DesktopBackend.isToolAvailable("kinfocenter")
                        onClicked: DesktopBackend.launchTool("kinfocenter")
                    }

                    Controls.ItemDelegate {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 40
                        text: qsTr("Impostazioni Plasma")
                        icon.name: "settings-configure"
                        enabled: DesktopBackend.isToolAvailable("settings")
                        onClicked: DesktopBackend.launchTool("settings")
                    }

                    Controls.ItemDelegate {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 40
                        text: qsTr("Centro YaST")
                        icon.name: "yast-control-center"
                        enabled: DesktopBackend.isToolAvailable("yast")
                        onClicked: DesktopBackend.launchTool("yast")
                    }

                    Controls.ItemDelegate {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 40
                        text: qsTr("Informazioni")
                        icon.name: "help-about"
                        onClicked: aboutDialog.open()
                    }
                }
            }

            // Divisore Verticale
            Rectangle {
                Layout.preferredWidth: 1
                Layout.fillHeight: true
                color: Qt.rgba(Kirigami.Theme.textColor.r,
                               Kirigami.Theme.textColor.g,
                               Kirigami.Theme.textColor.b, 0.10)
            }

            // 2. Area di Contenuto Centrale
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                // Barra Intestazione Superiore (Header Bar)
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 56
                    color: Kirigami.Theme.backgroundColor

                    Controls.Label {
                        anchors.left: parent.left
                        anchors.leftMargin: UiMetrics.pageMargin
                        anchors.right: versionLabel.left
                        anchors.rightMargin: Kirigami.Units.largeSpacing
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.sectionTitle(root.currentSection)
                        font.bold: true
                        font.pointSize: Kirigami.Theme.defaultFont.pointSize + 3
                        elide: Text.ElideRight
                    }

                    Controls.Label {
                        id: versionLabel
                        anchors.right: parent.right
                        anchors.rightMargin: UiMetrics.pageMargin
                        anchors.verticalCenter: parent.verticalCenter
                        horizontalAlignment: Text.AlignRight
                        text: "v" + DesktopBackend.appVersion
                        opacity: UiMetrics.secondaryOpacity
                    }

                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 1
                        color: Qt.rgba(Kirigami.Theme.textColor.r,
                                       Kirigami.Theme.textColor.g,
                                       Kirigami.Theme.textColor.b, 0.10)
                    }
                }

                // StackLayout con le 7 Pagine del Centro di Controllo
                StackLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    currentIndex: root.currentSection

                    DashboardModule {
                        onOpenSectionRequested: function(sectionIdx, subTabIdx) {
                            root.currentSection = sectionIdx
                            if (sectionIdx === 2 && subTabIdx !== undefined) {
                                servicesNetworkModule.currentSubTab = subTabIdx
                            }
                        }
                    }

                    SoftwareModule {}

                    ServicesNetworkModule {
                        id: servicesNetworkModule
                    }

                    SystemModule {}

                    RecoveryModule {}

                    CommandsModule {}

                    ToolsModule {}
                }

                // Barra di Notifica Globale (L'ultimo messaggio vince)
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: (root.activeNotification.length > 0 || DesktopBackend.busy || SlowrollBackend.busy) ? 44 : 0
                    visible: Layout.preferredHeight > 0
                    color: Kirigami.Theme.alternateBackgroundColor

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: UiMetrics.pageMargin
                        anchors.rightMargin: UiMetrics.pageMargin
                        spacing: Kirigami.Units.largeSpacing

                        Controls.BusyIndicator {
                            Layout.preferredWidth: 20
                            Layout.preferredHeight: 20
                            running: DesktopBackend.busy || SlowrollBackend.busy
                            visible: running
                        }

                        Kirigami.Icon {
                            Layout.preferredWidth: 20
                            Layout.preferredHeight: 20
                            source: "dialog-information"
                            visible: !DesktopBackend.busy && !SlowrollBackend.busy
                        }

                        Controls.Label {
                            Layout.fillWidth: true
                            text: root.activeNotification.length > 0
                                ? root.activeNotification
                                : qsTr("Operazione in corso...")
                            font.bold: true
                            elide: Text.ElideRight
                        }

                        Controls.Button {
                            text: qsTr("Annulla")
                            icon.name: "process-stop"
                            visible: (DesktopBackend.busy && DesktopBackend.isOperationCancellable) || (SlowrollBackend.busy && SlowrollBackend.isOperationCancellable)
                            onClicked: {
                                if (DesktopBackend.busy) DesktopBackend.cancelCurrentOperation()
                                if (SlowrollBackend.busy) SlowrollBackend.cancelCurrentOperation()
                            }
                        }

                        Controls.Button {
                            flat: true
                            icon.name: "dialog-close"
                            onClicked: {
                                root.activeNotification = ""
                                DesktopBackend.clearMessage()
                                SlowrollBackend.clearMessage()
                            }
                        }
                    }
                }
            }
        }
    }

    // About Dialog
    Controls.Dialog {
        id: aboutDialog
        title: qsTr("Informazioni su mySlowrollOS Control Center")
        standardButtons: Controls.Dialog.Close
        anchors.centerIn: Controls.Overlay.overlay
        width: 480
        modal: true

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.largeSpacing

            RowLayout {
                spacing: Kirigami.Units.largeSpacing
                Kirigami.Icon {
                    source: "distributor-logo-opensuse"
                    Layout.preferredWidth: 48
                    Layout.preferredHeight: 48
                }
                ColumnLayout {
                    Controls.Label {
                        text: qsTr("mySlowrollOS Control Center")
                        font.bold: true
                        font.pointSize: Kirigami.Theme.defaultFont.pointSize + 2
                    }
                    Controls.Label {
                        text: qsTr("Versione %1 · openSUSE Slowroll").arg(DesktopBackend.appVersion)
                        opacity: UiMetrics.secondaryOpacity
                    }
                }
            }

            Kirigami.Separator { Layout.fillWidth: true }

            Controls.Label {
                text: qsTr("Centro di controllo operativo per la gestione delle risorse hardware, aggiornamenti atomici del sistema, ripristino snapshot Btrfs/Snapper, comandi diagnostici, pulizia assistita e integrazione nativa con YaST.")
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }

            Controls.Label {
                text: qsTr("Sviluppato per mySlowrollOS.")
                opacity: UiMetrics.secondaryOpacity
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
        }
    }
}
