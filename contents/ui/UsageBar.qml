import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2

import org.kde.kirigami as Kirigami

ColumnLayout {
    id: usageBar

    property string label: ""
    property real percentage: 0
    property color barColor: Kirigami.Theme.positiveTextColor
    property string resetTime: ""
    property int segments: 0   // 0 or 1 = no segmentation
    property real pace: -1     // 0..1 elapsed fraction, -1 = unknown

    readonly property real fill: Math.min(usageBar.percentage / 100, 1.0)
    readonly property bool showPace: plasmoid.configuration.showPace
        && usageBar.pace >= 0 && usageBar.segments > 1
    readonly property bool overPace: usageBar.showPace && usageBar.fill > usageBar.pace
    // Only the ahead case gets a label; 2 points of slack keeps it from flickering
    // on and off as usage creeps across the marker.
    readonly property bool aheadOfPace: usageBar.overPace && (usageBar.fill - usageBar.pace) * 100 > 2
    // Stepped up to critical once the bar itself is warning-coloured, or the split
    // would be yellow-on-yellow and invisible above the warning threshold.
    readonly property color overPaceColor: usageBar.percentage >= plasmoid.configuration.warningThreshold
        ? Kirigami.Theme.negativeTextColor
        : (plasmoid.configuration.warningColor || "#E5C07B")
    // Opaque, so it reads the same over the track and over a coloured fill; same
    // 0.2-alpha-of-textColor recipe as the track border.
    readonly property color guideColor: Qt.tint(Kirigami.Theme.backgroundColor,
        Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.22))
    // The segment the marker falls in. Tinted whole, wherever inside it the marker sits.
    readonly property int currentSegment: Math.max(0,
        Math.min(usageBar.segments - 1, Math.floor(usageBar.pace * usageBar.segments)))

    spacing: Kirigami.Units.smallSpacing

    RowLayout {
        Layout.fillWidth: true
        QQC2.Label {
            text: usageBar.label
            font: Kirigami.Theme.smallFont
            elide: Text.ElideRight
            Layout.fillWidth: true
        }
        QQC2.Label {
            text: Math.round(usageBar.percentage) + "%"
            font.bold: true
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            color: usageBar.barColor
        }
    }

    // Progress bar
    Rectangle {
        id: track
        Layout.fillWidth: true
        Layout.preferredHeight: Kirigami.Units.smallSpacing * 3
        radius: height / 2
        color: Kirigami.Theme.backgroundColor
        border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.2)
        border.width: 1

        // Current-segment tint, behind the fills.
        Rectangle {
            // Kept inside the rounded caps, which only bites on the first and last
            // segment: every segment is far wider than the radius.
            readonly property real fromX: Math.max(parent.radius, usageBar.currentSegment / usageBar.segments * parent.width)
            readonly property real toX: Math.min(parent.width - parent.radius, (usageBar.currentSegment + 1) / usageBar.segments * parent.width)

            visible: usageBar.showPace
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            x: fromX
            width: Math.max(0, toX - fromX)
            color: usageBar.guideColor
        }

        // Usage that has run past the caret. Drawn at full usage width so it
        // supplies the rounded right cap; the base fill covers everything up
        // to the caret.
        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: parent.width * usageBar.fill
            radius: parent.radius
            color: usageBar.overPaceColor
            visible: usageBar.overPace

            Behavior on width {
                NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
            }
        }

        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: parent.width * (usageBar.overPace ? usageBar.pace : usageBar.fill)
            radius: parent.radius
            color: usageBar.barColor

            Behavior on width {
                NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
            }
        }

        // Segment dividers, over the fills: replacing fill pixels is what makes
        // the fill itself look segmented.
        Repeater {
            model: usageBar.showPace ? usageBar.segments - 1 : 0
            Rectangle {
                x: (index + 1) / usageBar.segments * track.width
                y: 0
                width: 1
                height: track.height
                color: usageBar.guideColor
            }
        }

        // Now marker. Centred on the pace position, so it also hides the seam
        // between the two fills.
        Rectangle {
            visible: usageBar.showPace
            width: 2
            height: parent.height + 2 * Math.max(2, Math.round(parent.height / 3))
            anchors.verticalCenter: parent.verticalCenter
            x: Math.max(0, Math.min(parent.width - width, usageBar.pace * parent.width - width / 2))
            // Theme colour, not the reference's hardcoded white, which would
            // vanish on a light theme.
            color: Kirigami.Theme.textColor
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing
        visible: usageBar.aheadOfPace || usageBar.resetTime !== ""

        QQC2.Label {
            text: "Ahead of pace"
            visible: usageBar.aheadOfPace
            font: Kirigami.Theme.smallFont
            // Same colour as the band, so text and bar always agree.
            color: usageBar.overPaceColor
            Layout.fillWidth: true
        }

        QQC2.Label {
            text: usageBar.resetTime ? "Resets in " + usageBar.resetTime : ""
            visible: text !== ""
            font: Kirigami.Theme.smallFont
            color: Kirigami.Theme.disabledTextColor
            Layout.fillWidth: true
            // Keyed on showPace, not on the verdict: otherwise the reset text
            // would jump sides every time usage crossed the pace line.
            horizontalAlignment: usageBar.showPace ? Text.AlignRight : Text.AlignLeft
        }
    }
}
