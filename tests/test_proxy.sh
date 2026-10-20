#!/bin/bash
# Tests for the proxy settings: `fetch_usage.sh --proxy-from ...` for a fetch,
# a limit reset and a token refresh. Runs in a throwaway HOME against a stub
# curl and a stub claude, with the widget settings written by the real
# kwriteconfig6, so it never makes a network request and never reads real
# settings, tokens or credentials.
#
# Every command the scripts start goes through a logging shim on PATH, so the
# test can check that no proxy password ever reaches a command line.
#
# Usage: bash tests/test_proxy.sh   (or: just test-proxy)
# Takes a few seconds. Set TMPDIR to put the scratch folder somewhere other than /tmp.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/contents/scripts/fetch_usage.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claudemeter-proxy-test.XXXXXX")"
WORK="$(realpath "$WORK")"
FAKE_HOME="$WORK/home"
STUB_BIN="$WORK/bin"        # stub curl and stub claude
SHIMS="$WORK/shims"         # every other command the scripts run, logged, then run for real
NO_KREAD="$WORK/shims-nokr" # the same without kreadconfig6
LOGS="$WORK/logs"           # per case: .procs (argv of every command), .curl.*, .claude
OUTPUTS="$WORK/outputs"     # every stdout, stderr and exit code the script produced
CONFIG="$FAKE_HOME/.config"
mkdir -p "$FAKE_HOME" "$STUB_BIN" "$SHIMS" "$NO_KREAD" "$LOGS" "$OUTPUTS" "$WORK/tmp" "$CONFIG"
cd "$WORK" || exit 1

cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; if [ -n "${2:-}" ]; then printf '        %s\n' "$2"; fi; }
section() { printf '\n%s\n' "$1"; }

check_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi
}

# A field of a JSON document by dotted path; null when missing.
jget() {
    python3 -c '
import json, sys
d = json.loads(sys.argv[1])
for k in sys.argv[2].split("."):
    d = d.get(k) if isinstance(d, dict) else None
print(d if isinstance(d, str) else json.dumps(d))
' "$1" "$2" 2>/dev/null || echo "<not json>"
}

# --- preflight ---------------------------------------------------------------

section "Preflight"
for tool in kreadconfig6 kwriteconfig6 python3 curl; do
    if ! command -v "$tool" >/dev/null; then
        echo "$tool is needed for this test" >&2
        exit 1
    fi
done
ok "kreadconfig6, kwriteconfig6, python3 and curl are installed"

# --- stubs and shims ---------------------------------------------------------

# Commands fetch_usage.sh, renew_signin.py and the stub claude start. One that
# is missing here fails loudly ("command not found" on stderr, checked below).
# Each logs its arguments to ARGV_LOG and its environment to ARGV_LOG.env.
for tool in python3 kreadconfig6 mktemp cksum cut rm dirname stat realpath ls grep sort tail timeout; do
    real="$(command -v "$tool")"
    cat > "$SHIMS/$tool" <<SHIM
#!/bin/bash
printf '%s\\n' "$tool \$*" >> "\${ARGV_LOG:?}"
for v in \$(compgen -e); do printf '%s %s=%s\\n' "$tool" "\$v" "\${!v}"; done >> "\$ARGV_LOG.env"
exec "$real" "\$@"
SHIM
    chmod +x "$SHIMS/$tool"
    if [ "$tool" != kreadconfig6 ]; then cp "$SHIMS/$tool" "$NO_KREAD/$tool"; fi
done

cat > "$STUB_BIN/curl" <<'STUB'
#!/bin/bash
# Stand-in for curl: saves its arguments, environment and the config it reads
# on stdin (-K -), writes STUB_BODY to the -o file and prints what -w asks for.
printf '%s\n' "$@" > "${CURL_LOG:?}.argv"
for v in $(compgen -e); do printf '%s=%s\n' "$v" "${!v}"; done > "$CURL_LOG.env"
IFS= read -r -d '' config
printf '%s' "$config" > "$CURL_LOG.config"
out=""
prev=""
for a in "$@"; do
    if [ "$prev" = "-o" ]; then out="$a"; fi
    prev="$a"
done
body="${STUB_BODY:-}"
if [ -z "$body" ]; then
    body='{"five_hour": {"utilization": 12, "resets_at": null}}'
fi
if [ -n "$out" ]; then
    printf '%s' "$body" > "$out"
fi
printf '%s %s' "${STUB_HTTP:-200}" "${STUB_CONNECT:-000}"
exit "${STUB_EXIT:-0}"
STUB

cat > "$STUB_BIN/claude" <<'STUB'
#!/bin/bash
# Stand-in for Claude Code: logs the proxy variables it was given, then renews
# the fake credentials as a real refresh would.
{
    for v in https_proxy HTTPS_PROXY http_proxy HTTP_PROXY NO_PROXY no_proxy \
             CLAUDEMETER_PROXY_URL CLAUDEMETER_PROXY_USER CLAUDEMETER_PROXY_PASSWORD; do
        if [ -n "${!v+x}" ]; then echo "$v=${!v}"; else echo "$v=<unset>"; fi
    done
} >> "${STUB_LOG:?}"
folder="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
python3 -I - "$folder/.credentials.json" <<'PY'
import json, sys, time
with open(sys.argv[1]) as f:
    data = json.load(f)
data["claudeAiOauth"]["expiresAt"] = int(time.time() * 1000) + 8 * 3600 * 1000
with open(sys.argv[1], "w") as f:
    json.dump(data, f)
PY
STUB
chmod +x "$STUB_BIN/curl" "$STUB_BIN/claude"

# --- helpers -----------------------------------------------------------------

# creds <folder> <valid|expired>: fake credentials and a fake organization.
creds() {
    mkdir -p "$1"
    python3 -I - "$1" "$2" <<'PY'
import json, os, sys, time
folder, shape = sys.argv[1], sys.argv[2]
hour = 3600 * 1000
expires = int(time.time() * 1000) + (8 * hour if shape == "valid" else -hour)
with open(os.path.join(folder, ".credentials.json"), "w") as f:
    json.dump({"claudeAiOauth": {"accessToken": "fake-access", "refreshToken": "fake-refresh",
                                 "expiresAt": expires, "scopes": ["user:inference", "user:profile"]}}, f)
with open(os.path.join(folder, ".claude.json"), "w") as f:
    json.dump({"oauthAccount": {"organizationUuid": "00000000-0000-4000-8000-000000000000"}}, f)
PY
}

A="$WORK/accounts/a"
creds "$A" valid
# For a run whose arguments end before the folder.
creds "$FAKE_HOME/.claude" valid

APPLETSRC="$CONFIG/plasma-org.kde.plasma.desktop-appletsrc"
APPLET=(--group Containments --group 7 --group Applets --group 42)
GENERAL=("${APPLET[@]}" --group Configuration --group General)
REF="plasmashell:7:42"

# put <file> <key> <value> <group args...>: one setting, escaped as Plasma does.
put() {
    local file="$1" key="$2" value="$3"
    shift 3
    kwriteconfig6 --file "$file" "$@" --key "$key" -- "$value"
}

# proxy [key=value ...]: a fresh settings file in which the test widget has the
# proxy on plus the given keys. Type and port are left out unless given, as
# Plasma does for values at their default.
proxy() {
    rm -f "$CONFIG"/plasma-*-appletsrc
    put "$APPLETSRC" plugin com.github.p3kj.claudemeter "${APPLET[@]}"
    put "$APPLETSRC" proxyEnabled true "${GENERAL[@]}"
    local kv
    for kv in "$@"; do
        put "$APPLETSRC" "${kv%%=*}" "${kv#*=}" "${GENERAL[@]}"
    done
}

# run <label> [VAR=value ...] -- [script args ...]
# fetch_usage.sh in a clean environment whose PATH holds only the stubs and
# the shims (SHIM_DIR picks which shims). Writes $OUTPUTS/<label>.{out,err,rc}.
run() {
    local label="$1"
    shift
    local envs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
        envs+=("$1")
        shift
    done
    shift
    printf 'fetch_usage.sh %s\n' "$*" > "$LOGS/$label.procs"
    timeout -k 5 60 env -i HOME="$FAKE_HOME" PATH="$STUB_BIN:${SHIM_DIR:-$SHIMS}" TMPDIR="$WORK/tmp" \
        ARGV_LOG="$LOGS/$label.procs" CURL_LOG="$LOGS/$label.curl" STUB_LOG="$LOGS/$label.claude" \
        "${envs[@]}" "$BASH" "$SCRIPT" "$@" > "$OUTPUTS/$label.out" 2> "$OUTPUTS/$label.err"
    echo "$?" > "$OUTPUTS/$label.rc"
}

out() { cat "$OUTPUTS/$1.out"; }
err_of() { local d; d="$(out "$1")"; echo "$(jget "$d" error): $(jget "$d" message)"; }

# The proxy part of what curl read on stdin (everything but the token line).
proxy_conf() {
    if [ -f "$LOGS/$1.curl.config" ]; then
        grep -v '^header = "Authorization: Bearer fake-access"$' "$LOGS/$1.curl.config"
    else
        echo "<curl not called>"
    fi
}

curl_called() {
    if [ -f "$LOGS/$1.curl.config" ]; then echo yes; else echo no; fi
}

claude_saw() {
    grep -m1 "^$2=" "$LOGS/$1.claude" 2>/dev/null | cut -d= -f2-
}

# --- proxy off -----------------------------------------------------------------

section "Proxy off: curl reads only the token, and no setting is read"
run off -- -- "$A"
check_eq "fetch: usage comes back" "$(jget "$(out off)" five_hour.utilization)" "12"
check_eq "fetch: config is the token line alone" "$(proxy_conf off)" ""
check_eq "fetch: the token line is there" "$(grep -c '^header = "Authorization: Bearer fake-access"$' "$LOGS/off.curl.config")" "1"
check_eq "fetch: kreadconfig6 never ran" "$(grep -c '^kreadconfig6 ' "$LOGS/off.procs")" "0"
run off-claim -- --claim grant_1 req1 -- "$A"
check_eq "claim: config is the token line alone" "$(proxy_conf off-claim)" ""
run off-down STUB_EXIT=7 STUB_HTTP=000 -- -- "$A"
check_eq "curl failing without a proxy: message unchanged" "$(err_of off-down)" "network_error: Failed to reach Anthropic API"

# --- proxy on ------------------------------------------------------------------

section "Proxy on: the right lines reach curl"
proxy proxyHost=proxy.test proxyPort=3128
run http -- --proxy-from "$REF" -- "$A"
check_eq "http, no user: proxy and noproxy only" "$(proxy_conf http)" $'proxy = "http://proxy.test:3128"\nnoproxy = ""'
check_eq "http, no user: usage comes back" "$(jget "$(out http)" five_hour.utilization)" "12"
check_eq "no proxy option on curl's command line" "$(grep -c -E '^(--proxy|--noproxy|-x|-U)|proxy\.test' "$LOGS/http.curl.argv")" "0"

proxy proxyHost=proxy.test
run defaults -- --proxy-from "$REF" -- "$A"
check_eq "type and port left out: http and 8080" "$(proxy_conf defaults)" $'proxy = "http://proxy.test:8080"\nnoproxy = ""'

proxy proxyType=socks5h proxyHost=proxy.test proxyPort=1080 proxyUser=bob proxyPassword=fake-proxy-secret
run socks -- --proxy-from "$REF" -- "$A"
check_eq "socks5h with a user: proxy-user, no proxy-anyauth" "$(proxy_conf socks)" \
    $'proxy = "socks5h://proxy.test:1080"\nnoproxy = ""\nproxy-user = "bob:fake-proxy-secret"'

proxy proxyType=https proxyHost=proxy.test proxyPort=3129 proxyUser=bob proxyPassword=fake-proxy-secret
run https -- --proxy-from "$REF" -- "$A"
check_eq "https with a user: proxy-anyauth too" "$(proxy_conf https)" \
    $'proxy = "https://proxy.test:3129"\nnoproxy = ""\nproxy-user = "bob:fake-proxy-secret"\nproxy-anyauth'

proxy proxyHost=proxy.test proxyPort=3128 proxyPassword=fake-proxy-secret
run pw-only -- --proxy-from "$REF" -- "$A"
check_eq "a password without a user name is not sent" "$(proxy_conf pw-only)" $'proxy = "http://proxy.test:3128"\nnoproxy = ""'

proxy proxyType=socks5 proxyHost=::1 proxyPort=1080
run ipv6 -- --proxy-from "$REF" -- "$A"
check_eq "IPv6 host gets brackets" "$(proxy_conf ipv6 | head -n 1)" 'proxy = "socks5://[::1]:1080"'
proxy proxyHost='[::1]' proxyPort=3128
run ipv6-brackets -- --proxy-from "$REF" -- "$A"
check_eq "IPv6 host given with brackets" "$(proxy_conf ipv6-brackets | head -n 1)" 'proxy = "http://[::1]:3128"'

for value in yes 1 on; do
    proxy proxyHost=proxy.test
    put "$APPLETSRC" proxyEnabled "$value" "${GENERAL[@]}"
    run "enabled-$value" -- --proxy-from "$REF" -- "$A"
    check_eq "proxyEnabled=$value counts as on, as it does for Plasma" "$(proxy_conf "enabled-$value" | head -n 1)" 'proxy = "http://proxy.test:8080"'
done

proxy proxyHost='  proxy.test ' proxyPort=3128 proxyUser=' bob '
run spaces -- --proxy-from "$REF" -- "$A"
check_eq "spaces around host and user are trimmed" "$(proxy_conf spaces)" \
    $'proxy = "http://proxy.test:3128"\nnoproxy = ""\nproxy-user = "bob:"\nproxy-anyauth'

rm -f "$CONFIG"/plasma-*-appletsrc
mkdir -p "$WORK/xdg"
put "$WORK/xdg/plasma-org.kde.plasma.desktop-appletsrc" proxyEnabled true "${GENERAL[@]}"
put "$WORK/xdg/plasma-org.kde.plasma.desktop-appletsrc" proxyHost xdg.test "${GENERAL[@]}"
run xdg XDG_CONFIG_HOME="$WORK/xdg" -- --proxy-from "$REF" -- "$A"
check_eq "XDG_CONFIG_HOME is where the settings are read" "$(proxy_conf xdg | head -n 1)" 'proxy = "http://xdg.test:8080"'

WINDOWED="$CONFIG/plasmawindowedrc"
put "$WINDOWED" plugin com.github.p3kj.claudemeter --group Applets --group 3
put "$WINDOWED" proxyEnabled true --group Applets --group 3 --group Configuration --group General
put "$WINDOWED" proxyHost windowed.test --group Applets --group 3 --group Configuration --group General
run windowed -- --proxy-from plasmawindowed:2:3 -- "$A"
check_eq "plasmawindowed reads plasmawindowedrc" "$(proxy_conf windowed | head -n 1)" 'proxy = "http://windowed.test:8080"'

# --- escaping ------------------------------------------------------------------

section "Escaping: a password stays one value"
proxy proxyHost=proxy.test proxyPort=3128 proxyUser=bob 'proxyPassword=fake-proxy-secret"q\b'
run quote -- --proxy-from "$REF" -- "$A"
check_eq "quote and backslash are escaped" "$(grep '^proxy-user' "$LOGS/quote.curl.config")" \
    'proxy-user = "bob:fake-proxy-secret\"q\\b"'

proxy proxyHost=proxy.test proxyPort=3128 proxyUser=bob 'proxyPassword=fake-proxy-secret" -o "/nope'
run inject -- --proxy-from "$REF" -- "$A"
check_eq "an injection attempt is one proxy-user line" "$(grep -c '^proxy-user' "$LOGS/inject.curl.config")" "1"
check_eq "and adds no other line" "$(proxy_conf inject | wc -l)" "4"
# The real curl, told to only print the options it would set, is the judge.
if libcurl="$(curl -s -K - --libcurl - -o /dev/null file:///dev/null < "$LOGS/inject.curl.config" 2>/dev/null)"; then
    check_eq "real curl: one CURLOPT_PROXYUSERPWD, with the whole password" \
        "$(grep 'CURLOPT_PROXYUSERPWD' <<< "$libcurl" | sed 's/^ *//')" \
        'curl_easy_setopt(curl, CURLOPT_PROXYUSERPWD, "bob:fake-proxy-secret\" -o \"/nope");'
    check_eq "real curl: the proxy is unchanged" "$(grep 'CURLOPT_PROXY,' <<< "$libcurl" | sed 's/^ *//')" \
        'curl_easy_setopt(curl, CURLOPT_PROXY, "http://proxy.test:3128");'
    check_eq "real curl: no output file option sneaked in" "$(grep -c '/nope"' <<< "$libcurl")" "1"
else
    ok "real curl has no --libcurl here, skipped its check"
fi

proxy proxyHost=proxy.test proxyPort=3128 proxyUser=bob 'proxyPassword= fake-proxy-secret = # [x] é'
run kconfig -- --proxy-from "$REF" -- "$A"
check_eq "leading space, = # [ and non-ASCII survive Plasma's escaping" "$(grep '^proxy-user' "$LOGS/kconfig.curl.config")" \
    'proxy-user = "bob: fake-proxy-secret = # [x] é"'

proxy proxyHost=proxy.test proxyPort=3128 proxyUser=bob $'proxyPassword=fake-proxy-secret\tx'
run tab -- --proxy-from "$REF" -- "$A"
check_eq "a tab in the password is refused" "$(jget "$(out tab)" error)" "proxy_error"
check_eq "and curl never ran" "$(curl_called tab)" "no"
proxy proxyHost=proxy.test proxyPort=3128 proxyUser=bob $'proxyPassword=fake-proxy-secret\nproxy = "http://evil.test"'
run newline LC_ALL=C.UTF-8 -- --proxy-from "$REF" -- "$A"
check_eq "a line break in the password is refused (UTF-8 locale)" "$(jget "$(out newline)" error)" "proxy_error"
check_eq "and curl never ran" "$(curl_called newline)" "no"

# --- refused settings ----------------------------------------------------------

section "Settings that are refused, never sent direct"
refused() {
    local label="$1"
    shift
    run "$label" "$@"
    if [ "$(jget "$(out "$label")" error)" = "proxy_error" ] && [ "$(curl_called "$label")" = "no" ]; then
        ok "$label: proxy_error, curl not called"
    else
        bad "$label: proxy_error, curl not called" "$(out "$label"), curl called: $(curl_called "$label")"
    fi
}

proxy proxyPort=3128
refused no-host -- --proxy-from "$REF" -- "$A"
check_eq "no host: says so" "$(jget "$(out no-host)" message)" "The proxy is on, but has no host. Set one on the Proxy page, or turn the proxy off."
proxy proxyType=ftp proxyHost=proxy.test
refused bad-type -- --proxy-from "$REF" -- "$A"
n=0
for host in 'bob@proxy.test' 'proxy.test/x' 'proxy test' '-proxy.test' '.proxy.test' 'g::1' 'fe80::1%eth0'; do
    n=$((n + 1))
    proxy "proxyHost=$host"
    refused "host-$n" -- --proxy-from "$REF" -- "$A"
done
check_eq "a bad host is not repeated in the message" "$(jget "$(out host-1)" message)" \
    "The proxy host on the Proxy page is not a host name or an IP address."
for port in 0 70000 abc; do
    proxy proxyHost=proxy.test "proxyPort=$port"
    refused "port $port" -- --proxy-from "$REF" -- "$A"
done
proxy proxyHost=proxy.test proxyUser=bob:x proxyPassword=fake-proxy-secret
refused user-colon -- --proxy-from "$REF" -- "$A"

proxy proxyHost=proxy.test
n=0
for ref in plasmashell:7 x:y:42 'a b:7:42' 'plasmashell:7:42:1' '' '--'; do
    n=$((n + 1))
    refused "ref-$n" -- --proxy-from "$ref" -- "$A"
done
refused ref-missing -- --proxy-from
refused ref-wrong-applet -- --proxy-from plasmashell:7:43 -- "$A"

# A flag after the folder must never be dropped quietly (the request would go
# direct), while every command line the widget builds keeps working.
n=0
for args in "-- $A --proxy-from $REF" "$A --proxy-from $REF" "-- $A extra"; do
    n=$((n + 1))
    read -r -a argv <<< "$args"
    run "trailing-$n" -- "${argv[@]}"
    check_eq "'${args//$WORK/WORK}': refused" "$(jget "$(out "trailing-$n")" error) $(curl_called "trailing-$n")" "bad_arguments no"
done
run widget-default -- --
check_eq "the widget's own '--' with no folder still fetches" "$(jget "$(out widget-default)" five_hour.utilization)" "12"
run widget-activity -- --activity -- "$A"
check_eq "the widget's activity check still answers" "$(out widget-activity)" "0"

proxy proxyHost=proxy.test
put "$APPLETSRC" proxyEnabled false "${GENERAL[@]}"
refused disabled-on-disk -- --proxy-from "$REF" -- "$A"
proxy proxyHost=proxy.test
cp "$APPLETSRC" "$CONFIG/plasma-org.kde.plasma.mobileshell-appletsrc"
refused two-shells -- --proxy-from "$REF" -- "$A"

proxy proxyHost=proxy.test
SHIM_DIR="$NO_KREAD" refused no-kreadconfig6 -- --proxy-from "$REF" -- "$A"
check_eq "no kreadconfig6: says what is missing" "$(jget "$(out no-kreadconfig6)" message | grep -c kreadconfig6)" "1"

# Plasma runs the script in the desktop's locale. In a UTF-8 one, bash's [0-9]
# also matches other scripts' digits, which once let a port such as ٣١٢٨ past
# the check and into an arithmetic error that skipped the proxy altogether.
UTF8_LOCALE=""
for loc in cs_CZ en_US; do
    if locale -a 2>/dev/null | grep -q -i -x "$loc\.utf-\?8"; then
        UTF8_LOCALE="$loc.UTF-8"
        break
    fi
done
if [ -n "$UTF8_LOCALE" ]; then
    U="$WORK/accounts/utf8"
    for port in '٣١٢٨' '８０８０'; do
        proxy proxyHost=proxy.test "proxyPort=$port"
        refused "utf8 fetch, port $port" LANG="$UTF8_LOCALE" -- --proxy-from "$REF" -- "$A"
        refused "utf8 claim, port $port" LANG="$UTF8_LOCALE" -- --claim grant_1 req1 --proxy-from "$REF" -- "$A"
        creds "$U" expired
        refused "utf8 renew, port $port" LANG="$UTF8_LOCALE" -- --renew --now --proxy-from "$REF" -- "$U"
        check_eq "utf8 renew, port $port: claude never started" "$([ -f "$LOGS/utf8 renew, port $port.claude" ] && echo started || echo no)" "no"
    done
else
    ok "no cs_CZ.UTF-8 or en_US.UTF-8 locale installed, skipped the UTF-8 digit cases"
fi

# An expired token is still reported as such, so the refresh can kick in.
E="$WORK/accounts/expired"
creds "$E" expired
proxy proxyType=ftp proxyHost=proxy.test
run expired-bad-proxy -- --proxy-from "$REF" -- "$E"
check_eq "expired token comes before a proxy error" "$(jget "$(out expired-bad-proxy)" error)" "token_expired"

# --- the limit reset -------------------------------------------------------------

section "The limit reset goes through the proxy too"
proxy proxyHost=proxy.test proxyPort=3128 proxyUser=bob proxyPassword=fake-proxy-secret
run claim STUB_BODY='{"result": "reset", "resets_left": 1}' -- --claim grant_1 req1 --proxy-from "$REF" -- "$A"
check_eq "claim: proxy lines reach curl" "$(proxy_conf claim)" \
    $'proxy = "http://proxy.test:3128"\nnoproxy = ""\nproxy-user = "bob:fake-proxy-secret"\nproxy-anyauth'
check_eq "claim: result comes back" "$(jget "$(out claim)" claim.result)" "reset"
run claim-down STUB_EXIT=7 STUB_HTTP=000 -- --claim grant_1 req1 --proxy-from "$REF" -- "$A"
check_eq "claim, proxy unreachable: proxy_error, nothing used" "$(err_of claim-down)" \
    "proxy_error: Could not connect to the proxy at proxy.test:3128. Nothing was used."
run claim-timeout STUB_EXIT=28 STUB_HTTP=000 STUB_CONNECT=200 -- --claim grant_1 req1 --proxy-from "$REF" -- "$A"
check_eq "claim, timeout past the proxy: unconfirmed, as without one" \
    "$(jget "$(out claim-timeout)" claim.result) $(jget "$(out claim-timeout)" claim.http)" "error 000"

# --- failures ------------------------------------------------------------------

section "Failures name the proxy when it is the problem"
proxy proxyHost=proxy.test proxyPort=3128
run fail-5 STUB_EXIT=5 STUB_HTTP=000 -- --proxy-from "$REF" -- "$A"
check_eq "exit 5" "$(err_of fail-5)" "proxy_error: Could not find the proxy host proxy.test."
run fail-7 STUB_EXIT=7 STUB_HTTP=000 -- --proxy-from "$REF" -- "$A"
check_eq "exit 7" "$(err_of fail-7)" "proxy_error: Could not connect to the proxy at proxy.test:3128."
run fail-97 STUB_EXIT=97 STUB_HTTP=000 -- --proxy-from "$REF" -- "$A"
check_eq "exit 97" "$(err_of fail-97)" "proxy_error: The proxy at proxy.test:3128 refused the connection. Check its type, user name and password."
run fail-35 STUB_EXIT=35 STUB_HTTP=000 -- --proxy-from "$REF" -- "$A"
check_eq "exit 35" "$(err_of fail-35)" "proxy_error: Could not set up a secure connection to the proxy at proxy.test:3128. If it is a plain HTTP proxy, pick HTTP as the type."
run fail-60 STUB_EXIT=60 STUB_HTTP=000 STUB_CONNECT=200 -- --proxy-from "$REF" -- "$A"
check_eq "exit 60" "$(err_of fail-60)" "proxy_error: The certificate check failed behind the proxy at proxy.test:3128. If the proxy inspects TLS, add its CA certificate to the system store."
run claim-35 STUB_EXIT=35 STUB_HTTP=000 -- --claim grant_1 req1 --proxy-from "$REF" -- "$A"
check_eq "exit 35 for a reset: nothing used" "$(err_of claim-35)" "proxy_error: Could not set up a secure connection to the proxy at proxy.test:3128. If it is a plain HTTP proxy, pick HTTP as the type. Nothing was used."
# An address the loose check lets through but curl rejects.
proxy proxyHost=dead:beef proxyPort=3128
run fail-3 STUB_EXIT=3 STUB_HTTP=000 -- --proxy-from "$REF" -- "$A"
check_eq "exit 3" "$(err_of fail-3)" "proxy_error: The proxy address [dead:beef]:3128 is not valid."
proxy proxyHost=proxy.test proxyPort=3128
run fail-407 STUB_EXIT=56 STUB_HTTP=000 STUB_CONNECT=407 -- --proxy-from "$REF" -- "$A"
check_eq "CONNECT 407" "$(err_of fail-407)" "proxy_error: The proxy at proxy.test:3128 wants a user name and password, or did not accept the ones on the Proxy page."
run fail-403 STUB_EXIT=56 STUB_HTTP=000 STUB_CONNECT=403 -- --proxy-from "$REF" -- "$A"
check_eq "CONNECT 403" "$(err_of fail-403)" "proxy_error: The proxy at proxy.test:3128 refused the connection (HTTP 403)."
# What curl 8.23 itself returns for a refused CONNECT: exit 7 with the reply code.
run fail-7-407 STUB_EXIT=7 STUB_HTTP=000 STUB_CONNECT=407 -- --proxy-from "$REF" -- "$A"
check_eq "exit 7 with CONNECT 407" "$(err_of fail-7-407)" "proxy_error: The proxy at proxy.test:3128 wants a user name and password, or did not accept the ones on the Proxy page."
run fail-7-403 STUB_EXIT=7 STUB_HTTP=000 STUB_CONNECT=403 -- --proxy-from "$REF" -- "$A"
check_eq "exit 7 with CONNECT 403" "$(err_of fail-7-403)" "proxy_error: The proxy at proxy.test:3128 refused the connection (HTTP 403)."
run fail-28 STUB_EXIT=28 STUB_HTTP=000 STUB_CONNECT=200 -- --proxy-from "$REF" -- "$A"
check_eq "timeout past the proxy" "$(err_of fail-28)" "network_error: Failed to reach Anthropic API through the proxy at proxy.test:3128"
run api-401 STUB_HTTP=401 STUB_CONNECT=200 STUB_BODY='{}' -- --proxy-from "$REF" -- "$A"
check_eq "an API error through the proxy is still an API error" "$(err_of api-401)" "api_error: API returned HTTP 401"

# --- the token refresh -----------------------------------------------------------

section "The token refresh gets an HTTP(S) proxy in its environment"
R="$WORK/accounts/renew"
creds "$R" expired
proxy proxyHost=proxy.test proxyPort=3128 proxyUser=bob 'proxyPassword=fake-proxy-secret"q\b'
run renew-http NO_PROXY=anthropic.com no_proxy=anthropic.com HTTPS_PROXY=http://session.invalid:1 \
    -- --renew --now --proxy-from "$REF" -- "$R"
check_eq "renewed" "$(jget "$(out renew-http)" renew.result)" "renewed"
want='http://bob:fake-proxy-secret%22q%5Cb@proxy.test:3128'
for v in https_proxy HTTPS_PROXY http_proxy HTTP_PROXY; do
    check_eq "claude saw $v" "$(claude_saw renew-http "$v")" "$want"
done
check_eq "NO_PROXY and no_proxy dropped" "$(claude_saw renew-http NO_PROXY) $(claude_saw renew-http no_proxy)" "<unset> <unset>"
check_eq "no CLAUDEMETER_ variable reached claude" \
    "$(grep -c '^CLAUDEMETER_PROXY_[A-Z]*=<unset>$' "$LOGS/renew-http.claude")" "3"

for type in socks5 socks5h; do
    creds "$R" expired
    proxy "proxyType=$type" proxyHost=proxy.test proxyUser=bob proxyPassword=fake-proxy-secret
    run "renew-$type" HTTPS_PROXY=http://session.invalid:1 -- --renew --now --proxy-from "$REF" -- "$R"
    check_eq "$type: no refresh, since Claude Code would go around the proxy" "$(err_of "renew-$type")" \
        "proxy_error: Claude Code cannot use a SOCKS proxy, so the widget cannot refresh the token. Run claude in a terminal to refresh it, or turn off the automatic refresh."
    check_eq "$type: claude never started" "$([ -f "$LOGS/renew-$type.claude" ] && echo started || echo no)" "no"
done

creds "$R" expired
run renew-stray CLAUDEMETER_PROXY_URL=http://stray.invalid:1 CLAUDEMETER_PROXY_USER=x -- --renew --now -- "$R"
check_eq "no --proxy-from: a stray CLAUDEMETER_PROXY_URL never reaches claude" \
    "$(claude_saw renew-stray CLAUDEMETER_PROXY_URL) $(claude_saw renew-stray https_proxy)" "<unset> <unset>"

creds "$R" expired
proxy proxyType=ftp proxyHost=proxy.test
run renew-bad -- --renew --now --proxy-from "$REF" -- "$R"
check_eq "a broken proxy setting stops the refresh before claude starts" \
    "$(jget "$(out renew-bad)" error) $([ -f "$LOGS/renew-bad.claude" ] && echo started || echo not-started)" "proxy_error not-started"

# --- leaks ---------------------------------------------------------------------

section "Nothing leaks"
# fake-proxy-secret is part of every test password, also once percent-encoded.
leaks="$(grep -l 'fake-proxy-secret' "$LOGS"/*.procs "$LOGS"/*.argv "$OUTPUTS"/* 2>/dev/null)"
if [ -z "$leaks" ]; then ok "no proxy password on any command line, stdout or stderr"; else bad "no proxy password on any command line, stdout or stderr" "$leaks"; fi
leaks="$(grep -l 'fake-access' "$LOGS"/*.procs "$LOGS"/*.argv 2>/dev/null)"
if [ -z "$leaks" ]; then ok "no token on any command line"; else bad "no token on any command line" "$leaks"; fi
# Only a refresh hands the proxy on in the environment, to the helper and on
# to Claude Code; in a fetch or a reset, no process gets it that way.
leaks="$(grep -l 'fake-proxy-secret' "$LOGS"/*.env 2>/dev/null | grep -v '/renew-[^/]*$')"
if [ -z "$leaks" ]; then ok "no proxy password in the environment of curl or python3 outside a refresh"; else bad "no proxy password in the environment of curl or python3 outside a refresh" "$leaks"; fi
leaks="$(grep -l 'fake-access' "$LOGS"/*.env 2>/dev/null)"
if [ -z "$leaks" ]; then ok "no token in any environment"; else bad "no token in any environment" "$leaks"; fi
check_eq "the check is not vacuous: environments were logged" \
    "$(grep -c '^python3 HOME=' "$LOGS/claim.procs.env" | grep -c -v '^0$') $(grep -c '^HOME=' "$LOGS/claim.curl.env")" "1 1"
check_eq "and the refresh's helper did get the proxy" "$(grep -c '^python3 CLAUDEMETER_PROXY_PASSWORD=fake-proxy-secret' "$LOGS/renew-http.procs.env")" "1"
check_eq "the check is not vacuous: kreadconfig6 ran" "$(grep -c '^kreadconfig6 .*--key proxyPassword' "$LOGS/quote.procs")" "1"
check_eq "the check is not vacuous: the helper and timeout ran" \
    "$(grep -c '^python3 -I .*renew_signin.py renew ' "$LOGS/renew-http.procs") $(grep -c '^timeout ' "$LOGS/renew-http.procs")" "1 1"
stderr_bytes="$(cat "$OUTPUTS"/*.err | wc -c)"
check_eq "nothing on stderr" "$stderr_bytes" "0"
if [ "$stderr_bytes" != 0 ]; then head -c 2000 "$OUTPUTS"/*.err; fi
nonzero=""
for rc in "$OUTPUTS"/*.rc; do
    if [ "$(cat "$rc")" != "0" ]; then nonzero="$nonzero $(basename "$rc" .rc)=$(cat "$rc")"; fi
done
check_eq "every run exited 0" "${nonzero:-none}" "none"
not_json=""
for o in "$OUTPUTS"/*.out; do
    python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$o" 2>/dev/null || not_json="$not_json $(basename "$o" .out)"
done
check_eq "every output is JSON" "${not_json:-none}" "none"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
