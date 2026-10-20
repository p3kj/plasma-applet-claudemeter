# Changelog

## Unreleased

- New icon: the widget in a panel with its popup open, the same picture as the KDE Store logo
- Add an optional proxy on a new Proxy settings page: HTTP, HTTPS, SOCKS5 or SOCKS5h, with an optional user name and password. It covers the usage fetch, limit resets and, with an HTTP or HTTPS proxy, the token refresh. The password stays off every command line: the script reads it from Plasma's settings file and hands it to curl on stdin (#3, thanks @AltairWN)

## 0.8.0 - 2026-10-13

- Keep the cached usage per Claude folder, so two widget instances pointed at different accounts no longer show each other's data when the API rate-limits one of them (#5, thanks @victoralcazardev)
- Add an optional "Account label" (for example MAX or PRO) shown as small text next to the compact bars, in the tooltip and in the popup title, so several instances monitoring different accounts can be told apart (#6, thanks @victoralcazardev)
- Refresh shortly after a usage window ends, instead of showing "expired" until the next poll
- Let Claude Code refresh an expired token by running it for a second (`claude --init-only --safe-mode --strict-mcp-config`), so the widget keeps working while you only use Claude on the web. The popup offers a "Refresh token" button, and the new "Expired token: Let Claude Code refresh it automatically" setting (off by default) does it on its own, at most every 30 minutes per account and less often while it keeps failing (#7, building on the idea in #4 by @victoralcazardev)
- Quote the Claude folder setting safely when running the fetch script, so unusual folder names can no longer break or inject into the command

## 0.7.0 - 2026-09-23

- Show the usage-limit reset that claude.ai offers under Settings > Usage, with what it refills, how many are left and its deadline, and spend it from the popup behind a confirmation step
- Identify as the Claude Code CLI to the usage endpoint, which only lists reset grants for Claude Code and claude.ai
- Say "Out of credits" instead of "Disabled" when extra usage has run out of credits
- Say "Window ended" instead of "Resets in expired" once the 5-hour window has lapsed

## 0.6.2 - 2026-08-27

- Find the sign-in token when `~/.claude/.credentials.json` is missing, and say which folders were searched when it turns up nowhere (#1)

## 0.6.1 - 2026-08-12

- Update the widget icon: new square artwork at 256x256, which also cuts the installed package from 237 KiB to 65 KiB

## 0.6.0 - 2026-08-12

- Show pace on the popup bars: each bar is split into its hours or days, a marker tracks the current time, and usage that has run past that marker is drawn in the warning colour
- Flag a bar as "Ahead of pace" when usage is more than 2 points past the current time
- Keep the reset countdowns live instead of freezing them between polls
- Add a "Show pace against the limit" toggle for the popup bars

## 0.5.0 - 2026-08-12

- Read per-model weekly limits from the API's new `limits` array, so scoped limits like Fable appear again; the legacy `seven_day_*` fields it replaced are now all null
- Label scoped limits from `scope.model.display_name` instead of deriving them from the API key name
- Add an optional inner gauge ring, defaulting to the top scoped weekly, so gauge mode can show two limits at once

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
