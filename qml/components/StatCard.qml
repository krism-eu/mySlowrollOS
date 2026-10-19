import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami

Kirigami.AbstractCard {
    id: root

    property string iconName: "help-about"
    property string title: ""
    property string value: ""
    property string detail: ""
    property color iconColor: Kirigami.Theme.highlightColor

    Layout.fillWidth: true
    Layout.minimumHeight: 90

    contentItem: RowLayout {
        spacing: Kirigami.Units.largeSpacing

        Rectangle {
            Layout.preferredWidth: 44
            Layout.preferredHeight: 44
            radius: 8
            color: Qt.rgba(root.iconColor.r, root.iconColor.g, root.iconColor.b, 0.12)

            Kirigami.Icon {
                anchors.centerIn: parent
                width: 24
                height: 24
                source: root.iconName
                color: root.iconColor
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            Controls.Label {
                text: root.title
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                opacity: 0.75
            }

            Controls.Label {
                text: root.value
                font.bold: true
                font.pointSize: Kirigami.Theme.defaultFont.pointSize + 3
            }

            Controls.Label {
                text: root.detail
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                opacity: 0.80
                visible: root.detail.length > 0
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
        }
    }
}
