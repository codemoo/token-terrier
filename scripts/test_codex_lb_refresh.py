#!/usr/bin/env python3
"""Unit tests for codex_lb_refresh_lib (pure functions, no login/network)."""

import sys
import unittest

from codex_lb_refresh_lib import (
    build_derived,
    to_used_pct,
    tokens_per_hour,
    validate_accounts_payload,
)


class ToUsedPctTests(unittest.TestCase):
    def test_to_used_pct(self):
        self.assertEqual(to_used_pct(100), 0.0)
        self.assertEqual(to_used_pct(0), 1.0)
        self.assertIsNone(to_used_pct(None))
        self.assertIsNone(to_used_pct("90"))


class TokensPerHourTests(unittest.TestCase):
    def test_tokens_per_hour(self):
        self.assertIsNone(tokens_per_hour(None, {"totalTokens": 100, "ts": 0}))  # 첫샘플
        self.assertIsNone(
            tokens_per_hour({"totalTokens": 100, "ts": 0}, {"totalTokens": 100, "ts": 0})
        )  # Δt<=0
        self.assertIsNone(
            tokens_per_hour({"totalTokens": 100, "ts": 0}, {"totalTokens": 50, "ts": 3600})
        )  # 리셋(음수)
        self.assertEqual(
            tokens_per_hour({"totalTokens": 100, "ts": 0}, {"totalTokens": 700, "ts": 3600}),
            600.0,
        )
        self.assertIsNone(
            tokens_per_hour({"totalTokens": "bad", "ts": 0}, {"totalTokens": 700, "ts": 3600})
        )


class ValidateAccountsPayloadTests(unittest.TestCase):
    def test_validate_rejects_401_body(self):
        self.assertFalse(validate_accounts_payload({"detail": "unauthorized"}))
        self.assertTrue(validate_accounts_payload({"accounts": []}))


class BuildDerivedTests(unittest.TestCase):
    def test_build_derived_preserves_source_order_and_maps(self):
        body = {
            "accounts": [
                {
                    "accountId": "b",
                    "email": "b@x",
                    "alias": "",
                    "displayName": "",
                    "status": "paused",
                    "usage": {"primaryRemainingPercent": 100, "secondaryRemainingPercent": 0},
                    "resetAtPrimary": "...",
                    "resetAtSecondary": "...",
                    "requestUsage": {"totalTokens": 10},
                },
                {
                    "accountId": "a",
                    "email": "a@x",
                    "alias": "Work",
                    "status": "active",
                    "usage": {"primaryRemainingPercent": 90, "secondaryRemainingPercent": 8},
                    "requestUsage": {"totalTokens": 700},
                },
            ]
        }
        prev = {"a": {"totalTokens": 100, "ts": 0}}
        d, new = build_derived(body, prev, now_ts=3600)
        self.assertEqual(d["schemaVersion"], 1)
        self.assertEqual([x["accountId"] for x in d["accounts"]], ["b", "a"])  # codex-lb 순서 보존
        self.assertEqual([x["number"] for x in d["accounts"]], [1, 2])  # 표시 번호도 원본 순서
        self.assertEqual(d["accounts"][0]["status"], "paused")
        self.assertEqual(d["accounts"][1]["status"], "active")
        self.assertEqual(d["accounts"][1]["alias"], "Work")  # alias 분리(reader 가 firstNonEmpty)
        self.assertEqual(d["accounts"][1]["email"], "a@x")
        self.assertEqual(d["accounts"][0]["alias"], "")  # b: alias 비어있음 → reader 가 email 폴백
        self.assertEqual(d["accounts"][1]["fiveHourPct"], round(0.1, 6))
        self.assertEqual(d["accounts"][1]["tokensPerHour"], 600.0)  # (700-100)/1h
        self.assertEqual(new["a"]["totalTokens"], 700)
        # 상위 accountsUpdatedAt = now_ts(3600s epoch) ISO8601 UTC
        self.assertEqual(d["accountsUpdatedAt"], "1970-01-01T01:00:00Z")

    def test_build_derived_skips_bad_items_and_does_not_sample_missing_account_id(self):
        body = {
            "accounts": [
                "not-an-account",
                {
                    "email": "fallback@x",
                    "status": "active",
                    "usage": {"primaryRemainingPercent": "bad"},
                    "requestUsage": {"totalTokens": 100},
                },
            ]
        }
        d, new = build_derived(body, {"fallback@x": {"totalTokens": 10, "ts": 0}}, now_ts=3600)
        self.assertEqual(len(d["accounts"]), 1)
        self.assertIsNone(d["accounts"][0]["accountId"])
        self.assertIsNone(d["accounts"][0]["fiveHourPct"])
        self.assertIsNone(d["accounts"][0]["tokensPerHour"])
        self.assertEqual(new, {})

    def test_build_derived_normalizes_status_from_alternate_shapes(self):
        body = {
            "accounts": [
                {"accountId": "a", "status": "reauth-required"},
                {"accountId": "b", "auth": {"requiresReauth": True}},
                {"accountId": "c", "enabled": False},
                {"accountId": "d", "accountStatus": "logged in"},
                {"accountId": "e", "deactivationReason": "owner_removed"},
                {"accountId": "f"},
            ]
        }
        d, _ = build_derived(body, {}, now_ts=3600)
        self.assertEqual(
            [x["status"] for x in d["accounts"]],
            ["reauth_required", "reauth_required", "paused", "active", "deactivated", "unavailable"],
        )


if __name__ == "__main__":
    runner = unittest.main(exit=False)
    sys.exit(0 if runner.result.wasSuccessful() else 1)
