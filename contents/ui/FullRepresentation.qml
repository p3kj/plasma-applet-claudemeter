import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2

import org.kde.kirigami as Kirigami

// Root is a plain Item, not a Layout, to avoid KDE bug 489365:
// plasmashell crashes in QQuickLayout::effectiveSizePolicy_helper when the
// popup is first expanded if the fullRepresentation root is a QQuickLayout.
Item {
    id: fullRep

    Layout.minimumWidth: Kirigami.Units.gridUnit * 14
    Layout.preferredWidth: Kirigami.Units.gridUnit * 16
    Layout.minimumHeight: content.implicitHeight
    Layout.preferredHeight: content.implicitHeight
    implicitWidth: Kirigami.Units.gridUnit * 16
    implicitHeight: content.implicitHeight

    ColumnLayout {
        id: content
        anchors.fill: parent
        spacing: Kirigami.Units.smallSpacing

    // Header
    RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: Kirigami.Units.smallSpacing
        Layout.rightMargin: Kirigami.Units.smallSpacing
        Layout.topMargin: Kirigami.Units.smallSpacing
        Kirigami.Heading {
            text: "Claude Code Usage"
            level: 4
            Layout.fillWidth: true
        }
        QQC2.ToolButton {
            icon.name: "view-refresh"
            onClicked: root.requestFetch("manual")
            QQC2.ToolTip.text: "Refresh"
            QQC2.ToolTip.visible: hovered
            enabled: !root.loading
            implicitHeight: Kirigami.Units.gridUnit * 1.5
            implicitWidth: Kirigami.Units.gridUnit * 1.5
        }
    }

    // Error display
    QQC2.Label {
        Layout.fillWidth: true
        Layout.leftMargin: Kirigami.Units.smallSpacing
        Layout.rightMargin: Kirigami.Units.smallSpacing
        visible: root.hasError
        text: root.errorMessage
        color: Kirigami.Theme.negativeTextColor
        wrapMode: Text.Wrap
    }

    // Loading indicator
    QQC2.BusyIndicator {
        Layout.alignment: Qt.AlignHCenter
        visible: root.loading && !root.hasError
        running: visible
    }

    // Usage bars
    ColumnLayout {
        Layout.fillWidth: true
        Layout.leftMargin: Kirigami.Units.smallSpacing
        Layout.rightMargin: Kirigami.Units.smallSpacing
        visible: !root.loading || !root.hasError
        spacing: Kirigami.Units.smallSpacing

        UsageBar {
            Layout.fillWidth: true
            label: "5-Hour Window"
            percentage: root.fiveHourUtil
            barColor: root.usageColor(root.fiveHourUtil)
            resetTime: root.formatResetTime(root.fiveHourResets)
            segments: 5
            pace: root.paceFraction(root.fiveHourResets, root.sessionWindowMs)
        }

        UsageBar {
            Layout.fillWidth: true
            label: "Weekly (All Models)"
            percentage: root.sevenDayUtil
            barColor: root.usageColor(root.sevenDayUtil)
            resetTime: root.formatResetTime(root.sevenDayResets)
            segments: 7
            pace: root.paceFraction(root.sevenDayResets, root.weeklyWindowMs)
        }

        Repeater {
            model: root.weeklyModels
            UsageBar {
                Layout.fillWidth: true
                label: modelData.label
                percentage: modelData.util
                barColor: root.usageColor(modelData.util)
                resetTime: root.formatResetTime(modelData.resets)
                segments: 7
                pace: root.paceFraction(modelData.resets, root.weeklyWindowMs)
            }
        }
    }

    // Extra usage
    ColumnLayout {
        Layout.fillWidth: true
        Layout.leftMargin: Kirigami.Units.smallSpacing
        Layout.rightMargin: Kirigami.Units.smallSpacing
        visible: root.hasExtraUsage
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Separator { Layout.fillWidth: true }

        RowLayout {
            Layout.fillWidth: true
            QQC2.Label {
                text: "Extra Usage Limit"
                font: Kirigami.Theme.smallFont
                Layout.fillWidth: true
            }
            QQC2.Label {
                text: root.extraUsageEnabled ? "Enabled" : "Disabled"
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                color: root.extraUsageEnabled ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.disabledTextColor
            }
        }

        QQC2.Label {
            visible: root.extraUsageEnabled
            text: root.extraUsageUsed + (root.extraUsageLimit ? " / " + root.extraUsageLimit : "")
            font.bold: true
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            color: Kirigami.Theme.activeTextColor
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Kirigami.Units.smallSpacing * 3
            radius: height / 2
            color: Kirigami.Theme.backgroundColor
            border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.2)
            border.width: 1
            visible: root.extraUsageUtil > 0

            Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: parent.width * Math.min(root.extraUsageUtil / 100, 1.0)
                radius: parent.radius
                color: Kirigami.Theme.activeTextColor

                Behavior on width {
                    NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
                }
            }
        }
    }

    // Footer
    QQC2.Label {
        Layout.fillWidth: true
        Layout.rightMargin: Kirigami.Units.smallSpacing
        Layout.bottomMargin: Kirigami.Units.smallSpacing
        text: (root.dataCached ? "Cached " : "Updated ") + Qt.formatTime(root.lastUpdated, "hh:mm:ss")
        font: Kirigami.Theme.smallFont
        color: Kirigami.Theme.disabledTextColor
        horizontalAlignment: Text.AlignRight
    }
    }
}
