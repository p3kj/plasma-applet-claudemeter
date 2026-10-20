# Claude Meter

[![KDE Store](https://img.shields.io/badge/dynamic/xml?url=https%3A%2F%2Fapi.kde-look.org%2Focs%2Fv1%2Fcontent%2Fdata%2F2348058&query=%2F%2Fversion&prefix=Get%20v&label=KDE%20Store&logo=kde&color=1d99f3)](https://store.kde.org/p/2348058/)
[![Plasma 6](https://img.shields.io/badge/Plasma-6-1d99f3?logo=kde)](https://kde.org/plasma-desktop/)
[![Release](https://img.shields.io/github/v/release/p3kj/plasma-applet-claudemeter)](https://github.com/p3kj/plasma-applet-claudemeter/releases/latest)
[![License: MIT](https://img.shields.io/github/license/p3kj/plasma-applet-claudemeter)](LICENSE)
[![Last commit](https://img.shields.io/github/last-commit/p3kj/plasma-applet-claudemeter)](https://github.com/p3kj/plasma-applet-claudemeter/commits/master)

A KDE Plasma 6 panel applet that monitors your Claude Code rate limits.

![Claude Meter in a Plasma panel, with its popup open](docs/screenshots/hero-dark.png)

## Features

<img src="docs/screenshots/popup-dark.png" alt="The popup: usage bars with pace markers, a limit reset and extra usage" width="320" align="right">

- The 5-hour window, the weekly limit and every per-model weekly limit the API reports (such as Fable), each with a reset countdown. New limits show up without an update
- Pace: each popup bar is split into its hours or days, with a marker at the current time. Usage past the marker turns the warning color, or the critical color once the bar is above the warning threshold, and a bar more than 2 points ahead says "Ahead of pace"
- Bars or a gauge in the panel, the gauge with an optional inner ring for a second limit
- Several accounts side by side: one widget per Claude folder, each with a short label
- Extra usage spent against its monthly limit, and the limit reset claude.ai offers under Settings > Usage, which you can spend from the popup after a confirmation. The widget never spends one on its own
- Optional [token refresh](#automatic-token-refresh-optional), so the widget keeps working while you only use Claude on the web
- Optional [proxy](#proxy-optional) for all of the widget's requests
- Refreshes on a schedule, shortly after you use Claude Code, and right after a usage window ends. When the API rate-limits it, it shows the last data it fetched and backs off

![Panel styles: bars, gauge, inner ring, account labels, custom colors and the warning colors](docs/screenshots/styles-dark.png)

## How it works

The widget reads the OAuth token Claude Code saves in `.credentials.json` when you sign in. It looks in `$CLAUDE_CONFIG_DIR` when that is exported session-wide, then `~/.claude`, then a single `~/.claude*` folder if exactly one has credentials. The **Claude folder** setting overrides all of that. With no folder set and no usable token in a file, an exported `CLAUDE_CODE_OAUTH_TOKEN` is used.

It then calls `GET https://api.anthropic.com/api/oauth/usage?cedar_ember=1` as the Claude Code CLI, because the server only lists reset grants for Claude Code and claude.ai. The token reaches `curl` on stdin, never on a command line where `/proc` would show it. So does a [proxy](#proxy-optional) password. Spending a reset sends the same `POST /api/organizations/<org>/reset_rate_limits` as Claude Code's `/limit-reset`. The widget never calls the OAuth token endpoint.

> **Note:** the usage endpoint is internal and undocumented. It may change or stop working without notice.

## Install

You need KDE Plasma 6, `python3`, `curl`, and the Claude Code CLI signed in with a Claude plan (Pro, Max or Team).

**From the KDE Store:** click **Install** on [Claude Meter on the KDE Store](https://store.kde.org/p/2348058/), or search for "Claude Meter" in Discover or in **Add Widgets > Get New Widgets**.

**From source:**

```sh
git clone https://github.com/p3kj/plasma-applet-claudemeter.git
cd plasma-applet-claudemeter
bash install.sh
```

Then add the "Claude Meter" widget to your panel. To update, `git pull` and run `bash install.sh` again, then restart Plasma (`systemctl --user restart plasma-plasmashell`), which otherwise keeps running the old version.

**Uninstall:**

```sh
kpackagetool6 -t Plasma/Applet -r com.github.p3kj.claudemeter
rm -rf ~/.cache/claudemeter
```

## Configuration

Right-click the widget and choose **Configure...**.

| Setting | What it does | Default |
|---|---|---|
| Panel style | Bars or Gauge | Bars |
| Gauge metric | The limit the gauge shows: 5-hour, weekly, or the fullest per-model weekly | 5-hour |
| Inner ring | A second, thinner ring for another limit, or None. Hidden when that limit has no data, would repeat the gauge, or the panel is too thin | Fullest per-model weekly |
| Gauge label | Time remaining, percentage or no label inside the gauge | Time remaining |
| Show pace against the limit | Pace segments and marker on the popup bars | On |
| Poll interval | Seconds between fetches, 30 to 3600. Automatic fetches stay at least 60 s apart | 900 |
| Activity check interval | How often to look for Claude Code activity, which triggers a fetch 15 s later | 10 s |
| Warning / Critical threshold | Percent at which bars turn the warning color, then the theme's negative (red) color | 80 / 95 |
| Currency symbol | Used for extra usage amounts | `$` |
| Normal / Warning color | Bar colors | Coral / yellow |
| Account label | Short text such as MAX or PRO, shown next to the panel view (not in vertical panels), in the tooltip and in the popup title | Empty |
| Claude folder | The Claude config folder to read, for example `~/.claude-personal` for a second account. Empty finds it as described in [How it works](#how-it-works) | Empty |
| Expired token | Let Claude Code refresh an expired token automatically, see below | Off |
| Proxy (separate page) | Send the widget's requests through a proxy, see [below](#proxy-optional) | Off |

The three gauge settings only show with the Gauge style.

## Automatic token refresh (optional)

The widget reads Claude Code's token, which lasts about 8 hours, and only Claude Code refreshes it. If you use Claude only on the web or in the desktop app for a while, the widget stops at "OAuth token has expired" until you run `claude` again. The widget can run Claude Code briefly to do that for you. It never signs in by itself and never writes your credentials: Claude Code refreshes its own token, as it does whenever you start it.

When the token has expired and can be refreshed, the popup offers a **Refresh token** button. The **Expired token** setting, off by default, makes the widget do the same on its own. With it off, Claude Code only ever starts when you click the button.

### When it runs

- Only when a fetch finds the token expired and the credentials file holds a refresh token that has not expired. Never for a token from `CLAUDE_CODE_OAUTH_TOKEN`.
- Automatically at most every 30 minutes per Claude folder, shared by all widget instances. After an automatic try that did not work, the wait doubles, up to a day, and the popup shows when the next try is due. **Refresh token** skips the wait, and one that works resets it to 30 minutes.
- Never twice at once for a folder, and not while a running Claude Code is refreshing the same token (its `.oauth_refresh.lock` is less than a minute old).
- When it works, the widget reads your usage again, once. When it does not, the popup says why and what to do.

### What it runs

From an empty folder of its own, `~/.cache/claudemeter/claude-renew` (mode 700):

```sh
CLAUDE_CONFIG_DIR=<your Claude folder> \
DISABLE_AUTOUPDATER=1 \
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
CLAUDE_CODE_SKIP_PROMPT_HISTORY=1 \
timeout -k 5 60 claude --init-only --safe-mode --strict-mcp-config </dev/null >/dev/null 2>&1
```

- `--init-only` runs Claude Code's startup, which refreshes an expired token, and exits. No prompt is sent, so no usage is spent. `--safe-mode` turns off CLAUDE.md, skills, plugins, hooks and MCP servers, and `--strict-mcp-config` ignores MCP config files. Your user settings still apply as on any start, including ones that run commands, such as `apiKeyHelper`.
- The folder must be empty, or Claude Code is not started: without a terminal it does not ask whether to trust a folder, so settings planted there would apply.
- `claude` is looked up on `PATH`, then in `~/.local/bin`. `CLAUDE_CONFIG_DIR` is left unset for `~/.claude`, because setting it would make Claude Code read `~/.claude/.claude.json` instead of `~/.claude.json`, unless your session already sets it to that folder.
- The rest of your environment is passed on, so proxy settings keep working, minus the variables that would switch Claude Code to another credential or provider or make it act as part of another session (`SCRUBBED_ENV` in `contents/scripts/renew_signin.py`). An HTTP or HTTPS proxy from the Proxy page replaces the session's `https_proxy` and `http_proxy` variables and drops `NO_PROXY`. With a SOCKS proxy there, Claude Code is not started at all.
- It takes about a second. After 30 seconds it is stopped, with everything it started (TERM, then KILL 5 seconds later), or after up to 15 seconds more if it is in the middle of refreshing, since stopping it halfway could sign you out. `timeout` stops it even if Plasma kills the widget mid-run. Its output is discarded.

In testing (Claude Code 2.1.296) it left no session transcript, no `history.jsonl` entry and no project entry. During a refresh the widget never uses, prints or passes on the tokens: it reads only their expiry times and whether a refresh token exists. It never writes tokens itself, because refresh tokens rotate and writing them back could race a running Claude Code and sign you out. Per folder it keeps a lock and a small state file in `~/.cache/claudemeter/` (`renew_<id>.lock`, `renew_<id>.json`).

## Proxy (optional)

The **Proxy** page of the settings sends the widget's requests through a proxy: reading your usage, spending a limit reset and, with an HTTP or HTTPS proxy, the token refresh. Each widget instance has its own proxy settings.

- **Type:** HTTP works with most proxies, including for https addresses. HTTPS encrypts the connection to the proxy itself. SOCKS5 looks up `api.anthropic.com` on your computer, SOCKS5h lets the proxy do it. Claude Code cannot use SOCKS, so with a SOCKS proxy the widget does not refresh an expired token at all (it would go around the proxy): run `claude` in a terminal instead.
- **Host and port:** pasting a whole URL such as `http://user:pass@proxy:3128` into Host fills in the type, port, user name and password for you.
- **User name and password** are optional. The password is stored in plain text in Plasma's widget settings file (`~/.config/plasma-org.kde.plasma.desktop-appletsrc`, readable only by you). For each request the script reads it from there with `kreadconfig6` and hands it to `curl` on stdin and to Claude Code in its environment, never on a command line where other users could see it.

With the proxy off, `curl` and Claude Code still use `https_proxy` when your Plasma session sets it, for example in `~/.config/environment.d/`.

## Troubleshooting

The warning icon in the panel means the last fetch failed. Open the popup to read why:

- **"No .credentials.json in ..."**: no sign-in token where the widget looked. `~/.claude.json` is not it: that file holds account details, never the token. Usually:
  - `CLAUDE_CONFIG_DIR` is set in your shell profile, which Plasma does not read. Put the same path in **Claude folder**, or export it session-wide in `~/.config/plasma-workspace/env/`.
  - You use an API key, `apiKeyHelper`, Bedrock, Vertex or Foundry instead of signing in. The usage endpoint needs the OAuth token you get from `claude` and `/login`. A Console API key cannot read usage, and neither can a `claude setup-token` token, which [can only make model requests](https://code.claude.com/docs/en/authentication#generate-a-long-lived-token).
  - You signed out.
- **"Could not read a token from ..."**: the credentials file is damaged or empty. Run `claude` and sign in again.
- **"Several accounts found ..."**: more than one `~/.claude*` folder has credentials. Set **Claude folder** to the one you want, and add a second widget for the other.
- **"OAuth token has expired"**: run `claude` once, click **Refresh token**, or turn on [automatic token refresh](#automatic-token-refresh-optional). If a refresh fails, the popup says why. "was not found" means `claude` is neither on Plasma's `PATH` nor in `~/.local/bin`, and "must be empty" means something is in `~/.cache/claudemeter/claude-renew`. Otherwise, run `claude` in a terminal and sign in again if it asks.
- **"API returned HTTP 401"**: the server rejected a token the file still calls valid, for example after you signed out elsewhere. Run `claude` and sign in again. The token refresh does not help here, because it only steps in once the token is past its expiry.
- **A message that names the proxy**: the widget could not get through the proxy set on its Proxy page. The message says what failed: the host was not found or did not answer, the proxy wants other credentials, or a setting is missing or malformed. Fix it on the Proxy page, or turn the proxy off.
- **"Rate limited", or "Cached" in the footer**: the API rate-limits usage polling. The widget shows the last data it fetched and backs off on its own. If it keeps happening, raise the poll interval.

## Development

Tasks are driven by [just](https://github.com/casey/just):

```sh
just              # list the recipes
just check        # lint metadata, config schema, shell, Python and QML, then build
just test-renew   # test the token refresh against a stub claude in a throwaway HOME
just test-proxy   # test the proxy settings against a stub curl in a throwaway HOME
just reinstall    # install and restart plasmashell, which otherwise keeps the old QML
just run          # open the installed widget in a window
just screenshots  # re-render docs/screenshots from the real QML (needs a desktop session)
```

### Releasing

```sh
just note "Add a thing"   # adds a bullet under "## Unreleased" in CHANGELOG.md
just release minor        # patch (the default), minor, major, or 1.0.0
```

`just release` checks that you are on `master` with a clean tree, not behind origin, with a free tag, a signed-in `gh` and a non-empty Unreleased section. It lints and asks before it bumps the version, dates the changelog, builds `dist/claudemeter-<version>.plasmoid`, commits, tags, pushes and publishes a GitHub release. An uncommitted `CHANGELOG.md` is fine, and so are untracked files outside the packaged set. `DRY_RUN=1` does it all locally without pushing or publishing (undo with `git tag -d v<version> && git reset --hard HEAD~1`).

The KDE Store has no upload API, so the recipe ends by opening the [store edit page](https://store.kde.org/p/2348058/edit) and `dist/`, with the release notes on the clipboard when `wl-copy` is installed.

## License

[MIT](LICENSE)
