package wire

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestUsageSnapshotOmitsAccountsWhenNil(t *testing.T) {
	snap := UsageSnapshot{Schema: 1, Provider: ProviderClaude}
	b, err := json.Marshal(snap)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(b), "accounts") {
		t.Fatalf("expected no accounts key when nil, got: %s", b)
	}
}

func TestUsageSnapshotIncludesAccountsWhenSet(t *testing.T) {
	reset := "2026-07-03T12:00:00.000Z"
	updated := "2026-07-03T09:47:00.000Z"
	snap := UsageSnapshot{
		Schema:   1,
		Provider: ProviderClaude,
		Accounts: []AccountUsage{{
			Number: 1, Email: "a@b.com", Active: true, Status: "ok",
			FiveHour: &AccountWindow{UsedPct: 0.07, ResetsAt: &reset},
			SevenDay: &AccountWindow{UsedPct: 0.29, ResetsAt: nil},
		}},
		AccountsUpdated: &updated,
	}
	b, _ := json.Marshal(snap)
	s := string(b)
	for _, want := range []string{`"accounts"`, `"number":1`, `"email":"a@b.com"`, `"active":true`, `"five_hour"`, `"used_pct":0.07`, `"seven_day"`, `"accounts_updated_at":"2026-07-03T09:47:00.000Z"`} {
		if !strings.Contains(s, want) {
			t.Fatalf("missing %q in %s", want, s)
		}
	}
}
