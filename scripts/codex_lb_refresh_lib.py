#!/usr/bin/env python3
"""Pure functions for the codex-lb accounts refresher: mapping, delta, validation.

No login/network here on purpose — this module is imported both by the
network-touching refresher script and by the unit tests
(scripts/test_codex_lb_refresh.py), which must run without any credentials
or connectivity.
"""

import datetime
import math

DEFAULT_CODEX_LB_URL = "http://127.0.0.1:2455"


def _as_number(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and math.isfinite(value):
        return value
    return None


def _as_identifier(value):
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _dict_or_empty(value):
    return value if isinstance(value, dict) else {}


def select_base_url(env):
    """Pick the codex-lb base URL using the same env aliases as the Go daemon."""
    env = env or {}
    for key in ("TOKEN_USAGE_CODEX_LB_URL", "CODEX_LB_URL", "CODEX_LB_BASE_URL"):
        value = _as_identifier(env.get(key))
        if value is not None:
            return value
    return DEFAULT_CODEX_LB_URL


def _normalize_status_value(value):
    text = _as_identifier(value)
    if text is None:
        return None
    normalized = text.lower().replace("-", "_").replace(" ", "_")
    aliases = {
        "ok": "active",
        "healthy": "active",
        "enabled": "active",
        "logged_in": "active",
        "disabled": "paused",
        "inactive": "paused",
        "suspended": "paused",
        "auth_required": "reauth_required",
        "auth_expired": "reauth_required",
        "login_required": "reauth_required",
        "reauth": "reauth_required",
        "reauthrequired": "reauth_required",
        "token_expired": "reauth_required",
        "unauthorized": "reauth_required",
        "rate_limited": "rate_limited",
        "ratelimited": "rate_limited",
    }
    return aliases.get(normalized, normalized)


def _derive_status(acct):
    """Return a normalized codex-lb account status from several known shapes."""
    for key in ("status", "accountStatus", "state", "authStatus", "health"):
        status = _normalize_status_value(acct.get(key))
        if status is not None:
            return status

    auth = _dict_or_empty(acct.get("auth"))
    for key in ("status", "state", "authStatus"):
        status = _normalize_status_value(auth.get(key))
        if status is not None:
            return status
    for key in ("requiresReauth", "reauthRequired", "expired", "isExpired"):
        if auth.get(key) is True:
            return "reauth_required"

    if _as_identifier(acct.get("deactivationReason")) is not None:
        return "deactivated"
    for key in ("active", "isActive", "enabled", "isEnabled"):
        if isinstance(acct.get(key), bool):
            return "active" if acct.get(key) else "paused"
    return "unavailable"


def to_used_pct(remaining_percent):
    """Convert a codex-lb "remaining percent" (0-100) into a used fraction (0.0-1.0).

    Returns None when remaining_percent is None/non-numeric (unknown/absent).
    """
    remaining_percent = _as_number(remaining_percent)
    if remaining_percent is None:
        return None
    return max(0.0, min(1.0, 1.0 - remaining_percent / 100.0))


def tokens_per_hour(prev, now):
    """Compute a tokens/hour rate from two samples.

    prev/now are `{"totalTokens": int, "ts": epoch_seconds}` or None.
    Returns None for: no prior sample, non-positive elapsed time, or a
    negative token delta (counter reset).
    """
    if not isinstance(prev, dict) or not isinstance(now, dict):
        return None
    prev_total = _as_number(prev.get("totalTokens"))
    now_total = _as_number(now.get("totalTokens"))
    prev_ts = _as_number(prev.get("ts"))
    now_ts = _as_number(now.get("ts"))
    if None in (prev_total, now_total, prev_ts, now_ts):
        return None
    delta_t = now_ts - prev_ts
    if delta_t <= 0:
        return None
    delta_tok = now_total - prev_total
    if delta_tok < 0:
        return None
    return delta_tok / (delta_t / 3600.0)


def validate_accounts_payload(obj):
    """True iff obj is a dict with a top-level "accounts" key that is a list."""
    if not isinstance(obj, dict):
        return False
    return isinstance(obj.get("accounts"), list)


def build_derived(accounts_json, prev_samples, now_ts):
    """Map a codex-lb /api/accounts body into the derived shape + updated samples.

    Returns (derived_dict, new_samples):
      - derived_dict: {"schemaVersion": 1, "accounts": [...]} in codex-lb source order.
      - new_samples: {accountId: {"totalTokens": int, "ts": now_ts}} for the next delta.
    """
    prev_samples = prev_samples or {}
    accounts_in = accounts_json.get("accounts") or []

    new_samples = {}
    derived_accounts = []

    for acct in accounts_in:
        if not isinstance(acct, dict):
            continue
        account_id = _as_identifier(acct.get("accountId"))
        usage = _dict_or_empty(acct.get("usage"))
        request_usage = _dict_or_empty(acct.get("requestUsage"))
        total_tokens_value = _as_number(request_usage.get("totalTokens"))
        total_tokens = int(total_tokens_value) if total_tokens_value is not None else None

        now_sample = None
        if account_id is not None and total_tokens is not None:
            now_sample = {"totalTokens": total_tokens, "ts": now_ts}
            new_samples[account_id] = now_sample

        rate = tokens_per_hour(prev_samples.get(account_id), now_sample) if account_id is not None else None

        five_hour_pct = to_used_pct(usage.get("primaryRemainingPercent"))
        seven_day_pct = to_used_pct(usage.get("secondaryRemainingPercent"))

        derived_accounts.append(
            {
                "accountId": account_id,
                "email": acct.get("email"),
                "alias": acct.get("alias"),
                "displayName": acct.get("displayName"),
                "status": _derive_status(acct),
                "fiveHourPct": round(five_hour_pct, 6) if five_hour_pct is not None else None,
                "sevenDayPct": round(seven_day_pct, 6) if seven_day_pct is not None else None,
                "resetAtPrimary": acct.get("resetAtPrimary"),
                "resetAtSecondary": acct.get("resetAtSecondary"),
                "totalTokens": total_tokens,
                "tokensPerHour": rate,
                "lastRefreshAt": acct.get("lastRefreshAt"),
            }
        )

    for i, a in enumerate(derived_accounts):
        a["number"] = i + 1

    updated_at = datetime.datetime.fromtimestamp(
        now_ts, datetime.timezone.utc
    ).strftime("%Y-%m-%dT%H:%M:%SZ")
    derived = {
        "schemaVersion": 1,
        "accountsUpdatedAt": updated_at,
        "accounts": derived_accounts,
    }
    return derived, new_samples
