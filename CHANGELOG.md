# Changelog

## 0.5.0 - 2026-06-08

- Add optional proxy support for the usage request: configure an HTTP, HTTPS, or SOCKS5 proxy (with optional username/password) in the widget settings. The proxy password, like the OAuth token, is passed to `curl` via stdin so it never appears on a process command line

## 0.4.0 - 2026-06-07

- Add "Claude folder" config option to point the widget at an alternate Claude config folder (e.g. `~/.claude-personal` when using `CLAUDE_CONFIG_DIR` for multiple accounts). Each widget instance can monitor a different account
- Activity detection follows the configured folder as well

## 0.3.1 - 2026-04-26

- Fix plasmashell crash when expanding the popup (KDE bug 489365): wrap `FullRepresentation` root in a plain `Item` so the popup-sizing path no longer recurses through a `QQuickLayout` root and dereferences a null `QQuickLayoutAttached`

## 0.3.0 - 2026-04-20

- Replace hardcoded Sonnet weekly bar with dynamic per-model weeklies: the widget now shows any active `seven_day_*` entry returned by the API (e.g. Opus, Cowork), so new model tiers appear without a widget update
- Labels are derived from the API key name (e.g. `seven_day_opus` becomes "Weekly (Opus)")
- Gauge "Weekly Sonnet" option replaced with "Weekly (top model)", which tracks the most-utilized per-model weekly. Existing configs pointing at `seven_day_sonnet` map to this automatically
- Compact bar strip now sizes itself to the actual number of active limits instead of a fixed 3

## 0.2.0 - 2026-03-09

- Add rate limiting with cooldown and exponential backoff to avoid hammering the API
- Cache successful responses to disk; serve cached data on HTTP 429
- Add 30s fetch timeout with DataSource disconnect to recover from hung requests
- Fix timeout recovery: disconnect DataSource so subsequent fetches aren't silently blocked
- Fix cache read crash on corrupt JSON (now falls through to error message)
- Show "Request timed out" error instead of silently clearing the loading state
- Show "Cached" label with original fetch timestamp when serving cached data
- Fix initial lastUpdated from current time to epoch so first-fetch errors surface properly

## 0.1.0 - 2026-02-14

Initial release.

- Display three rate limit windows: 5-hour, 7-day (all models), 7-day (Sonnet)
- Two compact panel styles: stacked bars and circular gauge
- Configurable warning/critical thresholds with color coding
- Customizable bar colors
- Auto-refresh on configurable polling interval
- Secure token handling (passed via stdin, never as CLI argument)
