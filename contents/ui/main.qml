import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as Plasma5Support

PlasmoidItem {
    id: root

    // --- Usage data properties ---
    property real fiveHourUtil: 0
    property string fiveHourResets: ""
    property real sevenDayUtil: 0
    property string sevenDayResets: ""
    // Per-model weekly limits, discovered dynamically from any `seven_day_*`
    // field in the API response. Each entry: { key, label, util, resets }.
    property var weeklyModels: []
    property bool hasError: false
    property string errorMessage: ""
    property bool loading: true
    property date lastUpdated: new Date(0)

    // --- Extra usage ---
    property bool hasExtraUsage: false
    property bool extraUsageEnabled: false
    property real extraUsageUtil: 0
    property string extraUsageLimit: ""
    property string extraUsageUsed: ""

    // --- Cache state ---
    property bool dataCached: false

    // --- Activity monitor state ---
    property real lastActivityMtime: 0

    // --- Rate limiting ---
    property real lastFetchTime: 0
    property int cooldownMs: 60000
    property int backoffMultiplier: 1
    property int maxBackoffMultiplier: 8
    property bool fetchInFlight: false

    // --- Config ---
    readonly property int pollInterval: plasmoid.configuration.pollInterval * 1000
    readonly property int activityCheckInterval: plasmoid.configuration.activityCheckInterval * 1000
    readonly property int warningThreshold: plasmoid.configuration.warningThreshold
    readonly property int criticalThreshold: plasmoid.configuration.criticalThreshold
    readonly property string claudeFolder: plasmoid.configuration.claudeFolder

    // --- Compact gauge computed properties ---
    readonly property string compactMetric: plasmoid.configuration.compactMetric
    // Picks the most-utilized active model-specific weekly, or an empty stub.
    readonly property var topWeeklyModel: {
        var top = { util: 0, resets: "" }
        for (var i = 0; i < weeklyModels.length; i++) {
            if (weeklyModels[i].util > top.util) top = weeklyModels[i]
        }
        return top
    }
    readonly property real compactUtil: compactMetric === "seven_day" ? sevenDayUtil
        : compactMetric === "model_weekly" ? topWeeklyModel.util
        : fiveHourUtil
    readonly property string compactResets: compactMetric === "seven_day" ? sevenDayResets
        : compactMetric === "model_weekly" ? topWeeklyModel.resets
        : fiveHourResets
    readonly property color compactColor: usageColor(compactUtil)

    // --- Executable DataSource ---
    Plasma5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            var stdout = data["stdout"]
            root.parseUsageData(stdout)
            disconnectSource(sourceName)
        }
        function exec(cmd) {
            if (cmd) connectSource(cmd)
        }
    }

    // Single-quote a value for safe use in a shell command, escaping any
    // embedded single quotes (e.g. in a proxy password).
    function shellQuote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'"
    }

    // Assemble the fetch command, optionally prefixed with proxy env vars.
    // All call sites use this so connect/disconnect keys match exactly.
    function buildFetchCommand() {
        var scriptPath = decodeURIComponent(Qt.resolvedUrl("../scripts/fetch_usage.sh").toString().replace(/^file:\/\//, ""))
        var folder = root.claudeFolder.trim()
        var cfg = plasmoid.configuration
        var prefix = ""
        if (cfg.proxyEnabled && cfg.proxyHost.trim()) {
            var type = cfg.proxyType || "http"
            var host = cfg.proxyHost.trim()
            var port = cfg.proxyPort
            prefix += "CM_PROXY=" + shellQuote(type + "://" + host + ":" + port) + " "
            var user = cfg.proxyUser.trim()
            if (user) {
                prefix += "CM_PROXY_USER=" + shellQuote(user + ":" + cfg.proxyPassword) + " "
            }
        }
        var cmd = prefix + "bash \"" + scriptPath + "\""
        if (folder) cmd += " \"" + folder + "\""
        return cmd
    }

    function fetchUsage() {
        root.fetchInFlight = true
        root.loading = true
        root.lastFetchTime = Date.now()
        fetchTimeoutTimer.restart()
        executable.exec(root.buildFetchCommand())
    }

    function requestFetch(source) {
        if (root.fetchInFlight) return

        var bypass = (source === "startup" || source === "manual")
        if (!bypass) {
            var elapsed = Date.now() - root.lastFetchTime
            if (elapsed < root.cooldownMs * root.backoffMultiplier) return
        }

        pollTimer.restart()
        root.fetchUsage()
    }

    function parseUsageData(stdout) {
        fetchTimeoutTimer.stop()
        root.fetchInFlight = false
        root.loading = false
        try {
            var data = JSON.parse(stdout)
            if (data.error) {
                root.hasError = true
                root.errorMessage = data.message || data.error
                return
            }
            root.hasError = false
            root.errorMessage = ""

            if (data.five_hour) {
                root.fiveHourUtil = data.five_hour.utilization || 0
                root.fiveHourResets = data.five_hour.resets_at || ""
            }
            if (data.seven_day) {
                root.sevenDayUtil = data.seven_day.utilization || 0
                root.sevenDayResets = data.seven_day.resets_at || ""
            }

            var weeklies = []
            for (var key in data) {
                if (key === "seven_day" || key.indexOf("seven_day_") !== 0) continue
                var entry = data[key]
                if (!entry) continue
                var util = entry.utilization || 0
                var resets = entry.resets_at || ""
                if (util <= 0 && !resets) continue
                weeklies.push({
                    key: key,
                    label: root.weeklyLabelFor(key),
                    util: util,
                    resets: resets
                })
            }
            weeklies.sort(function (a, b) {
                if (b.util !== a.util) return b.util - a.util
                return a.key < b.key ? -1 : a.key > b.key ? 1 : 0
            })
            root.weeklyModels = weeklies

            if (data.extra_usage) {
                root.hasExtraUsage = true
                root.extraUsageEnabled = data.extra_usage.is_enabled || false
                root.extraUsageUtil = data.extra_usage.utilization || 0
                root.extraUsageLimit = data.extra_usage.monthly_limit != null ? plasmoid.configuration.currencySymbol + (data.extra_usage.monthly_limit / 100).toFixed(2) : ""
                root.extraUsageUsed = plasmoid.configuration.currencySymbol + ((data.extra_usage.used_credits || 0) / 100).toFixed(2)
            } else {
                root.hasExtraUsage = false
                root.extraUsageEnabled = false
            }

            root.dataCached = !!data.cached
            if (data.rate_limited) {
                root.backoffMultiplier = Math.min(root.backoffMultiplier * 2, root.maxBackoffMultiplier)
            } else {
                root.backoffMultiplier = 1
            }

            if (data.cached && data._fetched_at) {
                root.lastUpdated = new Date(data._fetched_at * 1000)
            } else {
                root.lastUpdated = new Date()
            }
        } catch (e) {
            root.hasError = true
            root.errorMessage = "Failed to parse response"
        }
    }

    // --- Helper functions ---
    function weeklyLabelFor(key) {
        var suffix = key.replace(/^seven_day_/, "")
        var parts = suffix.split("_")
        for (var i = 0; i < parts.length; i++) {
            parts[i] = parts[i].charAt(0).toUpperCase() + parts[i].slice(1)
        }
        return "Weekly (" + parts.join(" ") + ")"
    }

    function usageColor(percent) {
        if (percent >= root.criticalThreshold) {
            return Kirigami.Theme.negativeTextColor
        } else if (percent >= root.warningThreshold) {
            return plasmoid.configuration.warningColor || "#E5C07B"
        } else {
            return plasmoid.configuration.normalColor || "#D77757"
        }
    }

    function formatResetTime(isoString) {
        if (!isoString) return ""
        var d = new Date(isoString)
        var now = new Date()
        var diffMs = d.getTime() - now.getTime()
        if (diffMs <= 0) return "expired"
        var diffMin = Math.floor(diffMs / 60000)
        var diffHrs = Math.floor(diffMin / 60)
        var remainMin = diffMin % 60
        if (diffHrs >= 24) {
            var days = Math.floor(diffHrs / 24)
            var hrs = diffHrs % 24
            return days + "d " + hrs + "h"
        }
        if (diffHrs > 0) return diffHrs + "h " + remainMin + "m"
        return diffMin + "m"
    }

    // --- Activity monitor DataSource ---
    Plasma5Support.DataSource {
        id: activityChecker
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            var stdout = data["stdout"].trim()
            var mtime = parseInt(stdout)
            if (!isNaN(mtime)) {
                if (root.lastActivityMtime > 0 && mtime > root.lastActivityMtime) {
                    fetchDelayTimer.restart()
                }
                root.lastActivityMtime = mtime
            }
            disconnectSource(sourceName)
        }
        function check() {
            var folder = root.claudeFolder.trim()
            // Expand leading ~ since this runs in a non-login shell
            if (folder.charAt(0) === "~") folder = "$HOME" + folder.slice(1)
            var dir = folder || "$HOME/.claude"
            // GNU stat format — Linux-only, which is fine since this is a KDE Plasma widget
            connectSource("stat --format=%Y \"" + dir + "/history.jsonl\" 2>/dev/null || echo 0")
        }
    }

    // --- Activity check timer ---
    Timer {
        id: activityTimer
        interval: root.activityCheckInterval
        running: true
        repeat: true
        onTriggered: activityChecker.check()
        Component.onCompleted: activityChecker.check()
    }

    // --- Fetch timeout recovery ---
    Timer {
        id: fetchTimeoutTimer
        interval: 30000
        running: false
        repeat: false
        onTriggered: {
            executable.disconnectSource(root.buildFetchCommand())
            root.fetchInFlight = false
            root.loading = false
            root.hasError = true
            root.errorMessage = "Request timed out"
        }
    }

    // --- Delay before fetching after activity ---
    Timer {
        id: fetchDelayTimer
        interval: 15000
        running: false
        repeat: false
        onTriggered: root.requestFetch("activity")
    }

    // --- Polling timer ---
    Timer {
        id: pollTimer
        interval: root.pollInterval
        running: true
        repeat: true
        onTriggered: root.requestFetch("poll")
        Component.onCompleted: root.requestFetch("startup")
    }

    // --- Widget setup ---
    switchWidth: Kirigami.Units.gridUnit * 12
    switchHeight: Kirigami.Units.gridUnit * 8

    compactRepresentation: CompactRepresentation {}
    fullRepresentation: FullRepresentation {}
}
