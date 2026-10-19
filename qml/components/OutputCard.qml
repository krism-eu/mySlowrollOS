import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami
import org.myslowrollos.controlcenter

Kirigami.AbstractCard {
    id: root

    property string title: qsTr("Output dell'operazione")
    property alias outputText: outputArea.text
    property bool hasOutput: outputArea.text.trim().length > 0

    signal closeRequested()

    visible: hasOutput

    Layout.fillWidth: true

    contentItem: ColumnLayout {
        spacing: Kirigami.Units.smallSpacing

        RowLayout {
            Layout.fillWidth: true

            Kirigami.Heading {
                level: 3
                font.bold: true
                text: root.title
                Layout.fillWidth: true
                elide: Text.ElideRight
            }

            Controls.Button {
                text: qsTr("Copia")
                icon.name: "edit-copy"
                enabled: root.hasOutput
                onClicked: DesktopBackend.copyToClipboard(root.outputText)
            }

            Controls.Button {
                text: qsTr("Chiudi")
                icon.name: "dialog-close"
                onClicked: {
                    root.closeRequested()
                }
            }
        }

        Controls.ScrollView {
            Layout.fillWidth: true
            Layout.preferredHeight: UiMetrics.outputHeight

            Controls.TextArea {
                id: outputArea
                readOnly: true
                selectByMouse: true
                font: Kirigami.Theme.fixedWidthFont
                wrapMode: Text.WrapAnywhere
            }
        }
    }
}
