pragma Singleton
import QtQuick
import org.kde.kirigami as Kirigami

QtObject {
    id: root
    readonly property int pageMargin: Kirigami.Units.largeSpacing * 2
    readonly property int cardSpacing: Kirigami.Units.largeSpacing
    readonly property int smallSpacing: Kirigami.Units.smallSpacing
    readonly property int outputHeight: 200
    readonly property real secondaryOpacity: 0.72
    readonly property real mutedOpacity: 0.50
}
