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
    // Scoped weekly limits, discovered dynamically from the API's `limits` array
    // (or the legacy `seven_day_*` fields it replaced), so a new plan tier shows
    // up without an update. Each entry: { key, name, label, util, resets }.
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

    // --- Clock ---
    // Ticks so the countdowns and the pace marker keep up between polls: polls are
    // 15 minutes apart and resets_at does not change within a window, so before
    // this existed no binding on formatResetTime ever re-evaluated.
    property date now: new Date()

    readonly property int sessionWindowMs: 5 * 60 * 60 * 1000
    readonly property int weeklyWindowMs: 7 * 24 * 60 * 60 * 1000

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
    // Anything unrecognised, including a config value left over from an older
    // release, falls back to the 5-hour window.
    readonly property string outerMetric: (compactMetric === "seven_day" || compactMetric === "model_weekly")
        ? compactMetric : "five_hour"
    readonly property real compactUtil: metricUtil(outerMetric)
    readonly property string compactResets: metricResets(outerMetric)
    readonly property color compactColor: usageColor(compactUtil)

    // --- Inner gauge ring ---
    readonly property string innerMetric: plasmoid.configuration.gaugeInnerMetric
    readonly property real innerUtil: metricUtil(innerMetric)
    readonly property string innerResets: metricResets(innerMetric)
    readonly property color innerColor: usageColor(innerUtil)
    // Nothing to gain from drawing the same number twice, and the default metric
    // only exists for accounts that actually have a scoped weekly limit.
    readonly property bool hasInnerRing: innerMetric !== "none"
        && innerMetric !== outerMetric
        && metricHasData(innerMetric)

    // Metric resolution shared by both gauge rings.
    function metricUtil(metric) {
        if (metric === "five_hour") return fiveHourUtil
        if (metric === "seven_day") return sevenDayUtil
        if (metric === "model_weekly") return topWeeklyModel.util
        return 0
    }

    function metricResets(metric) {
        if (metric === "five_hour") return fiveHourResets
        if (metric === "seven_day") return sevenDayResets
        if (metric === "model_weekly") return topWeeklyModel.resets
        return ""
    }

    function metricHasData(metric) {
        return metricUtil(metric) > 0 || metricResets(metric) !== ""
    }

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

    function fetchUsage() {
        root.fetchInFlight = true
        root.loading = true
        root.lastFetchTime = Date.now()
        fetchTimeoutTimer.restart()
        var scriptPath = decodeURIComponent(Qt.resolvedUrl("../scripts/fetch_usage.sh").toString().replace(/^file:\/\//, ""))
        var folder = root.claudeFolder.trim()
        var cmd = "bash \"" + scriptPath + "\""
        if (folder) cmd += " \"" + folder + "\""
        executable.exec(cmd)
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

            var limits = Array.isArray(data.limits) ? data.limits : []

            // The fixed windows have their own top-level fields and are also
            // listed in `limits`. The dedicated fields keep float precision
            // (`limits[].percent` is a rounded int) so they win where present,
            // and `limits` only stands in if one of them goes away.
            var sessionLimit = root.findLimit(limits, "session")
            var weeklyAllLimit = root.findLimit(limits, "weekly_all")
            if (data.five_hour) {
                root.fiveHourUtil = data.five_hour.utilization || 0
                root.fiveHourResets = data.five_hour.resets_at || ""
            } else if (sessionLimit) {
                root.fiveHourUtil = sessionLimit.percent || 0
                root.fiveHourResets = sessionLimit.resets_at || ""
            }
            if (data.seven_day) {
                root.sevenDayUtil = data.seven_day.utilization || 0
                root.sevenDayResets = data.seven_day.resets_at || ""
            } else if (weeklyAllLimit) {
                root.sevenDayUtil = weeklyAllLimit.percent || 0
                root.sevenDayResets = weeklyAllLimit.resets_at || ""
            }

            var weeklies = []
            var seenKeys = {}

            // Every weekly that is not the all-models one is a scoped limit:
            // per model today (Fable), possibly per surface tomorrow.
            for (var i = 0; i < limits.length; i++) {
                var limit = limits[i]
                if (!limit || limit.group !== "weekly" || limit.kind === "weekly_all") continue
                // Deliberately not filtered on `is_active`: the API sets it on
                // the scoped entry while leaving it false on both fixed windows,
                // so it does not mean "this limit is live".
                var scopeName = root.scopeNameFor(limit.scope)
                var scopeUtil = limit.percent || 0
                var scopeResets = limit.resets_at || ""
                if (scopeUtil <= 0 && !scopeResets) continue
                var scopeKey = root.scopedKeyFor(scopeName)
                seenKeys[scopeKey] = true
                weeklies.push({
                    key: scopeKey,
                    name: scopeName,
                    // The API already supplies the right casing, so the label is
                    // built from the display name rather than from the key.
                    label: "Weekly (" + scopeName + ")",
                    util: scopeUtil,
                    resets: scopeResets
                })
            }

            // Legacy per-model fields, all null since 2026-08 but cheap to keep
            // reading in case the shape moves again.
            for (var key in data) {
                if (key === "seven_day" || key.indexOf("seven_day_") !== 0) continue
                if (seenKeys[key]) continue
                var entry = data[key]
                if (!entry) continue
                var util = entry.utilization || 0
                var resets = entry.resets_at || ""
                if (util <= 0 && !resets) continue
                seenKeys[key] = true
                weeklies.push({
                    key: key,
                    name: root.weeklyNameFor(key),
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
    function weeklyNameFor(key) {
        var suffix = key.replace(/^seven_day_/, "")
        var parts = suffix.split("_")
        for (var i = 0; i < parts.length; i++) {
            parts[i] = parts[i].charAt(0).toUpperCase() + parts[i].slice(1)
        }
        return parts.join(" ")
    }

    function weeklyLabelFor(key) {
        return "Weekly (" + root.weeklyNameFor(key) + ")"
    }

    // Canonical key for a scoped limit, so `limits` entries dedupe against
    // legacy `seven_day_*` keys and sort with the same tiebreak.
    function scopedKeyFor(displayName) {
        return "seven_day_" + displayName.toLowerCase().replace(/[^a-z0-9]+/g, "_")
    }

    // What to call a scoped limit. `surface` comes as a bare string in some
    // responses and as an object shaped like `model` in others.
    function scopeNameFor(scope) {
        if (scope) {
            if (scope.model) {
                if (scope.model.display_name) return scope.model.display_name
                if (scope.model.id) return scope.model.id
            }
            if (scope.surface) {
                if (typeof scope.surface === "string") return scope.surface
                if (scope.surface.display_name) return scope.surface.display_name
                if (scope.surface.id) return scope.surface.id
            }
        }
        return "Scoped"
    }

    // First entry in the API's `limits` array of the given kind, or null.
    function findLimit(limits, kind) {
        for (var i = 0; i < limits.length; i++) {
            if (limits[i] && limits[i].kind === kind) return limits[i]
        }
        return null
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
        var now = root.now
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

    // Fraction 0..1 of a window that has elapsed, or -1 when it cannot be known.
    // The API sends no window start, but both windows are a fixed length, so the
    // start is resets_at minus that length.
    function paceFraction(resetsAt, windowMs) {
        if (!resetsAt || !windowMs) return -1
        var end = new Date(resetsAt).getTime()
        if (isNaN(end)) return -1
        var elapsed = windowMs - (end - root.now.getTime())
        // Unknown, rather than pinned to an edge: over a window elapsed means the
        // reset is already past (stale payload, or no session in the last 5h), and
        // under zero means it is more than a whole window out (clock skew).
        if (elapsed < 0 || elapsed > windowMs) return -1
        return elapsed / windowMs
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
            var scriptPath = decodeURIComponent(Qt.resolvedUrl("../scripts/fetch_usage.sh").toString().replace(/^file:\/\//, ""))
            var folder = root.claudeFolder.trim()
            var cmd = "bash \"" + scriptPath + "\""
            if (folder) cmd += " \"" + folder + "\""
            executable.disconnectSource(cmd)
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

    // --- Clock tick ---
    // 30s is well under 1% of a 5-hour window and costs one date assignment.
    Timer {
        id: clockTimer
        interval: 30000
        running: true
        repeat: true
        onTriggered: root.now = new Date()
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
