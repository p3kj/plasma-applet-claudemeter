#!/usr/bin/env python3
"""Let Claude Code renew its own expired sign-in, for fetch_usage.sh.

The widget never calls the OAuth token endpoint itself: refresh tokens rotate,
and writing a new pair back would race a running Claude Code and could sign it
out. Instead it starts Claude Code for a moment, which renews its own file.

    renew_signin.py check --credentials=FILE
        Print {"possible": bool, "reason": str|null} for a token already known
        to be expired. fetch_usage.sh adds it to its token_expired error.

    renew_signin.py renew --folder=DIR --key=KEY [--credentials=FILE]
                          [--env-token] [--now]
        Print {"renew": {"result": ..., "reason": ..., "next_try": ...,
        "last_try": ...}}. result is one of renewed, not_renewed, busy,
        cooldown, not_possible, not_installed, timeout, workdir_not_empty or
        error. KEY names the lock and state files (fetch_usage.sh derives it
        from the folder's real path).

Of the credentials file it only looks at expiresAt, whether refreshToken is
set, and refreshTokenExpiresAt. No token value is used, printed, logged or
passed on, and Claude Code's own output is discarded.

The widget's own HTTP(S) proxy, password included, arrives in the environment
(CLAUDEMETER_PROXY_*) and reaches Claude Code the same way, never on a
command line.

Always prints JSON and exits 0; problems are reported in the JSON.
"""

import argparse
import fcntl
import json
import math
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
from urllib.parse import quote

# Automatic tries: at most one per 30 minutes, doubling after every try in a
# row that did not renew, up to a day. A click ("--now") skips the wait.
BASE_COOLDOWN_S = 30 * 60
MAX_COOLDOWN_S = 24 * 60 * 60
TIMEOUT_S = 30
# At the deadline, extra time while Claude Code's refresh lock is fresh:
# stopping it halfway through a refresh could lose the rotated refresh token.
REFRESH_GRACE_S = 15
KILL_GRACE_S = 5
# coreutils timeout around Claude Code. It only matters if this script dies
# first (Plasma SIGKILLs it when the widget goes away mid-run, and then no
# cleanup here runs): it still stops Claude Code. Kept past this script's own
# worst case of 30 + 15 + 5 s, so normally it never acts.
OUTER_TIMEOUT_S = 60
OUTER_KILL_S = 5
# Claude Code holds this while it refreshes, and keeps touching it while it does.
CLAUDE_LOCK_NAME = ".oauth_refresh.lock"
CLAUDE_LOCK_FRESH_S = 60

# Tested against Claude Code 2.1.296: renews an expired token in about a second
# and exits, without a prompt, a model request, a transcript or a history entry.
# --init-only runs startup only, --safe-mode turns off CLAUDE.md, skills,
# plugins, hooks and MCP, --strict-mcp-config ignores every MCP config file.
# Never --bare (it does not read OAuth) and never -p (it would spend usage).
CLAUDE_FLAGS = ("--init-only", "--safe-mode", "--strict-mcp-config")
EXTRA_ENV = {
    "DISABLE_AUTOUPDATER": "1",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "CLAUDE_CODE_SKIP_PROMPT_HISTORY": "1",
}
# Names checked against the Claude Code 2.1.296 binary.
SCRUBBED_ENV = (
    # Other credentials, or another provider, would make Claude Code skip the
    # file it is meant to renew, or refresh with a token that is not the file's.
    "CLAUDE_CODE_OAUTH_TOKEN",
    "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
    "CLAUDE_CODE_OAUTH_REFRESH_TOKEN",
    "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR",
    "CLAUDE_CODE_GATEWAY_TOKEN_FILE_DESCRIPTOR",
    "CLAUDE_CODE_WEBSOCKET_AUTH_FILE_DESCRIPTOR",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_AWS_API_KEY",
    "ANTHROPIC_FOUNDRY_API_KEY",
    "ANTHROPIC_FOUNDRY_AUTH_TOKEN",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "CLAUDE_CODE_USE_FOUNDRY",
    "CLAUDE_CODE_USE_GATEWAY",
    "CLAUDE_CODE_USE_MANTLE",
    # A host that refreshes for it, or no refresh lock: neither is true here.
    "CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH",
    "CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH",
    "CLAUDE_CODE_DISABLE_AUTH_REFRESH_LOCK",
    # Markers that would make it think it runs inside another session.
    "CLAUDECODE",
    "CLAUDE_CODE_ENTRYPOINT",
    "CLAUDE_CODE_CHILD_SESSION",
)
# The proxy set on the widget's Proxy page, from fetch_usage.sh. Claude Code
# uses the first of PROXY_OUT that is set, so all of them are set to it.
PROXY_IN = ("CLAUDEMETER_PROXY_URL", "CLAUDEMETER_PROXY_USER", "CLAUDEMETER_PROXY_PASSWORD")
PROXY_OUT = ("https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY")
STOP_SIGNALS = (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)


class Stopped(BaseException):
    """A signal asked this script to stop; unwinds through the cleanup."""


def now_ms():
    return int(time.time() * 1000)


def number(value):
    """value if it is a finite JSON number (not a bool), else None."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if isinstance(value, float) and not math.isfinite(value):
        return None
    return value


def read_state(path):
    """(expires_at, has_refresh, refresh_expires_at), or None if unreadable."""
    try:
        with open(path, encoding="utf-8") as f:
            oauth = json.load(f)["claudeAiOauth"]
        refresh = oauth.get("refreshToken")
        return (
            number(oauth.get("expiresAt")),
            isinstance(refresh, str) and refresh != "",
            number(oauth.get("refreshTokenExpiresAt")),
        )
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None


def renewability(state):
    """(possible, reason) for credentials as returned by read_state."""
    if state is None:
        return False, "unreadable"
    expires_at, has_refresh, refresh_expires_at = state
    if not has_refresh:
        return False, "no_refresh_token"
    if expires_at is None or expires_at <= 0:
        return False, "no_expiry"
    current = now_ms()
    if expires_at > current:
        return False, "not_expired"
    if refresh_expires_at is not None and refresh_expires_at <= current:
        return False, "refresh_token_expired"
    return True, None


def read_state_settled(path):
    """read_state, retried briefly in case Claude Code is mid-write."""
    for _ in range(5):
        state = read_state(path)
        if state is not None:
            return state
        time.sleep(0.2)
    return None


def home():
    return os.path.expanduser("~")


def find_claude():
    found = shutil.which("claude")
    if found:
        # Absolute, since it is started from another folder.
        return os.path.abspath(found)
    # plasmashell's PATH often lacks ~/.local/bin, where the native installer puts it.
    fallback = os.path.join(home(), ".local", "bin", "claude")
    if os.path.isfile(fallback) and os.access(fallback, os.X_OK):
        return fallback
    return None


def same_folder(a, b):
    return os.path.realpath(a) == os.path.realpath(b)


def claude_refreshing(folder):
    try:
        age = time.time() - os.stat(os.path.join(folder, CLAUDE_LOCK_NAME)).st_mtime
    except OSError:
        return False
    return age < CLAUDE_LOCK_FRESH_S


def cooldown_s(failures):
    return min(BASE_COOLDOWN_S * 2 ** min(failures, 16), MAX_COOLDOWN_S)


def read_tries(path):
    """(last_try, failures) from the state file, or (None, 0)."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        last = data.get("last_try")
        failures = data.get("failures", 0)
    except (OSError, ValueError, AttributeError):
        return None, 0
    if isinstance(last, bool) or not isinstance(last, int):
        return None, 0
    if isinstance(failures, bool) or not isinstance(failures, int) or failures < 0:
        failures = 0
    # One from the future (the clock was set back) would block renewal for as
    # long as the clock is off, so it is ignored instead.
    if last > time.time() + 60:
        return None, 0
    return last, failures


def write_tries(path, last, failures):
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_CLOEXEC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump({"last_try": last, "failures": failures}, f)
    os.replace(tmp, path)


def group_alive(proc):
    """Whether anything is left in the child's process group. Reaps the leader."""
    proc.poll()
    try:
        os.killpg(proc.pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def signal_group(proc, sig):
    try:
        os.killpg(proc.pid, sig)
    except (ProcessLookupError, PermissionError):
        pass


def stop_group(proc):
    """TERM whatever is left of the child's group, KILL it after a grace period, reap."""
    if group_alive(proc):
        signal_group(proc, signal.SIGTERM)
        deadline = time.monotonic() + KILL_GRACE_S
        while time.monotonic() < deadline and group_alive(proc):
            time.sleep(0.05)
        if group_alive(proc):
            signal_group(proc, signal.SIGKILL)
    proc.wait()
    # Orphaned grandchildren are reaped by init; give it a moment so nothing
    # outlives this script.
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline and group_alive(proc):
        time.sleep(0.05)


def child_env(folder):
    env = dict(os.environ)
    for name in SCRUBBED_ENV:
        env.pop(name, None)
    env.update(EXTRA_ENV)
    inherited = env.get("CLAUDE_CONFIG_DIR", "")
    if inherited and same_folder(os.path.expanduser(inherited), folder):
        # Already names this folder (a session-wide setting): kept, so Claude
        # Code uses the same .claude.json as the user's own sessions. A literal
        # ~ (environment.d does not expand it) is expanded, or Claude Code would
        # resolve it inside the work folder.
        env["CLAUDE_CONFIG_DIR"] = os.path.expanduser(inherited)
    elif same_folder(folder, os.path.join(home(), ".claude")):
        # Setting it to the default folder would move Claude Code's global
        # config from ~/.claude.json to ~/.claude/.claude.json, which looks
        # like an account that was never set up.
        env.pop("CLAUDE_CONFIG_DIR", None)
    else:
        env["CLAUDE_CONFIG_DIR"] = folder
    with_proxy(env)
    return env


def with_proxy(env):
    """Point Claude Code at the widget's proxy, if fetch_usage.sh passed one."""
    url, user, password = (env.pop(name, "") for name in PROXY_IN)
    if not url:
        return
    if user:
        scheme, rest = url.split("://", 1)
        url = f"{scheme}://{quote(user, safe='')}:{quote(password, safe='')}@{rest}"
    for name in PROXY_OUT:
        env[name] = url
    # The widget's proxy wins over exceptions set for the session, as in curl.
    env.pop("NO_PROXY", None)
    env.pop("no_proxy", None)


def wait_out_refresh(proc, folder):
    """At the deadline: give a refresh in flight up to REFRESH_GRACE_S more."""
    deadline = time.monotonic() + REFRESH_GRACE_S
    while time.monotonic() < deadline and claude_refreshing(folder):
        try:
            proc.wait(timeout=0.5)
            return "exited"
        except subprocess.TimeoutExpired:
            pass
    return "exited" if proc.poll() is not None else "timeout"


def run_claude(claude, folder, workdir):
    """Run Claude Code once: "exited", "timeout" or "not_started"."""
    argv = [claude, *CLAUDE_FLAGS]
    outer = shutil.which("timeout")
    if outer:
        argv = [os.path.abspath(outer), "-k", str(OUTER_KILL_S), str(OUTER_TIMEOUT_S), *argv]
    # A session of its own, so stopping it reaches everything it starts.
    try:
        proc = subprocess.Popen(
            argv,
            cwd=workdir,
            env=child_env(folder),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError:
        return "not_started"
    outcome = "exited"
    try:
        try:
            proc.wait(timeout=TIMEOUT_S)
        except subprocess.TimeoutExpired:
            outcome = wait_out_refresh(proc, folder)
    finally:
        # Also on a stop signal to this script, and for anything Claude Code
        # left running after a normal exit.
        stop_group(proc)
    # timeout(1) reports a command it could not run as 126 or 127.
    if outer and outcome == "exited" and proc.returncode in (126, 127):
        return "not_started"
    return outcome


def private_dir(path):
    os.makedirs(path, mode=0o700, exist_ok=True)
    if not stat.S_ISDIR(os.lstat(path).st_mode):
        raise OSError(f"{path} is not a folder")
    os.chmod(path, 0o700)


def result(name, reason=None, next_try=None, last_try=None):
    return {"renew": {"result": name, "reason": reason, "next_try": next_try, "last_try": last_try}}


def renew(args):
    if not re.fullmatch(r"[0-9]{1,20}", args.key):
        return result("error", "bad_key")
    if args.env_token:
        # The widget reads CLAUDE_CODE_OAUTH_TOKEN, not this file, so renewing
        # the file would change nothing it shows.
        return result("not_possible", "token_from_env")
    if not args.credentials:
        return result("not_possible", "no_credentials")

    cache = os.path.join(home(), ".cache", "claudemeter")
    os.makedirs(cache, exist_ok=True)
    workdir = os.path.join(cache, "claude-renew")

    # One renewal per account at a time, across widget instances. The lock goes
    # with this process (and is not inherited by Claude Code), so it can never
    # be left behind.
    lock_fd = os.open(os.path.join(cache, f"renew_{args.key}.lock"),
                      os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return result("busy", "running")

    before = read_state(args.credentials)
    possible, reason = renewability(before)
    if not possible:
        return result("not_possible", reason)

    claude = find_claude()
    if not claude:
        return result("not_installed")

    if claude_refreshing(args.folder):
        return result("busy", "claude_refreshing")

    state_path = os.path.join(cache, f"renew_{args.key}.json")
    last, failures = read_tries(state_path)
    started = int(time.time())
    if not args.now and last is not None and started < last + cooldown_s(failures):
        return result("cooldown", next_try=last + cooldown_s(failures), last_try=last)

    # Claude Code skips its "trust this folder?" dialog when stdout is not a
    # terminal, so project settings in its folder would apply unasked. It runs
    # in an empty folder of its own, and not at all if something is in there.
    private_dir(workdir)
    if os.listdir(workdir):
        return result("workdir_not_empty")

    # Recorded before starting, so a crash or a kill still counts as a try.
    write_tries(state_path, started, failures)
    outcome = run_claude(claude, args.folder, workdir)
    if outcome == "not_started":
        return result("not_installed", "not_started",
                      next_try=started + cooldown_s(failures), last_try=started)

    after = read_state_settled(args.credentials)
    if after is not None and after[0] is not None and after[0] > before[0] and after[0] > now_ms():
        write_tries(state_path, started, 0)
        return result("renewed", next_try=started + cooldown_s(0), last_try=started)
    # Only automatic tries back off; a click that fails leaves the count alone.
    if not args.now:
        failures += 1
        write_tries(state_path, started, failures)
    name = "timeout" if outcome == "timeout" else "not_renewed"
    return result(name, next_try=started + cooldown_s(failures), last_try=started)


def check(args):
    if not args.credentials:
        possible, reason = False, "no_credentials"
    else:
        possible, reason = renewability(read_state(args.credentials))
    return {"possible": possible, "reason": reason}


def stop_on_signal(signum, _frame):
    # Ignore further stop signals first, so a second one cannot cut the
    # cleanup in run_claude short and leave Claude Code running.
    for sig in STOP_SIGNALS:
        signal.signal(sig, signal.SIG_IGN)
    raise Stopped(signum)


def parse_args():
    parser = argparse.ArgumentParser(add_help=False)
    sub = parser.add_subparsers(dest="command", required=True)
    p_check = sub.add_parser("check", add_help=False)
    p_check.add_argument("--credentials", default="")
    p_renew = sub.add_parser("renew", add_help=False)
    p_renew.add_argument("--folder", required=True)
    p_renew.add_argument("--key", required=True)
    p_renew.add_argument("--credentials", default="")
    p_renew.add_argument("--env-token", action="store_true")
    p_renew.add_argument("--now", action="store_true")
    return parser.parse_args()


def main():
    for sig in STOP_SIGNALS:
        signal.signal(sig, stop_on_signal)
    is_check = len(sys.argv) > 1 and sys.argv[1] == "check"
    try:
        args = parse_args()
        out = check(args) if args.command == "check" else renew(args)
    except Stopped:
        out = result("error", "stopped")
    except SystemExit:
        out = result("error", "bad_arguments")
    except Exception:
        out = result("error", "internal_error")
    if is_check and "renew" in out:
        out = {"possible": False, "reason": "error"}
    try:
        json.dump(out, sys.stdout)
        sys.stdout.write("\n")
        sys.stdout.flush()
    except (OSError, Stopped):
        pass


if __name__ == "__main__":
    main()
