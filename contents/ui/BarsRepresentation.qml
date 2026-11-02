import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.core as PlasmaCore

Item {
    id: barsRep

    readonly property bool isVertical: plasmoid.formFactor === PlasmaCore.Types.Vertical
    readonly property int barThickness: Math.max(3, Math.round(
        (isVertical ? barsRep.width : barsRep.height) / 5))
    readonly property var barModel: {
        var bars = root.hasFiveHour ? [{ util: root.fiveHourUtil }] : []
        bars.push({ util: root.sevenDayUtil })
        for (var i = 0; i < root.weeklyModels.length; i++) {
            bars.push({ util: root.weeklyModels[i].util })
        }
        return bars
    }
    readonly property int barCount: barModel.length

    Layout.minimumWidth: isVertical ? Kirigami.Units.gridUnit : barThickness * barCount + (barCount + 1)
    Layout.minimumHeight: isVertical ? barThickness * barCount + (barCount + 1) : Kirigami.Units.gridUnit
    Layout.preferredWidth: Layout.minimumWidth
    Layout.preferredHeight: Layout.minimumHeight

    RowLayout {
        anchors.fill: parent
        anchors.margins: 1
        spacing: 1
        rotation: isVertical ? 90 : 0

        Repeater {
            model: barsRep.barModel

            Rectangle {
                Layout.fillHeight: true
                Layout.preferredWidth: barsRep.barThickness
                radius: width / 2
                color: Kirigami.Theme.backgroundColor
                border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.2)
                border.width: 1

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: parent.height * Math.min(modelData.util / 100, 1.0)
                    radius: parent.radius
                    color: root.usageColor(modelData.util)

                    Behavior on height {
                        NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
                    }
                }
            }
        }
    }
}
