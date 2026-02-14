#!/bin/bash
# DEMO MODE: outputs hardcoded fake usage data for screenshots.
# Timestamps are computed dynamically so "resets in X" always looks realistic.

five_hour_reset=$(date -u -d "+3 hours +25 minutes" +"%Y-%m-%dT%H:%M:%S.000Z")
seven_day_reset=$(date -u -d "+4 days +7 hours" +"%Y-%m-%dT%H:%M:%S.000Z")
sonnet_reset=$(date -u -d "+5 days +2 hours" +"%Y-%m-%dT%H:%M:%S.000Z")

cat <<EOF
{"five_hour":{"utilization":43,"resets_at":"${five_hour_reset}"},"seven_day":{"utilization":85,"resets_at":"${seven_day_reset}"},"seven_day_sonnet":{"utilization":25,"resets_at":"${sonnet_reset}"}}
EOF
