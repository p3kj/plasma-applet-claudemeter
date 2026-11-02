#!/usr/bin/env python3
"""Feed usage payloads through the widget's real parsing and check what it shows.

main.qml cannot run outside plasmashell, so this reuses the stubbed copy that
tools/screenshots/render.py builds, loads it under qml6 on the offscreen
platform, and reads back root's properties plus what the panel bars and the
popup make of them. No network, no plasmashell, a couple of seconds.

Usage: python3 tests/test_usage_parse.py
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "tools" / "screenshots"))
sys.dont_write_bytecode = True  # no __pycache__ left in tools/screenshots
import render  # noqa: E402

FIVE_HOUR_RESETS = "2026-11-02T13:29:59.713344+00:00"
WEEKLY_RESETS = "2026-11-08T11:59:59.713367+00:00"

# A Max account with a 5-hour window in progress.
MAX = {
    "five_hour": {"utilization": 35.0, "resets_at": FIVE_HOUR_RESETS},
    "seven_day": {"utilization": 7.0, "resets_at": WEEKLY_RESETS},
    "limits": [
        {"kind": "session", "group": "session", "percent": 35, "resets_at": FIVE_HOUR_RESETS, "scope": None, "is_active": True},
        {"kind": "weekly_all", "group": "weekly", "percent": 7, "resets_at": WEEKLY_RESETS, "scope": None, "is_active": False},
    ],
}

# Same account with no session in the last five hours: the window is idle,
# but the limit is still there.
MAX_IDLE = {
    "five_hour": {"utilization": 0.0, "resets_at": None},
    "seven_day": {"utilization": 2.0, "resets_at": WEEKLY_RESETS},
    "limits": [
        {"kind": "session", "group": "session", "percent": 0, "resets_at": None, "scope": None, "is_active": False},
        {"kind": "weekly_all", "group": "weekly", "percent": 2, "resets_at": WEEKLY_RESETS, "scope": None, "is_active": True},
    ],
}

# The 5-hour window only in `limits`, should the top-level field ever go.
SESSION_IN_LIMITS_ONLY = {
    "seven_day": {"utilization": 7.0, "resets_at": WEEKLY_RESETS},
    "limits": MAX["limits"],
}

# A verified Ultra account since 2026-10-30, quota fields verbatim from the
# capture in alexey-pelykh/sessiometer#1592.
ULTRA = json.loads(
    '{"five_hour":null,"seven_day":{"utilization":90.0,"resets_at":"2026-11-06T22:59:59.916061+00:00",'
    '"limit_dollars":null,"used_dollars":null,"remaining_dollars":null,"locked_reason":null},'
    '"limits":[{"kind":"weekly_all","group":"weekly","percent":90,"severity":"critical",'
    '"resets_at":"2026-11-06T22:59:59.916061+00:00","scope":null,"is_active":true},'
    '{"kind":"weekly_scoped","group":"weekly","percent":12,"severity":"normal",'
    '"resets_at":"2026-11-06T22:59:59.916182+00:00","scope":{"model":{"id":null,"display_name":"Fable"},'
    '"surface":null},"is_active":false}]}'
)
ULTRA_NO_KEY = {k: v for k, v in ULTRA.items() if k != "five_hour"}

ERROR = {"error": "network_error", "message": "Network error"}


def with_reset(payload, clears):
    """The payload plus a usable limit-reset grant that refills `clears`."""
    out = dict(payload)
    out["cedar_ember"] = {
        "eligible": True, "next_grant_id": "g1", "at_limit": False,
        "grants": [{"id": "g1", "label": "Reset", "resets_left": 1, "resets_total": 1,
                    "clears": clears, "usable_now": True, "percent_used": {}}],
    }
    return out


# name -> (config overrides, payloads fed in order)
CASES = {
    "max": ({}, [MAX]),
    "max_idle": ({}, [MAX_IDLE]),
    "session_in_limits_only": ({}, [SESSION_IN_LIMITS_ONLY]),
    "ultra": ({}, [ULTRA]),
    "ultra_no_key": ({}, [ULTRA_NO_KEY]),
    "max_then_ultra": ({}, [MAX, ULTRA]),
    "ultra_then_max": ({}, [ULTRA, MAX]),
    "ultra_then_error": ({}, [ULTRA, ERROR]),
    "ultra_gauge_model_weekly": ({"compactMetric": "model_weekly"}, [ULTRA]),
    "ultra_gauge_inner_five_hour": ({"gaugeInnerMetric": "five_hour"}, [ULTRA]),
    "ultra_reset": ({}, [with_reset(ULTRA, ["five_hour", "seven_day"])]),
    "max_reset": ({}, [with_reset(MAX, ["five_hour", "seven_day"])]),
}

PROBE = """import QtQuick
import "defaults.js" as Defaults

// One widget instance per case: its own plasmoid stub and root, with the panel
// bars and the popup loaded against them as plasmashell would.
Item {
    id: probe
    property var config: ({})
    property var payloads: []
    property var result: ({})

    QtObject {
        id: plasmoid
        property var configuration: Object.assign({}, Defaults.defaults, probe.config)
        property int formFactor: 2
    }

    Root { id: root }

    Loader { id: bars; source: Defaults.uiDir + "BarsRepresentation.qml" }
    Loader { id: full; source: Defaults.uiDir + "FullRepresentation.qml" }

    function findBar(item, label) {
        if (item.label === label && item.percentage !== undefined) return item
        for (var i = 0; i < item.children.length; i++) {
            var hit = findBar(item.children[i], label)
            if (hit) return hit
        }
        return null
    }

    Component.onCompleted: {
        for (var i = 0; i < payloads.length; i++) root.parseUsageData(payloads[i])
        var fiveBar = findBar(full.item, "5-Hour Window")
        result = {
            hasError: root.hasError,
            hasFiveHour: root.hasFiveHour,
            fiveHourUtil: root.fiveHourUtil,
            fiveHourResets: root.fiveHourResets,
            sevenDayUtil: root.sevenDayUtil,
            outerMetric: root.outerMetric,
            compactUtil: root.compactUtil,
            compactResets: root.compactResets,
            hasInnerRing: root.hasInnerRing,
            weekly: root.weeklyModels.map(function (m) { return m.name + ":" + m.util }),
            barCount: bars.item.barCount,
            fiveHourBarVisible: fiveBar ? fiveBar.visible : null,
            resetClears: root.resetClearsText(root.resetGrant)
        }
    }
}
"""

MAIN = """import QtQuick
import "cases.js" as Cases

Item {
    Component.onCompleted: {
        var component = Qt.createComponent("Probe.qml")
        if (component.status !== Component.Ready) {
            console.log("PROBE_ERROR " + component.errorString())
            Qt.exit(2)
            return
        }
        var out = {}
        for (var name in Cases.cases) {
            var c = Cases.cases[name]
            var probe = component.createObject(null, {
                config: c.config,
                payloads: c.payloads.map(function (p) { return JSON.stringify(p) })
            })
            out[name] = probe.result
            probe.destroy()
        }
        console.log("PROBE_RESULT " + JSON.stringify(out))
        Qt.quit()
    }
}
"""

failures = 0


def check(name, label, actual, expected):
    global failures
    if actual == expected:
        print(f"  ok    {name}: {label}")
    else:
        failures += 1
        print(f"  FAIL  {name}: {label}: expected {expected!r}, got {actual!r}")


def run_probe():
    build = Path(tempfile.mkdtemp(prefix="claudemeter-parse-"))
    try:
        (build / "Root.qml").write_text(render.make_root())
        (build / "defaults.js").write_text(render.make_defaults())
        (build / "Probe.qml").write_text(PROBE)
        (build / "main.qml").write_text(MAIN)
        cases = {name: {"config": cfg, "payloads": payloads} for name, (cfg, payloads) in CASES.items()}
        (build / "cases.js").write_text(".pragma library\nvar cases = " + json.dumps(cases) + "\n")
        env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_FORCE_STDERR_LOGGING="1",
                   QT_QUICK_CONTROLS_STYLE="org.kde.desktop")
        proc = subprocess.run(["qml6", str(build / "main.qml")], env=env,
                              capture_output=True, text=True, timeout=60)
    finally:
        shutil.rmtree(build, ignore_errors=True)
    for line in proc.stderr.splitlines():
        if "PROBE_RESULT " in line:
            results = json.loads(line.split("PROBE_RESULT ", 1)[1])
            # A property the QML does not have reads as None, so it fails a
            # check instead of stopping the run.
            return {name: defaultdict(lambda: None, res) for name, res in results.items()}
    sys.exit(f"qml6 exited {proc.returncode} without a result:\n{proc.stderr}")


def main():
    if shutil.which("qml6") is None:
        sys.exit("qml6 not found (Qt 6 declarative tools)")
    r = run_probe()

    print("\nAccounts with a 5-hour limit keep it")
    for name in ("max", "session_in_limits_only"):
        check(name, "has a 5-hour window", r[name]["hasFiveHour"], True)
        check(name, "5-hour at 35%", r[name]["fiveHourUtil"], 35)
        check(name, "5-hour reset time kept", r[name]["fiveHourResets"], FIVE_HOUR_RESETS)
        check(name, "gauge shows the 5-hour window", r[name]["outerMetric"], "five_hour")
        check(name, "two panel bars", r[name]["barCount"], 2)
        check(name, "popup shows the 5-hour bar", r[name]["fiveHourBarVisible"], True)
    check("max_idle", "an idle window still counts", r["max_idle"]["hasFiveHour"], True)
    check("max_idle", "popup still shows the 5-hour bar", r["max_idle"]["fiveHourBarVisible"], True)
    check("max_idle", "two panel bars", r["max_idle"]["barCount"], 2)

    print("\nUltra: no 5-hour limit, so no 5-hour bar")
    for name in ("ultra", "ultra_no_key"):
        res = r[name]
        check(name, "parsed without error", res["hasError"], False)
        check(name, "no 5-hour window", res["hasFiveHour"], False)
        check(name, "5-hour value cleared", (res["fiveHourUtil"], res["fiveHourResets"]), (0, ""))
        check(name, "weekly at 90%", res["sevenDayUtil"], 90)
        check(name, "Fable weekly at 12%", res["weekly"], ["Fable:12"])
        check(name, "gauge falls back to weekly", res["outerMetric"], "seven_day")
        check(name, "gauge shows the weekly value", res["compactUtil"], 90)
        check(name, "gauge counts down to the weekly reset", res["compactResets"], "2026-11-06T22:59:59.916061+00:00")
        check(name, "panel bars are weekly and Fable only", res["barCount"], 2)
        check(name, "popup hides the 5-hour bar", res["fiveHourBarVisible"], False)

    print("\nSwitching plans")
    res = r["max_then_ultra"]
    check("max_then_ultra", "the old 35% does not linger", (res["hasFiveHour"], res["fiveHourUtil"], res["fiveHourResets"]), (False, 0, ""))
    res = r["ultra_then_max"]
    check("ultra_then_max", "the 5-hour window comes back", (res["hasFiveHour"], res["fiveHourUtil"], res["fiveHourBarVisible"]), (True, 35, True))
    res = r["ultra_then_error"]
    check("ultra_then_error", "an error keeps the 5-hour bar hidden", (res["hasError"], res["hasFiveHour"], res["barCount"]), (True, False, 2))

    print("\nGauge settings")
    check("ultra_gauge_model_weekly", "an explicit weekly metric is kept", r["ultra_gauge_model_weekly"]["outerMetric"], "model_weekly")
    res = r["ultra_gauge_inner_five_hour"]
    check("ultra_gauge_inner_five_hour", "no empty 5-hour inner ring", res["hasInnerRing"], False)

    print("\nLimit reset text")
    check("ultra_reset", "names only limits the account has", r["ultra_reset"]["resetClears"], "weekly")
    check("max_reset", "still names the 5-hour limit", r["max_reset"]["resetClears"], "5-hour and weekly")

    print()
    if failures:
        print(f"{failures} failed")
        sys.exit(1)
    print("all passed")


if __name__ == "__main__":
    main()
