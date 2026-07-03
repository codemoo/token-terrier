#!/usr/bin/env python3
"""Pure functions for the codex-lb accounts refresher: mapping, delta, validation.

No login/network here on purpose — this module is imported both by the
network-touching refresher script and by the unit tests
(scripts/test_codex_lb_refresh.py), which must run without any credentials
or connectivity.
"""


def to_used_pct(remaining_percent):
    """Convert a codex-lb "remaining percent" (0-100) into a used fraction (0.0-1.0).

    Returns None when remaining_percent is None (unknown/absent).
    """
    if remaining_percent is None:
        return None
    return max(0.0, min(1.0, 1.0 - remaining_percent / 100.0))


def tokens_per_hour(prev, now):
    """Compute a tokens/hour rate from two samples.

    prev/now are `{"totalTokens": int, "ts": epoch_seconds}` or None.
    Returns None for: no prior sample, non-positive elapsed time, or a
    negative token delta (counter reset).
    """
    if prev is None or now is None:
        return None
    delta_t = now["ts"] - prev["ts"]
    if delta_t <= 0:
        return None
    delta_tok = now["totalTokens"] - prev["totalTokens"]
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
      - derived_dict: {"schemaVersion": 1, "accounts": [...]} sorted stably by accountId.
      - new_samples: {accountId: {"totalTokens": int, "ts": now_ts}} for the next delta.
    """
    prev_samples = prev_samples or {}
    accounts_in = accounts_json.get("accounts") or []

    new_samples = {}
    derived_accounts = []

    for acct in accounts_in:
        account_id = acct.get("accountId")
        usage = acct.get("usage") or {}
        request_usage = acct.get("requestUsage") or {}
        total_tokens = request_usage.get("totalTokens")

        now_sample = None
        if total_tokens is not None:
            now_sample = {"totalTokens": total_tokens, "ts": now_ts}
            new_samples[account_id] = now_sample

        rate = tokens_per_hour(prev_samples.get(account_id), now_sample)

        label = acct.get("alias") or acct.get("displayName") or acct.get("email")

        five_hour_pct = to_used_pct(usage.get("primaryRemainingPercent"))
        seven_day_pct = to_used_pct(usage.get("secondaryRemainingPercent"))

        derived_accounts.append(
            {
                "accountId": account_id,
                "label": label,
                "email": acct.get("email"),
                "status": acct.get("status"),
                "fiveHourPct": round(five_hour_pct, 6) if five_hour_pct is not None else None,
                "sevenDayPct": round(seven_day_pct, 6) if seven_day_pct is not None else None,
                "resetAtPrimary": acct.get("resetAtPrimary"),
                "resetAtSecondary": acct.get("resetAtSecondary"),
                "totalTokens": total_tokens,
                "tokensPerHour": rate,
                "lastRefreshAt": acct.get("lastRefreshAt"),
            }
        )

    derived_accounts.sort(key=lambda a: (a["accountId"] is None, a["accountId"]))

    derived = {
        "schemaVersion": 1,
        "accounts": derived_accounts,
    }
    return derived, new_samples
