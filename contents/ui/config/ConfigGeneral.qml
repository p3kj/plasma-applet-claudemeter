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
    property string cfg_gaugeLabel
    property string cfg_normalColor
    property string cfg_warningColor
    property alias cfg_currencySymbol: currencyField.text
    property string cfg_claudeFolder
    property alias cfg_proxyEnabled: proxyEnabledCheck.checked
    property string cfg_proxyType
    property alias cfg_proxyHost: proxyHostField.text
    property alias cfg_proxyPort: proxyPortField.text
    property alias cfg_proxyUser: proxyUserField.text
    property alias cfg_proxyPassword: proxyPasswordField.text

    // Defaults injected by Plasma config system
    property var cfg_pollIntervalDefault
    property var cfg_activityCheckIntervalDefault
    property var cfg_warningThresholdDefault
    property var cfg_criticalThresholdDefault
    property var cfg_compactStyleDefault
    property var cfg_compactMetricDefault
    property var cfg_gaugeLabelDefault
    property var cfg_normalColorDefault
    property var cfg_warningColorDefault
    property var cfg_currencySymbolDefault
    property var cfg_claudeFolderDefault
    property var cfg_proxyEnabledDefault
    property var cfg_proxyTypeDefault
    property var cfg_proxyHostDefault
    property var cfg_proxyPortDefault
    property var cfg_proxyUserDefault
    property var cfg_proxyPasswordDefault

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
    readonly property var proxyTypeModel: [
        { value: "http", label: "HTTP" },
        { value: "https", label: "HTTPS" },
        { value: "socks5", label: "SOCKS5 (local DNS)" },
        { value: "socks5h", label: "SOCKS5h (remote DNS)" }
    ]

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

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Proxy"
        }

        QQC2.CheckBox {
            id: proxyEnabledCheck
            Kirigami.FormData.label: "Use proxy:"
            text: "Route the usage request through a proxy"
        }

        QQC2.ComboBox {
            id: proxyTypeCombo
            Kirigami.FormData.label: "Proxy type:"
            model: configGeneral.proxyTypeModel
            textRole: "label"
            visible: proxyEnabledCheck.checked
            currentIndex: {
                for (var i = 0; i < model.length; i++) {
                    if (model[i].value === cfg_proxyType) return i
                }
                return 0
            }
            onActivated: cfg_proxyType = model[currentIndex].value
        }

        QQC2.TextField {
            id: proxyHostField
            Kirigami.FormData.label: "Host:"
            placeholderText: "127.0.0.1"
            implicitWidth: Kirigami.Units.gridUnit * 18
            visible: proxyEnabledCheck.checked
        }

        QQC2.TextField {
            id: proxyPortField
            Kirigami.FormData.label: "Port:"
            placeholderText: "8080"
            implicitWidth: Kirigami.Units.gridUnit * 18
            visible: proxyEnabledCheck.checked
        }

        QQC2.TextField {
            id: proxyUserField
            Kirigami.FormData.label: "Username:"
            placeholderText: "(optional)"
            implicitWidth: Kirigami.Units.gridUnit * 18
            visible: proxyEnabledCheck.checked
        }

        QQC2.TextField {
            id: proxyPasswordField
            Kirigami.FormData.label: "Password:"
            placeholderText: "(optional)"
            echoMode: TextInput.Password
            implicitWidth: Kirigami.Units.gridUnit * 18
            visible: proxyEnabledCheck.checked
        }
    }
}
