import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2

import org.kde.kirigami as Kirigami

MouseArea {
    id: compactRep

    readonly property string accountLabel: plasmoid.configuration.accountLabel.trim()
    readonly property bool showLabel: accountLabel !== "" && plasmoid.formFactor !== 3
    readonly property real labelWidth: showLabel ? labelText.implicitWidth + Kirigami.Units.smallSpacing : 0

    Layout.minimumWidth: (styleLoader.item ? styleLoader.item.Layout.minimumWidth : Kirigami.Units.gridUnit) + labelWidth
    Layout.minimumHeight: styleLoader.item ? styleLoader.item.Layout.minimumHeight : Kirigami.Units.gridUnit
    Layout.preferredWidth: (styleLoader.item ? styleLoader.item.Layout.preferredWidth : Kirigami.Units.gridUnit) + labelWidth
    Layout.preferredHeight: styleLoader.item ? styleLoader.item.Layout.preferredHeight : Layout.minimumHeight

    onClicked: root.expanded = !root.expanded

    hoverEnabled: true
    QQC2.ToolTip {
        id: tooltip
        text: {
            var prefix = compactRep.accountLabel ? compactRep.accountLabel + " - " : ""
            if (root.hasError) return prefix + root.errorMessage
            var parts = [
                "5h: " + Math.round(root.fiveHourUtil) + "%",
                "7d: " + Math.round(root.sevenDayUtil) + "%"
            ]
            for (var i = 0; i < root.weeklyModels.length; i++) {
                var m = root.weeklyModels[i]
                var name = m.name || m.label.replace(/^Weekly \(|\)$/g, "")
                parts.push(name + ": " + Math.round(m.util) + "%")
            }
            return prefix + parts.join(" | ")
        }
        visible: compactRep.containsMouse
    }

    QQC2.Label {
        id: labelText
        visible: compactRep.showLabel
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: compactRep.accountLabel
        font.pixelSize: Math.round(parent.height * 0.32)
        opacity: 0.6
        color: Kirigami.Theme.textColor
    }

    Loader {
        id: styleLoader
        anchors.left: compactRep.showLabel ? labelText.right : parent.left
        anchors.leftMargin: compactRep.showLabel ? Kirigami.Units.smallSpacing : 0
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        source: plasmoid.configuration.compactStyle === "gauge"
            ? "GaugeRepresentation.qml"
            : "BarsRepresentation.qml"
    }

    Kirigami.Icon {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        width: Kirigami.Units.iconSizes.small
        height: width
        source: "data-warning"
        visible: root.hasError
        color: Kirigami.Theme.negativeTextColor
    }
}
