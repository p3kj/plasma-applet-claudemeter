import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: configProxy

    property alias cfg_proxyEnabled: enabledCheck.checked
    property string cfg_proxyType
    property alias cfg_proxyHost: hostField.text
    property alias cfg_proxyPort: portSpinBox.value
    property alias cfg_proxyUser: userField.text
    property alias cfg_proxyPassword: passwordField.text

    // Defaults injected by Plasma config system
    property var cfg_proxyEnabledDefault
    property var cfg_proxyTypeDefault
    property var cfg_proxyHostDefault
    property var cfg_proxyPortDefault
    property var cfg_proxyUserDefault
    property var cfg_proxyPasswordDefault

    readonly property var typeModel: [
        { value: "http", label: "HTTP" },
        { value: "https", label: "HTTPS" },
        { value: "socks5", label: "SOCKS5" },
        { value: "socks5h", label: "SOCKS5h (DNS through the proxy)" }
    ]

    // Called by the settings dialog before it saves, so a host typed and
    // applied without leaving the field is tidied too. The password is kept
    // exactly as typed.
    function saveConfig() {
        takeHost(hostField.text)
        userField.text = userField.text.trim()
    }

    function decoded(text) {
        try {
            return decodeURIComponent(text)
        } catch (e) {
            return text
        }
    }

    // Takes a pasted proxy URL apart: a known scheme sets the type, a user and
    // password replace those fields (and never stay in the host, which an
    // error message may show), and host:port fills both fields.
    function takeHost(text) {
        var host = String(text).trim()
        var scheme = host.match(/^([A-Za-z][A-Za-z0-9+.-]*):\/\//)
        if (scheme) {
            host = host.slice(scheme[0].length)
            for (var i = 0; i < typeModel.length; i++) {
                if (typeModel[i].value !== scheme[1].toLowerCase()) continue
                cfg_proxyType = typeModel[i].value
                // Set too, since picking a type by hand breaks its binding.
                typeCombo.currentIndex = i
            }
        }
        // At the last @ before anything else, since a pasted password may well
        // hold a / ? # or @ of its own.
        var at = host.lastIndexOf("@")
        if (at >= 0) {
            var userinfo = host.slice(0, at)
            host = host.slice(at + 1)
            var colon = userinfo.indexOf(":")
            userField.text = decoded(colon >= 0 ? userinfo.slice(0, colon) : userinfo)
            passwordField.text = colon >= 0 ? decoded(userinfo.slice(colon + 1)) : ""
        }
        host = host.split(/[\/?#]/)[0]
        var hostPort = host.match(/^(\[[^\]]*\]|[^:]*):(\d{1,5})$/)
        if (hostPort) {
            host = hostPort[1]
            var port = parseInt(hostPort[2], 10)
            if (port >= 1 && port <= 65535) portSpinBox.value = port
        }
        if (host.charAt(0) === "[" && host.charAt(host.length - 1) === "]") host = host.slice(1, -1)
        hostField.text = host
    }

    Kirigami.FormLayout {
        RowLayout {
            Kirigami.FormData.label: "Proxy:"
            spacing: Kirigami.Units.smallSpacing

            QQC2.CheckBox {
                id: enabledCheck
                text: "Send the widget's requests through a proxy"
            }

            Kirigami.ContextualHelpButton {
                toolTipText: "Covers reading your usage, spending a limit reset and, with an HTTP or HTTPS proxy, the token refresh. With this off, curl and Claude Code still use https_proxy if your Plasma session sets it."
            }
        }

        RowLayout {
            Kirigami.FormData.label: "Type:"
            spacing: Kirigami.Units.smallSpacing
            enabled: enabledCheck.checked

            QQC2.ComboBox {
                id: typeCombo
                model: configProxy.typeModel
                textRole: "label"
                currentIndex: {
                    for (var i = 0; i < model.length; i++) {
                        if (model[i].value === cfg_proxyType) return i
                    }
                    return 0
                }
                onActivated: cfg_proxyType = model[currentIndex].value
            }

            Kirigami.ContextualHelpButton {
                toolTipText: "HTTP works with most proxies, including for https addresses. HTTPS encrypts the connection to the proxy itself. SOCKS5 looks up api.anthropic.com on this computer, SOCKS5h lets the proxy do it. With a SOCKS proxy the widget cannot refresh an expired token, because Claude Code does not support SOCKS. Run claude in a terminal instead."
            }
        }

        QQC2.TextField {
            id: hostField
            Kirigami.FormData.label: "Host:"
            placeholderText: "proxy.example.com"
            implicitWidth: Kirigami.Units.gridUnit * 18
            Layout.maximumWidth: implicitWidth
            enabled: enabledCheck.checked
            onEditingFinished: configProxy.takeHost(text)
        }

        QQC2.SpinBox {
            id: portSpinBox
            Kirigami.FormData.label: "Port:"
            from: 1
            to: 65535
            editable: true
            enabled: enabledCheck.checked
            validator: IntValidator {
                bottom: 1
                top: 65535
            }
            // Plain digits: the locale would make 8080 read "8 080" or "8,080".
            textFromValue: (value, locale) => String(value)
            valueFromText: (text, locale) => parseInt(text, 10) || value
        }

        QQC2.TextField {
            id: userField
            Kirigami.FormData.label: "User name:"
            placeholderText: "Optional"
            implicitWidth: Kirigami.Units.gridUnit * 18
            Layout.maximumWidth: implicitWidth
            enabled: enabledCheck.checked
        }

        RowLayout {
            Kirigami.FormData.label: "Password:"
            spacing: Kirigami.Units.smallSpacing
            enabled: enabledCheck.checked && userField.text.trim() !== ""

            Kirigami.PasswordField {
                id: passwordField
                placeholderText: "Optional"
                // As wide as the fields above, with the help button past them.
                Layout.preferredWidth: Kirigami.Units.gridUnit * 18
            }

            Kirigami.ContextualHelpButton {
                toolTipText: "Stored in plain text in Plasma's widget settings file, which only you can read. For each request the widget reads it from there and hands it to curl on stdin, or to Claude Code in its environment for a token refresh, never on a command line where other users could see it."
            }
        }
    }
}
