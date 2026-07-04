#!/usr/bin/env python3
"""Codex-lb accounts refresher.

Logs into the codex-lb dashboard, fetches /api/accounts, and atomically
writes the derived per-account snapshot that token-terrier's daemon reads.

The daemon NEVER logs into codex-lb itself -- this script is the only thing
that does. The password/session cookie value is never printed or logged.
"""

import http.cookiejar
import json
import logging
import os
import sys
import tempfile
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from codex_lb_refresh_lib import build_derived, select_base_url, validate_accounts_payload  # noqa: E402

logging.basicConfig(level=logging.INFO, format="%(asctime)s codex-lb-refresh: %(message)s", stream=sys.stdout)
log = logging.getLogger("codex-lb-refresh")

CONFIG_DIR = os.path.join(os.path.expanduser("~"), ".config", "token-usage")
DEFAULT_OUT = os.path.join(CONFIG_DIR, "codex-lb-accounts.json")
DEFAULT_SIDECAR = os.path.join(CONFIG_DIR, "codex-lb-samples.json")
LOGIN_PATH = "/api/dashboard-auth/password/login"
ACCOUNTS_PATH = "/api/accounts"
BACKOFF_SECONDS = 60
LOCK_STALE_SECONDS = 300


def _atomic_write_json(path, obj):
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=os.path.basename(path) + ".", dir=directory)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(obj, f)
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.remove(tmp_path)
        except OSError:
            pass
        raise


def _load_json(path):
    try:
        with open(path, "r") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _read_backoff(path):
    data = _load_json(path)
    if not isinstance(data, dict):
        return 0.0
    ts = data.get("lastFailureTs")
    return ts if isinstance(ts, (int, float)) else 0.0


def _write_backoff(path, ts):
    try:
        _atomic_write_json(path, {"lastFailureTs": ts})
    except OSError:
        pass  # backoff bookkeeping is best-effort; never block the caller on it


def _acquire_lock(lock_dir):
    # Reclaim a stale lock left behind by a hard-killed previous run.
    if os.path.isdir(lock_dir):
        try:
            age = time.time() - os.stat(lock_dir).st_mtime
        except OSError:
            age = 0
        if age > LOCK_STALE_SECONDS:
            try:
                os.rmdir(lock_dir)
            except OSError:
                pass
    try:
        os.mkdir(lock_dir)
        return True
    except FileExistsError:
        return False


def _release_lock(lock_dir):
    try:
        os.rmdir(lock_dir)
    except OSError:
        pass


def _login(base_url, password, cookie_jar):
    """POST the dashboard password login; return (opener, ok). Never logs the password."""
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cookie_jar))
    body = json.dumps({"password": password}).encode("utf-8")
    req = urllib.request.Request(
        base_url.rstrip("/") + LOGIN_PATH,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with opener.open(req, timeout=15) as resp:
            status = getattr(resp, "status", resp.getcode())
            resp.read()
            return opener, status == 200
    except urllib.error.HTTPError as exc:
        exc.read()
        return opener, False
    except (urllib.error.URLError, OSError, TimeoutError):
        return opener, False


def _fetch_accounts(opener, base_url):
    req = urllib.request.Request(base_url.rstrip("/") + ACCOUNTS_PATH, method="GET")
    try:
        with opener.open(req, timeout=15) as resp:
            status = getattr(resp, "status", resp.getcode())
            raw = resp.read()
    except urllib.error.HTTPError as exc:
        exc.read()
        return None
    except (urllib.error.URLError, OSError, TimeoutError):
        return None
    if status != 200:
        return None
    try:
        return json.loads(raw.decode("utf-8"))
    except ValueError:
        return None


def main():
    password = os.environ.get("CODEX_LB_DASHBOARD_PASSWORD", "").strip()
    if not password:
        log.info("CODEX_LB_DASHBOARD_PASSWORD not set; refresher dormant")
        return 0

    base_url = select_base_url(os.environ)
    out_path = os.environ.get("TOKEN_USAGE_CODEX_ACCOUNTS", "").strip() or DEFAULT_OUT
    sidecar_path = DEFAULT_SIDECAR
    lock_dir = out_path + ".lock"
    backoff_path = out_path + ".backoff"

    os.makedirs(os.path.dirname(out_path), exist_ok=True)

    if not _acquire_lock(lock_dir):
        log.info("another run in progress; skipping")
        return 0

    try:
        last_failure = _read_backoff(backoff_path)
        if last_failure and (time.time() - last_failure) < BACKOFF_SECONDS:
            log.info("backing off after a recent failure; skipping this tick")
            return 1

        cookie_jar = http.cookiejar.CookieJar()
        opener, ok = _login(base_url, password, cookie_jar)
        if not ok:
            log.warning("login failed; keeping last-good snapshot")
            _write_backoff(backoff_path, time.time())
            return 1

        body = _fetch_accounts(opener, base_url)
        if body is None or not validate_accounts_payload(body):
            log.warning("accounts fetch/validation failed; keeping last-good snapshot")
            _write_backoff(backoff_path, time.time())
            return 1

        prev_samples = _load_json(sidecar_path) or {}
        derived, new_samples = build_derived(body, prev_samples, now_ts=time.time())

        _atomic_write_json(out_path, derived)
        _atomic_write_json(sidecar_path, new_samples)
        log.info("refreshed %d account(s)", len(derived.get("accounts") or []))
        return 0
    finally:
        _release_lock(lock_dir)


if __name__ == "__main__":
    sys.exit(main())
