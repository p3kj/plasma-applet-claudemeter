#!/bin/bash
# Fetch Claude Code usage data from the Anthropic API
# Outputs JSON to stdout. Always exits 0; errors reported as JSON.
#
# Usage: fetch_usage.sh [--activity] [claude-folder]
#   --activity  print the mtime of history.jsonl in the resolved folder (or 0)
#               instead of fetching, so activity polling follows the same
#               folder resolution the fetch does.

set -euo pipefail

MODE="fetch"
if [ "${1:-}" = "--activity" ]; then
    MODE="activity"
    shift
fi

EXPLICIT="${1:-}"
CACHE_FILE="$HOME/.cache/claudemeter/last_usage.json"

error_json() {
    python3 -c "import json,sys; print(json.dumps({'error':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"
    exit 0
}

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

# Activity mode needs only the folder, not a token.
if [ "$MODE" = "activity" ]; then
    stat --format=%Y "$CLAUDE_DIR/history.jsonl" 2>/dev/null || echo 0
    exit 0
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
    error_json "token_expired" "OAuth token has expired. Run claude to refresh."
fi

# Call usage API - auth header passed via stdin (-K -) to avoid token in /proc/cmdline
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

HTTP_CODE=$(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | \
    curl -s --max-time 10 -o "$TMPFILE" -w '%{http_code}' \
    -K - \
    -H "anthropic-beta: oauth-2025-04-20" \
    https://api.anthropic.com/api/oauth/usage 2>/dev/null) || error_json "network_error" "Failed to reach Anthropic API"

TOKEN=""

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
        cache_dir = os.path.expanduser('~/.cache/claudemeter')
        os.makedirs(cache_dir, exist_ok=True)
        with open(os.path.join(cache_dir, 'last_usage.json'), 'w') as f:
            json.dump(data, f)
        json.dump(data, sys.stdout)
except Exception:
    json.dump({'error': 'parse_error', 'message': 'Invalid JSON from API'}, sys.stdout)
" < "$TMPFILE"
