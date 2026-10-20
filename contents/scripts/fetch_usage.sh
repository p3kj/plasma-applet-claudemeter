#!/bin/bash
# Fetch Claude Code usage data from the Anthropic API
# Outputs JSON to stdout. Always exits 0; errors reported as JSON.
#
# Usage: fetch_usage.sh [--activity] [--proxy-from APP:CONTAINMENT:APPLET] [-- claude-folder]
#        fetch_usage.sh --claim <grant-id> <request-id> [--proxy-from ...] [-- claude-folder]
#        fetch_usage.sh --renew [--now] [--proxy-from ...] [-- claude-folder]
#   --proxy-from  send the requests through the proxy set on the Proxy page of
#               this widget instance (Plasma app name, containment id, applet
#               id). The settings, password included, are read from Plasma's
#               own settings file, so none of them is on a command line.
#               --activity ignores it.
#   --          everything after it is the folder, even if it starts with a
#               dash. The widget always passes it. Without it, a folder that
#               starts with a dash is refused rather than read as a mode.
#   --activity  print the mtime of history.jsonl in the resolved folder (or 0)
#               instead of fetching, so activity polling follows the same
#               folder resolution the fetch does.
#   --claim     spend one usage-limit reset from the given grant. Prints
#               {"claim": {"result": ...}}. Only ever run on an explicit click;
#               CLAUDEMETER_DRY_RUN=1 prints the request instead of sending it.
#   --renew     start Claude Code hidden for a moment so it renews an expired
#               sign-in in the resolved folder (see renew_signin.py). Prints
#               {"renew": {"result": ...}}. At most once per 30 minutes per
#               folder, less often after tries that did not work; --now (an
#               explicit click) skips that wait.
#
# A token_expired error from a fetch carries "renew": {"possible", "reason"}.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENEW_HELPER="$SCRIPT_DIR/renew_signin.py"

MODE="fetch"
GRANT_ID=""
REQUEST_ID=""
RENEW_NOW=""
if [ "${1:-}" = "--activity" ]; then
    MODE="activity"
    shift
elif [ "${1:-}" = "--claim" ]; then
    MODE="claim"
    GRANT_ID="${2:-}"
    REQUEST_ID="${3:-}"
    shift 3 || shift $#
elif [ "${1:-}" = "--renew" ]; then
    MODE="renew"
    shift
    if [ "${1:-}" = "--now" ]; then
        RENEW_NOW="1"
        shift
    fi
fi

# Tracked apart from the value, so "--proxy-from" with a missing or empty
# value fails instead of quietly going direct.
PROXY_WANTED=""
PROXY_REF=""
if [ "${1:-}" = "--proxy-from" ]; then
    PROXY_WANTED="1"
    PROXY_REF="${2:-}"
    shift 2 || shift $#
fi

DASHDASH=""
if [ "${1:-}" = "--" ]; then
    DASHDASH="1"
    shift
fi
EXPLICIT="${1:-}"
API="https://api.anthropic.com"

# Reset grants (the usage response's `cedar_ember` block) are only offered to
# Claude Code and claude.ai: any other User-Agent gets `ineligible_reason:
# "surface"` and an empty grant list. So identify as the installed Claude Code,
# or a recent release when the native installer's versions folder is absent.
CLAUDE_VERSION="2.1.280"
if [ -d "$HOME/.local/share/claude/versions" ]; then
    NEWEST="$(ls "$HOME/.local/share/claude/versions" 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+)+$' | sort -V | tail -n 1 || true)"
    if [ -n "$NEWEST" ]; then
        CLAUDE_VERSION="$NEWEST"
    fi
fi
USER_AGENT="claude-cli/$CLAUDE_VERSION (external, cli)"

error_json() {
    python3 -c "import json,sys; print(json.dumps({'error':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"
    exit 0
}

# A mode flag in the wrong place, or a folder setting such as "--renew", must
# never switch modes or turn into a folder.
if [ -z "$DASHDASH" ] && [ "${EXPLICIT#-}" != "$EXPLICIT" ]; then
    error_json "bad_folder" "Refusing the Claude folder \"$EXPLICIT\": it starts with a dash. Put -- before it."
fi

# Nothing may follow the folder: a flag there would be ignored, and a request
# meant for the proxy would go direct.
if [ "$#" -gt 1 ]; then
    error_json "bad_arguments" "Refusing unexpected arguments after the Claude folder."
fi

# Abbreviate $HOME to ~ for display. Done with bash substitution rather than sed
# so paths containing regex or delimiter metacharacters cannot corrupt it.
tildify() {
    local p="$1"
    if [ "$HOME" != "/" ] && [ "${p#"$HOME"}" != "$p" ]; then
        printf '~%s' "${p#"$HOME"}"
    else
        printf '%s' "$p"
    fi
}

trim() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    printf '%s' "${v%"${v##*[![:space:]]}"}"
}

# Filled by load_proxy. PROXY_URL never holds the user or the password.
PROXY_TYPE=""
PROXY_HOST=""
PROXY_HOSTPORT=""
PROXY_URL=""
PROXY_USER=""
PROXY_PASSWORD=""
PROXY_USERPASS=""

# Messages name the host only once it is checked, and never the user or the
# password: error_json puts its message on python3's command line.
proxy_error() {
    local msg="$1"
    if [ "$MODE" = "claim" ]; then
        msg="$msg Nothing was used."
    fi
    error_json "proxy_error" "$msg"
}

# config_value <file> <key> <group args...>: the value in VALUE, empty when the
# file, group or key is missing (kreadconfig6 exits 0 for all of those). The x
# keeps $(...) from stripping more than kreadconfig6's own newline.
config_value() {
    VALUE="$(kreadconfig6 --file "$1" "${@:3}" --key "$2" 2>/dev/null; printf x)"
    VALUE="${VALUE%x}"
    VALUE="${VALUE%$'\n'}"
}

# Reads this widget's Proxy page from the file Plasma keeps its settings in.
# Anything missing or malformed is a proxy_error, never a direct request.
# Called directly, never in $(...), so that error_json ends the script.
load_proxy() {
    # In a UTF-8 locale, [0-9] also matches digits such as ٣ or ８, which
    # would get past the checks below and then break the arithmetic on them.
    local LC_ALL=C
    local not_found="Could not find this widget's proxy settings. Open the Proxy page and click Apply, or turn the proxy off."
    if ! [[ "$PROXY_REF" =~ ^([A-Za-z0-9._-]{1,64}):([0-9]{1,10}):([0-9]{1,10})$ ]]; then
        proxy_error "$not_found"
    fi
    local app="${BASH_REMATCH[1]}" containment="${BASH_REMATCH[2]}" applet="${BASH_REMATCH[3]}"
    if ! command -v kreadconfig6 >/dev/null; then
        proxy_error "The proxy needs kreadconfig6, which was not found. It is part of KDE Frameworks (package kconfig, or libkf6config-bin on Debian and Ubuntu)."
    fi
    local config="${XDG_CONFIG_HOME:-}"
    case "$config" in
        /*) ;;
        *) config="$HOME/.config" ;;
    esac
    # plasmawindowed (`just run`) keeps its applets in its own rc file, each
    # Plasma shell in a plasma-<shell>-appletsrc.
    local files=() groups=()
    if [ "$app" = "plasmawindowed" ]; then
        files=("$config/plasmawindowedrc")
        groups=(--group Applets --group "$applet")
    else
        files=("$config"/plasma-*-appletsrc)
        groups=(--group Containments --group "$containment" --group Applets --group "$applet")
    fi
    local general=("${groups[@]}" --group Configuration --group General)
    local file found=()
    for file in "${files[@]}"; do
        [ -f "$file" ] || continue
        # Read as a bool, so 1, yes and on count as they do for Plasma.
        # kreadconfig6 answers a bool with its exit code alone.
        if kreadconfig6 --file "$file" --type bool "${general[@]}" --key proxyEnabled >/dev/null 2>&1; then
            found+=("$file")
        fi
    done
    if [ "${#found[@]}" -ne 1 ]; then
        proxy_error "$not_found"
    fi
    file="${found[0]}"

    # Plasma leaves out a value that is at its default (see main.xml).
    config_value "$file" proxyType "${general[@]}"
    PROXY_TYPE="${VALUE:-http}"
    case "$PROXY_TYPE" in
        http|https|socks5|socks5h) ;;
        *) proxy_error "The proxy type is not HTTP, HTTPS, SOCKS5 or SOCKS5h. Pick one on the Proxy page." ;;
    esac

    config_value "$file" proxyHost "${general[@]}"
    local host
    host="$(trim "$VALUE")"
    if [[ "$host" == \[*\] ]]; then
        host="${host:1:${#host}-2}"
    fi
    if [ -z "$host" ]; then
        proxy_error "The proxy is on, but has no host. Set one on the Proxy page, or turn the proxy off."
    fi
    # A host name, or an IPv6 address (which gets brackets in the URL). curl
    # judges whether the address itself is valid (exit 3, see blame_proxy).
    if [[ "$host" == *:* ]]; then
        [[ "$host" =~ ^[0-9A-Fa-f:.]{2,45}$ ]] || host=""
    elif ! [[ "$host" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,252}$ ]]; then
        host=""
    fi
    if [ -z "$host" ]; then
        proxy_error "The proxy host on the Proxy page is not a host name or an IP address."
    fi

    config_value "$file" proxyPort "${general[@]}"
    local port="${VALUE:-8080}"
    if ! [[ "$port" =~ ^[0-9]{1,5}$ ]] || [ "$((10#$port))" -lt 1 ] || [ "$((10#$port))" -gt 65535 ]; then
        proxy_error "The proxy port on the Proxy page is not between 1 and 65535."
    fi
    port="$((10#$port))"

    # A password without a user name is never sent.
    config_value "$file" proxyUser "${general[@]}"
    PROXY_USER="$(trim "$VALUE")"
    PROXY_PASSWORD=""
    if [ -n "$PROXY_USER" ]; then
        config_value "$file" proxyPassword "${general[@]}"
        PROXY_PASSWORD="$VALUE"
    fi
    VALUE=""
    # curl splits user:password at the first colon.
    if [[ "$PROXY_USER" == *:* ]]; then
        proxy_error "The proxy user name on the Proxy page contains a colon, which curl would read as the start of the password."
    fi
    if [[ "$PROXY_USER$PROXY_PASSWORD" == *[[:cntrl:]]* ]]; then
        proxy_error "The proxy user name or password on the Proxy page contains a tab, a line break or another control character."
    fi

    PROXY_HOST="$host"
    if [[ "$host" == *:* ]]; then
        PROXY_HOSTPORT="[$host]:$port"
    else
        PROXY_HOSTPORT="$host:$port"
    fi
    PROXY_URL="$PROXY_TYPE://$PROXY_HOSTPORT"
    PROXY_USERPASS=""
    if [ -n "$PROXY_USER" ]; then
        PROXY_USERPASS="$PROXY_USER:$PROXY_PASSWORD"
    fi
}

# A value in double quotes for curl's config. Inside them curl only reads
# \\ \" \t \n \r \v as escapes, so with \ and " escaped and control characters
# refused above, a password stays one value and cannot add curl options.
curl_quoted() {
    local v="${1//\\/\\\\}"
    printf '"%s"' "${v//\"/\\\"}"
}

# What curl reads on stdin (-K -): the token, and the proxy when one is set.
# Only bash builtins see these values, so none of them is on a command line.
curl_config() {
    printf 'header = "Authorization: Bearer %s"\n' "$TOKEN"
    if [ -z "$PROXY_URL" ]; then
        return 0
    fi
    printf 'proxy = %s\n' "$(curl_quoted "$PROXY_URL")"
    # The widget's proxy wins over a no_proxy in the environment.
    printf 'noproxy = ""\n'
    if [ -n "$PROXY_USERPASS" ]; then
        printf 'proxy-user = %s\n' "$(curl_quoted "$PROXY_USERPASS")"
        # Lets curl answer a proxy that asks for Digest, NTLM or Negotiate.
        case "$PROXY_TYPE" in
            http|https) printf 'proxy-anyauth\n' ;;
        esac
    fi
}

# blame_proxy <curl exit code> <CONNECT reply code>: a proxy_error when the
# proxy is what failed, so the message does not point at Anthropic. In each of
# these cases nothing reached Anthropic.
blame_proxy() {
    if [ -z "$PROXY_URL" ]; then
        return 0
    fi
    case "$2" in
        407) proxy_error "The proxy at $PROXY_HOSTPORT wants a user name and password, or did not accept the ones on the Proxy page." ;;
        000|200) ;;
        [1-5][0-9][0-9]) proxy_error "The proxy at $PROXY_HOSTPORT refused the connection (HTTP $2)." ;;
    esac
    case "$1" in
        3) proxy_error "The proxy address $PROXY_HOSTPORT is not valid." ;;
        5) proxy_error "Could not find the proxy host $PROXY_HOST." ;;
        7) proxy_error "Could not connect to the proxy at $PROXY_HOSTPORT." ;;
        35) proxy_error "Could not set up a secure connection to the proxy at $PROXY_HOSTPORT. If it is a plain HTTP proxy, pick HTTP as the type." ;;
        60) proxy_error "The certificate check failed behind the proxy at $PROXY_HOSTPORT. If the proxy inspects TLS, add its CA certificate to the system store." ;;
        97) proxy_error "The proxy at $PROXY_HOSTPORT refused the connection. Check its type, user name and password." ;;
    esac
}

# Which folders to look in. An explicit first arg (the widget's "Claude folder"
# setting) wins outright; otherwise try the locations Claude Code actually uses.
# plasmashell does not source a shell profile, so CLAUDE_CONFIG_DIR is only
# visible here when it is exported session-wide.
CANDIDATES=()
if [ -n "$EXPLICIT" ]; then
    # Expand leading ~ in case the user typed it literally
    CANDIDATES+=("${EXPLICIT/#\~/$HOME}")
else
    if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
        CANDIDATES+=("${CLAUDE_CONFIG_DIR/#\~/$HOME}")
    fi
    CANDIDATES+=("$HOME/.claude")
fi

CLAUDE_DIR="${CANDIDATES[0]}"
CRED_FILE=""
for dir in "${CANDIDATES[@]}"; do
    if [ -f "$dir/.credentials.json" ]; then
        CLAUDE_DIR="$dir"
        CRED_FILE="$dir/.credentials.json"
        break
    fi
done

# Last resort when no folder was configured: a single ~/.claude* sibling, which
# is what a CLAUDE_CONFIG_DIR multi-account setup looks like. Only when exactly
# one matches, so we never silently guess between accounts.
AMBIGUOUS=""
if [ -z "$CRED_FILE" ] && [ -z "$EXPLICIT" ]; then
    MATCHES=()
    for f in "$HOME"/.claude*/.credentials.json; do
        [ -f "$f" ] && MATCHES+=("$f")
    done
    if [ "${#MATCHES[@]}" -eq 1 ]; then
        CRED_FILE="${MATCHES[0]}"
        CLAUDE_DIR="$(dirname "$CRED_FILE")"
    elif [ "${#MATCHES[@]}" -gt 1 ]; then
        for f in "${MATCHES[@]}"; do
            AMBIGUOUS="${AMBIGUOUS:+$AMBIGUOUS, }$(tildify "$(dirname "$f")")"
        done
    fi
fi

# Cache per Claude folder so several widget instances never show each other's data
FOLDER_KEY="$(printf %s "$CLAUDE_DIR" | cksum | cut -d' ' -f1)"
CACHE_FILE="$HOME/.cache/claudemeter/last_usage_$FOLDER_KEY.json"
export CACHE_FILE

# Activity mode needs only the folder, not a token.
if [ "$MODE" = "activity" ]; then
    stat --format=%Y "$CLAUDE_DIR/history.jsonl" 2>/dev/null || echo 0
    exit 0
fi

# Renew mode never uses the token: the helper looks only at its expiry and
# whether a refresh token exists. CLAUDE_CODE_OAUTH_TOKEN is what the fetch
# below falls back to in the same case, and renewing the file cannot help then.
# The lock and cool-down are per real folder, however the setting spells it.
if [ "$MODE" = "renew" ]; then
    REAL_DIR="$(realpath -m -- "$CLAUDE_DIR" 2>/dev/null)" || REAL_DIR="$CLAUDE_DIR"
    RENEW_KEY="$(printf %s "$REAL_DIR" | cksum | cut -d' ' -f1)"
    RENEW_ARGS=(renew "--folder=$CLAUDE_DIR" "--key=$RENEW_KEY" "--credentials=$CRED_FILE")
    if [ -z "$EXPLICIT" ] && [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        RENEW_ARGS+=(--env-token)
    fi
    if [ -n "$RENEW_NOW" ]; then
        RENEW_ARGS+=(--now)
    fi
    # The widget's proxy reaches Claude Code in its environment only (the
    # helper turns it into https_proxy and the like). Claude Code has no SOCKS
    # support, and starting it without the proxy would go direct, so it is
    # not started at all then.
    unset CLAUDEMETER_PROXY_URL CLAUDEMETER_PROXY_USER CLAUDEMETER_PROXY_PASSWORD
    if [ -n "$PROXY_WANTED" ]; then
        load_proxy
        case "$PROXY_TYPE" in
            http|https)
                export CLAUDEMETER_PROXY_URL="$PROXY_URL"
                export CLAUDEMETER_PROXY_USER="$PROXY_USER"
                export CLAUDEMETER_PROXY_PASSWORD="$PROXY_PASSWORD"
                ;;
            *)
                proxy_error "Claude Code cannot use a SOCKS proxy, so the widget cannot refresh the token. Run claude in a terminal to refresh it, or turn off the automatic refresh."
                ;;
        esac
    fi
    exec python3 -I "$RENEW_HELPER" "${RENEW_ARGS[@]}"
fi

# Only reached if bash gave up on the block above (an expansion error skips a
# whole top-level command): a refresh must never turn into a fetch.
if [ "$MODE" = "renew" ]; then
    if [ -n "$PROXY_WANTED" ]; then
        proxy_error "Could not read this widget's proxy settings, so the token was not refreshed. Open the Proxy page and click Apply, or turn the proxy off."
    fi
    error_json "renew_error" "Could not start the token refresh. Run claude in a terminal to refresh it."
fi

# Extract token and check expiry via python3, reading creds from file (not args)
TOKEN=""
EXPIRED=""
UNREADABLE=""
if [ -n "$CRED_FILE" ]; then
    if ! read -r TOKEN EXPIRED < <(python3 -c "
import json, sys, time
try:
    with open(sys.argv[1]) as f:
        creds = json.load(f)
    oauth = creds['claudeAiOauth']
    token = oauth['accessToken']
    if not token:
        raise ValueError('empty token')
    expires_at = oauth.get('expiresAt', 0)
    now_ms = int(time.time() * 1000)
    expired = '1' if (expires_at and now_ms > expires_at) else '0'
    print(token, expired)
except Exception as e:
    sys.exit(1)
" "$CRED_FILE" 2>/dev/null); then
        TOKEN=""
        EXPIRED=""
        UNREADABLE="1"
    fi
fi

# CLAUDE_CODE_OAUTH_TOKEN is only consulted when the widget was left to find the
# folder itself; an explicit folder means the user named the account they want.
# Note that a token from `claude setup-token` carries the user:inference scope
# only, so it is rejected by this endpoint - see the HTTP 403 branch below.
TOKEN_SOURCE="file"
if [ -z "$TOKEN" ] || [ "$EXPIRED" = "1" ]; then
    if [ -z "$EXPLICIT" ] && [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        TOKEN="$CLAUDE_CODE_OAUTH_TOKEN"
        EXPIRED="0"
        TOKEN_SOURCE="env"
    fi
fi

if [ -z "$TOKEN" ]; then
    if [ -n "$AMBIGUOUS" ]; then
        error_json "no_credentials" "Several accounts found ($AMBIGUOUS) and no way to tell which you want. Set Claude folder in the widget settings to pick one."
    fi
    if [ -n "$UNREADABLE" ]; then
        error_json "parse_error" "Could not read a token from $(tildify "$CRED_FILE"). Sign in again by running claude in a terminal."
    fi
    CHECKED=""
    for dir in "${CANDIDATES[@]}"; do
        CHECKED="${CHECKED:+$CHECKED, }$(tildify "$dir")"
    done
    error_json "no_credentials" "No .credentials.json in $CHECKED. Sign in by running claude in a terminal, or set Claude folder in the widget settings if you use CLAUDE_CONFIG_DIR."
fi

if [ "$EXPIRED" = "1" ]; then
    # Whether Claude Code could renew it, so the widget can offer that. Only
    # reached for a token from the file: an env token never counts as expired.
    TOKEN=""
    RENEW_INFO="$(python3 -I "$RENEW_HELPER" check "--credentials=$CRED_FILE" 2>/dev/null)" \
        || RENEW_INFO='{"possible": false, "reason": "unreadable"}'
    python3 -c "
import json, sys
print(json.dumps({'error': 'token_expired', 'message': sys.argv[1], 'renew': json.loads(sys.argv[2])}))
" "OAuth token has expired. Run claude to refresh." "$RENEW_INFO"
    exit 0
fi

# After the token checks, so an expired token is still reported as such (the
# automatic refresh depends on it) even with a broken proxy setting.
if [ -n "$PROXY_WANTED" ]; then
    load_proxy
fi
# A separate command, so it still runs if bash gave up on the one above (an
# expansion error skips a whole top-level command): never a direct request.
if [ -n "$PROXY_WANTED" ] && [ -z "$PROXY_URL" ]; then
    proxy_error "Could not read this widget's proxy settings. Open the Proxy page and click Apply, or turn the proxy off."
fi

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

if [ "$MODE" = "claim" ]; then
    # Same shapes the server enforces, checked here too because both ids end up
    # in a URL-adjacent JSON body and the widget builds this command line.
    if ! [[ "$GRANT_ID" =~ ^[a-z0-9_-]{1,40}$ ]] || ! [[ "$REQUEST_ID" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
        error_json "claim_error" "Refusing to send a reset with a malformed grant or request id. Nothing was used."
    fi

    # The reset endpoint is per organization. Claude Code keeps the id in its
    # global config: .claude.json next to the default folder, or inside a
    # CLAUDE_CONFIG_DIR one (with the legacy .config.json taking precedence).
    CONFIG_FILES=("$CLAUDE_DIR/.config.json")
    if [ "$CLAUDE_DIR" = "$HOME/.claude" ]; then
        CONFIG_FILES+=("$HOME/.claude.json")
    else
        CONFIG_FILES+=("$CLAUDE_DIR/.claude.json")
    fi
    ORG_UUID="$(python3 -c "
import json, sys
for path in sys.argv[1:]:
    try:
        with open(path) as f:
            org = (json.load(f).get('oauthAccount') or {}).get('organizationUuid')
    except Exception:
        continue
    if org:
        print(org)
        break
" "${CONFIG_FILES[@]}" 2>/dev/null || true)"
    if ! [[ "$ORG_UUID" =~ ^[0-9a-fA-F-]{36}$ ]]; then
        error_json "claim_error" "Could not find your organization in $(tildify "${CONFIG_FILES[-1]}"). Run claude once, then try again. Nothing was used."
    fi

    BODY="$(python3 -c "import json,sys; print(json.dumps({'program':'cedar_ember','grant_id':sys.argv[1],'request_id':sys.argv[2]}))" "$GRANT_ID" "$REQUEST_ID")"
    URL="$API/api/organizations/$ORG_UUID/reset_rate_limits"

    if [ "${CLAUDEMETER_DRY_RUN:-0}" = "1" ]; then
        TOKEN=""
        python3 -c "import json,sys; print(json.dumps({'claim':{'result':'dry_run'},'url':sys.argv[1],'body':json.loads(sys.argv[2]),'user_agent':sys.argv[3]}))" "$URL" "$BODY" "$USER_AGENT"
        exit 0
    fi

    # 25s matches Claude Code. A timeout here does not mean nothing happened:
    # the server may have applied the reset, so it is reported as unconfirmed.
    CURL_RC=0
    CURL_OUT=$(curl_config | \
        curl -s --max-time 25 -o "$TMPFILE" -w '%{http_code} %{http_connect}' \
        -K - \
        -X POST \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Content-Type: application/json" \
        -A "$USER_AGENT" \
        --data-binary "$BODY" \
        "$URL" 2>/dev/null) || CURL_RC=$?
    TOKEN=""
    PROXY_USERPASS=""
    read -r HTTP_CODE CONNECT_CODE _ <<< "$CURL_OUT" || true
    if [ "$CURL_RC" -ne 0 ]; then
        # A proxy that failed before the request went out: nothing was used.
        blame_proxy "$CURL_RC" "${CONNECT_CODE:-}"
        HTTP_CODE="000"
    fi

    python3 -c "
import json, sys
code = sys.argv[1]
out = {'result': 'error', 'http': code}
if code == '429':
    out = {'result': 'rate_limited'}
elif code in ('401', '403'):
    out = {'result': 'auth_error'}
elif code == '200':
    try:
        with open(sys.argv[2]) as f:
            data = json.load(f)
        out = {
            'result': data.get('result') or 'unavailable',
            'reason': data.get('reason'),
            'resets_left': data.get('resets_left'),
            'cleared': data.get('cleared') or [],
            'cooldown_until': data.get('cooldown_until'),
        }
    except Exception:
        pass
json.dump({'claim': out}, sys.stdout)
" "$HTTP_CODE" "$TMPFILE"
    exit 0
fi

# Call usage API - auth header (and proxy) passed via stdin (-K -) to keep the
# token and the proxy password out of /proc/cmdline.
# `cedar_ember=1` adds the reset grants to the response.
CURL_RC=0
CURL_OUT=$(curl_config | \
    curl -s --max-time 10 -o "$TMPFILE" -w '%{http_code} %{http_connect}' \
    -K - \
    -H "anthropic-beta: oauth-2025-04-20" \
    -A "$USER_AGENT" \
    "$API/api/oauth/usage?cedar_ember=1" 2>/dev/null) || CURL_RC=$?

TOKEN=""
PROXY_USERPASS=""
read -r HTTP_CODE CONNECT_CODE _ <<< "$CURL_OUT" || true
if [ "$CURL_RC" -ne 0 ]; then
    blame_proxy "$CURL_RC" "${CONNECT_CODE:-}"
    if [ -n "$PROXY_URL" ]; then
        error_json "network_error" "Failed to reach Anthropic API through the proxy at $PROXY_HOSTPORT"
    fi
    error_json "network_error" "Failed to reach Anthropic API"
fi

if [ "$HTTP_CODE" = "429" ]; then
    if [ -f "$CACHE_FILE" ]; then
        python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    data['cached'] = True
    data['rate_limited'] = True
    json.dump(data, sys.stdout)
except Exception:
    json.dump({'error': 'rate_limited', 'message': 'Rate limited. Cached data is unreadable.'}, sys.stdout)
" "$CACHE_FILE"
        exit 0
    fi
    error_json "rate_limited" "Rate limited. No cached data available."
elif [ "$HTTP_CODE" = "403" ] && [ "$TOKEN_SOURCE" = "env" ]; then
    error_json "api_error" "CLAUDE_CODE_OAUTH_TOKEN was rejected (HTTP 403). A token from claude setup-token can only make model requests, so it cannot read usage. Sign in with claude instead."
elif [ "$HTTP_CODE" != "200" ]; then
    error_json "api_error" "API returned HTTP $HTTP_CODE"
fi

# Validate, cache, and output response - pipe through stdin, never in args
python3 -c "
import json, sys, os, time
try:
    data = json.load(sys.stdin)
    if 'error' in data:
        msg = data.get('error', {})
        if isinstance(msg, dict):
            msg = msg.get('message', str(data))
        json.dump({'error': 'api_error', 'message': str(msg)}, sys.stdout)
    else:
        data['_fetched_at'] = int(time.time())
        cache_file = os.environ['CACHE_FILE']
        os.makedirs(os.path.dirname(cache_file), exist_ok=True)
        with open(cache_file, 'w') as f:
            json.dump(data, f)
        json.dump(data, sys.stdout)
except Exception:
    json.dump({'error': 'parse_error', 'message': 'Invalid JSON from API'}, sys.stdout)
" < "$TMPFILE"
