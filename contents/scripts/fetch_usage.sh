#!/bin/bash
# Fetch Claude Code usage data from the Anthropic API
# Outputs JSON to stdout. Always exits 0; errors reported as JSON.

set -euo pipefail

# Optional first arg: custom Claude folder path (e.g. ~/.claude-personal)
CLAUDE_DIR="${1:-$HOME/.claude}"
# Expand leading ~ in case user typed it literally
CLAUDE_DIR="${CLAUDE_DIR/#\~/$HOME}"

CRED_FILE="$CLAUDE_DIR/.credentials.json"
CACHE_FILE="$HOME/.cache/claudemeter/last_usage.json"

error_json() {
    python3 -c "import json,sys; print(json.dumps({'error':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"
    exit 0
}

# Check credentials file exists
if [ ! -f "$CRED_FILE" ]; then
    error_json "no_credentials" "Credentials file not found"
fi

# Extract token and check expiry via python3, reading creds from file (not args)
read -r TOKEN EXPIRED < <(python3 -c "
import json, sys, time
try:
    with open(sys.argv[1]) as f:
        creds = json.load(f)
    oauth = creds['claudeAiOauth']
    token = oauth['accessToken']
    expires_at = oauth.get('expiresAt', 0)
    now_ms = int(time.time() * 1000)
    expired = '1' if (expires_at and now_ms > expires_at) else '0'
    print(token, expired)
except Exception as e:
    sys.exit(1)
" "$CRED_FILE" 2>/dev/null) || error_json "parse_error" "Failed to parse credentials file"

if [ "$EXPIRED" = "1" ]; then
    error_json "token_expired" "OAuth token has expired. Run claude to refresh."
fi

# Call usage API - auth header (and optional proxy) passed via stdin (-K -)
# to keep the token and proxy password off curl's command line.
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

PROXY="${CM_PROXY:-}"
PROXY_USER="${CM_PROXY_USER:-}"

build_curl_config() {
    printf 'header = "Authorization: Bearer %s"\n' "$TOKEN"
    if [ -n "$PROXY" ]; then
        printf 'proxy = "%s"\n' "$PROXY"
    fi
    if [ -n "$PROXY_USER" ]; then
        printf 'proxy-user = "%s"\n' "$PROXY_USER"
    fi
}

HTTP_CODE=$(build_curl_config | \
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
    sys.exit(0)
except Exception:
    pass" "$CACHE_FILE" && exit 0
    fi
    error_json "rate_limited" "Rate limited. No cached data available."
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
