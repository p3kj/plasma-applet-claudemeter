import QtQuick

import org.kde.plasma.configuration

ConfigModel {
    ConfigCategory {
        name: "General"
        icon: "configure"
        source: "config/ConfigGeneral.qml"
    }
    ConfigCategory {
        name: "Proxy"
        icon: "preferences-system-network-proxy"
        source: "config/ConfigProxy.qml"
    }
}
