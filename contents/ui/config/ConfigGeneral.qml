import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import org.kde.kquickcontrols as KQC

KCM.SimpleKCM {
    id: configGeneral

    // Migrate legacy value: seven_day_sonnet is no longer an active API limit.
    Component.onCompleted: {
        if (cfg_compactMetric === "seven_day_sonnet") {
            cfg_compactMetric = "model_weekly"
        }
    }

    property alias cfg_pollInterval: pollIntervalSpinBox.value
    property alias cfg_activityCheckInterval: activityCheckSpinBox.value
    property alias cfg_warningThreshold: warningSpinBox.value
    property alias cfg_criticalThreshold: criticalSpinBox.value
    property string cfg_compactStyle
    property string cfg_compactMetric
    property string cfg_gaugeInnerMetric
    property string cfg_gaugeLabel
    property alias cfg_showPace: paceCheck.checked
    property string cfg_normalColor
    property string cfg_warningColor
    property alias cfg_currencySymbol: currencyField.text
    property string cfg_claudeFolder

    // Defaults injected by Plasma config system
    property var cfg_pollIntervalDefault
    property var cfg_activityCheckIntervalDefault
    property var cfg_warningThresholdDefault
    property var cfg_criticalThresholdDefault
    property var cfg_compactStyleDefault
    property var cfg_compactMetricDefault
    property var cfg_gaugeInnerMetricDefault
    property var cfg_gaugeLabelDefault
    property var cfg_showPaceDefault
    property var cfg_normalColorDefault
    property var cfg_warningColorDefault
    property var cfg_currencySymbolDefault
    property var cfg_claudeFolderDefault

    readonly property var styleModel: [
        { value: "bars", label: "Bars" },
        { value: "gauge", label: "Gauge" }
    ]
    readonly property var gaugeLabelModel: [
        { value: "time", label: "Time remaining" },
        { value: "percent", label: "Percentage" },
        { value: "none", label: "No label" }
    ]
    readonly property var metricModel: [
        { value: "five_hour", label: "5-Hour Window" },
        { value: "seven_day", label: "Weekly All" },
        { value: "model_weekly", label: "Weekly (top model)" }
    ]
    readonly property var innerMetricModel: [
        { value: "none", label: "None" }
    ].concat(metricModel)

    Kirigami.FormLayout {
        QQC2.ComboBox {
            id: styleCombo
            Kirigami.FormData.label: "Panel style:"
            model: configGeneral.styleModel
            textRole: "label"
            currentIndex: {
                for (var i = 0; i < model.length; i++) {
                    if (model[i].value === cfg_compactStyle) return i
                }
                return 0
            }
            onActivated: cfg_compactStyle = model[currentIndex].value
        }

        QQC2.ComboBox {
            id: metricCombo
            Kirigami.FormData.label: "Gauge metric:"
            model: configGeneral.metricModel
            textRole: "label"
            visible: cfg_compactStyle === "gauge"
            currentIndex: {
                for (var i = 0; i < model.length; i++) {
                    if (model[i].value === cfg_compactMetric) return i
                }
                return 0
            }
            onActivated: cfg_compactMetric = model[currentIndex].value
        }

        QQC2.ComboBox {
            id: innerMetricCombo
            Kirigami.FormData.label: "Inner ring:"
            model: configGeneral.innerMetricModel
            textRole: "label"
            visible: cfg_compactStyle === "gauge"
            currentIndex: {
                for (var i = 0; i < model.length; i++) {
                    if (model[i].value === cfg_gaugeInnerMetric) return i
                }
                return 0
            }
            onActivated: cfg_gaugeInnerMetric = model[currentIndex].value
        }

        QQC2.ComboBox {
            id: gaugeLabelCombo
            Kirigami.FormData.label: "Gauge label:"
            model: configGeneral.gaugeLabelModel
            textRole: "label"
            visible: cfg_compactStyle === "gauge"
            currentIndex: {
                for (var i = 0; i < model.length; i++) {
                    if (model[i].value === cfg_gaugeLabel) return i
                }
                return 0
            }
            onActivated: cfg_gaugeLabel = model[currentIndex].value
        }

        QQC2.CheckBox {
            id: paceCheck
            Kirigami.FormData.label: "Popup:"
            text: "Show pace against the limit"
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Thresholds"
        }

        QQC2.SpinBox {
            id: pollIntervalSpinBox
            Kirigami.FormData.label: "Poll interval (seconds):"
            from: 30
            to: 3600
            stepSize: 30
        }

        QQC2.SpinBox {
            id: activityCheckSpinBox
            Kirigami.FormData.label: "Activity check interval (seconds):"
            from: 5
            to: 120
            stepSize: 5
        }

        QQC2.SpinBox {
            id: warningSpinBox
            Kirigami.FormData.label: "Warning threshold (%):"
            from: 10
            to: criticalSpinBox.value
            stepSize: 5
        }

        QQC2.SpinBox {
            id: criticalSpinBox
            Kirigami.FormData.label: "Critical threshold (%):"
            from: warningSpinBox.value
            to: 100
            stepSize: 5
        }

        QQC2.TextField {
            id: currencyField
            Kirigami.FormData.label: "Currency symbol:"
            maximumLength: 3
            implicitWidth: Kirigami.Units.gridUnit * 3
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Colors"
        }

        KQC.ColorButton {
            Kirigami.FormData.label: "Normal color:"
            color: cfg_normalColor
            onColorChanged: {
                if (String(color) !== cfg_normalColor)
                    cfg_normalColor = String(color)
            }
        }

        KQC.ColorButton {
            Kirigami.FormData.label: "Warning color:"
            color: cfg_warningColor
            onColorChanged: {
                if (String(color) !== cfg_warningColor)
                    cfg_warningColor = String(color)
            }
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Data Source"
        }

        QQC2.TextField {
            id: claudeFolderField
            Kirigami.FormData.label: "Claude folder:"
            placeholderText: "~/.claude (default)"
            implicitWidth: Kirigami.Units.gridUnit * 18
            text: cfg_claudeFolder
            onTextChanged: cfg_claudeFolder = text
        }
    }
}
