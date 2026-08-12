import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.quickcharts as Charts

Item {
    id: gaugeRep

    readonly property real utilization: root.compactUtil
    readonly property string resetsAt: root.compactResets
    readonly property color arcColor: root.compactColor
    readonly property bool isDark: Kirigami.Theme.backgroundColor.hslLightness < 0.5
    readonly property color trackColor: isDark ? "#33373B" : "#E5E7E8"
    readonly property real ringThickness: Kirigami.Units.smallSpacing * 1.1
    // Hairline gap: just enough to separate the two arcs, so the inner one stays
    // close to the outer and leaves the centre free for the label.
    readonly property real innerInset: ringThickness + Math.max(1, Math.round(ringThickness * 0.25))
    // Below a handful of ring widths of diameter the second arc just smears into
    // the first, so a thin panel gets the outer ring alone.
    readonly property bool showInner: root.hasInnerRing
        && Math.min(width, height) >= ringThickness * 6

    Layout.minimumWidth: Kirigami.Units.gridUnit
    Layout.minimumHeight: Kirigami.Units.gridUnit
    Layout.preferredWidth: height
    Layout.preferredHeight: height

    // Background track — always visible
    Charts.PieChart {
        anchors.fill: parent
        fromAngle: -180
        toAngle: 180
        smoothEnds: true
        thickness: gaugeRep.ringThickness
        range { from: 0; to: 100; automatic: false }
        valueSources: Charts.SingleValueSource { value: 100 }
        colorSource: Charts.SingleValueSource { value: gaugeRep.trackColor }
    }

    // Foreground usage arc
    Charts.PieChart {
        id: pie
        anchors.fill: parent

        fromAngle: -180
        toAngle: 180
        smoothEnds: true
        thickness: gaugeRep.ringThickness

        range {
            from: 0
            to: 100
            automatic: false
        }

        valueSources: Charts.SingleValueSource {
            value: gaugeRep.utilization
        }
        colorSource: Charts.SingleValueSource {
            value: gaugeRep.arcColor
        }
    }

    // Inner track for the secondary metric, drawn thinner so the outer ring
    // stays the one the eye lands on.
    Charts.PieChart {
        anchors.fill: parent
        anchors.margins: gaugeRep.innerInset
        visible: gaugeRep.showInner
        fromAngle: -180
        toAngle: 180
        smoothEnds: true
        thickness: Math.max(2, gaugeRep.ringThickness * 0.8)
        range { from: 0; to: 100; automatic: false }
        valueSources: Charts.SingleValueSource { value: 100 }
        colorSource: Charts.SingleValueSource { value: gaugeRep.trackColor }
    }

    // Inner usage arc
    Charts.PieChart {
        anchors.fill: parent
        anchors.margins: gaugeRep.innerInset
        visible: gaugeRep.showInner
        fromAngle: -180
        toAngle: 180
        smoothEnds: true
        thickness: Math.max(2, gaugeRep.ringThickness * 0.8)
        range { from: 0; to: 100; automatic: false }
        valueSources: Charts.SingleValueSource { value: root.innerUtil }
        colorSource: Charts.SingleValueSource { value: root.innerColor }
    }

    Text {
        anchors.centerIn: parent
        visible: plasmoid.configuration.gaugeLabel !== "none"
        text: {
            var mode = plasmoid.configuration.gaugeLabel
            if (mode === "percent") return Math.round(gaugeRep.utilization) + "%"
            return root.formatResetTime(gaugeRep.resetsAt)
        }
        color: Kirigami.Theme.textColor
        font.pixelSize: Math.max(7, Math.min(parent.width, parent.height) * 0.22)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
}
