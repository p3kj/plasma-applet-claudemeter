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

# Extract token and expiry info via python3, reading creds from file (not args)
# Returns: TOKEN EXPIRED EXPIRES_AT NOW_MS (space-separated)
read -r TOKEN EXPIRED EXPIRES_AT NOW_MS < <(python3 -c "
import json, sys, time
try:
    with open(sys.argv[1]) as f:
        creds = json.load(f)
    oauth = creds['claudeAiOauth']
    token = oauth['accessToken']
    expires_at = oauth.get('expiresAt', 0)
    now_ms = int(time.time() * 1000)
    expired = '1' if (expires_at and now_ms > expires_at) else '0'
    print(token, expired, expires_at, now_ms)
except Exception as e:
    sys.exit(1)
" "$CRED_FILE" 2>/dev/null) || error_json "parse_error" "Failed to parse credentials file"

# Auto-refresh: if token is expired or within 1 hour of expiry, try refreshing via claude auth status
if [ "$EXPIRED" = "1" ] || { [ "$EXPIRES_AT" -ne 0 ] && [ $((EXPIRES_AT - NOW_MS)) -lt 3600000 ] 2>/dev/null; }; then
    CLAUDE_BIN="$(command -v claude 2>/dev/null)"
    if [ -z "$CLAUDE_BIN" ]; then
        CLAUDE_BIN="$HOME/.local/bin/claude"
    fi
    if [ -x "$CLAUDE_BIN" ]; then
        # Run claude auth status to trigger OAuth token refresh (handled internally by Claude Code)
        timeout 15 "$CLAUDE_BIN" auth status --json >/dev/null 2>&1 || true
        # Re-read credentials after potential refresh
        read -r TOKEN EXPIRED _ < <(python3 -c "
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
except Exception:
    sys.exit(1)
" "$CRED_FILE" 2>/dev/null) || error_json "refresh_failed" "Token refresh failed. Try running 'claude auth login' to re-authenticate."
    fi
fi

if [ "$EXPIRED" = "1" ]; then
    error_json "token_expired" "OAuth token has expired and could not be refreshed. Run 'claude auth login' to re-authenticate."
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
