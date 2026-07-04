package codexaccounts

import (
	"math"
	"os"
	"path/filepath"
	"testing"
	"time"

	"log/slog"
)

func readerFromString(t *testing.T, js string) *Reader {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "codex-lb-accounts.json")
	if err := os.WriteFile(path, []byte(js), 0o600); err != nil {
		t.Fatalf("write temp file: %v", err)
	}
	return NewReader(path, slog.Default())
}

func TestReader_MapsAndNormalizes(t *testing.T) {
	js := `{"schemaVersion":1,"accountsUpdatedAt":"2026-07-03T13:00:00Z","accounts":[
      {"number":1,"accountId":"aid1","email":"a@x","alias":" Work ","status":" active ","fiveHourPct":10,"sevenDayPct":0.92,"resetAtPrimary":"2026-07-03T15:00:00Z","resetAtSecondary":"2026-07-07T02:00:00Z","totalTokens":123,"tokensPerHour":45.6,"lastRefreshAt":"2026-07-03T12:55:00Z"},
      {"number":2,"accountId":"aid2","email":"b@x","alias":"","status":"paused","fiveHourPct":null,"sevenDayPct":0}]}`

	accts, updated := readerFromString(t, js).Accounts()

	if updated == nil || *updated != "2026-07-03T13:00:00.000Z" {
		t.Fatalf("expected accountsUpdatedAt passthrough, got %v", updated)
	}
	if len(accts) != 2 {
		t.Fatalf("expected 2 accounts, got %d", len(accts))
	}
	if accts[0].Status != "ok" { // active -> ok
		t.Errorf("expected status ok, got %q", accts[0].Status)
	}
	if accts[0].Email != "Work" { // display label: alias preferred
		t.Errorf("expected display label Work, got %q", accts[0].Email)
	}
	if accts[0].FiveHour == nil || math.Abs(accts[0].FiveHour.UsedPct-1) > 1e-9 {
		t.Errorf("expected FiveHour.UsedPct clamped to 1, got %+v", accts[0].FiveHour)
	}
	if accts[0].FiveHour.ResetsAt == nil || *accts[0].FiveHour.ResetsAt != "2026-07-03T15:00:00.000Z" {
		t.Errorf("expected normalized reset, got %+v", accts[0].FiveHour.ResetsAt)
	}
	if accts[0].LastRefreshAt == nil || *accts[0].LastRefreshAt != "2026-07-03T12:55:00.000Z" {
		t.Errorf("expected normalized lastRefreshAt, got %v", accts[0].LastRefreshAt)
	}
	if accts[0].TokensPerHour == nil || *accts[0].TokensPerHour != 45.6 {
		t.Errorf("expected TokensPerHour 45.6, got %v", accts[0].TokensPerHour)
	}
	if accts[0].TotalTokens == nil || *accts[0].TotalTokens != 123 {
		t.Errorf("expected TotalTokens 123, got %v", accts[0].TotalTokens)
	}
	if accts[1].Status != "paused" { // pass-through unknown status
		t.Errorf("expected status paused pass-through, got %q", accts[1].Status)
	}
	if accts[1].FiveHour != nil {
		t.Errorf("expected nil FiveHour for null window, got %+v", accts[1].FiveHour)
	}
}

func TestReader_FallsBackToFileMtimeWhenUpdatedAtMissing(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "codex-lb-accounts.json")
	js := `{"schemaVersion":1,"accounts":[{"number":1,"accountId":"aid1","email":"a@x","status":"active","fiveHourPct":0.1}]}`
	if err := os.WriteFile(path, []byte(js), 0o600); err != nil {
		t.Fatalf("write temp file: %v", err)
	}
	mtime := time.Date(2026, 7, 3, 13, 0, 0, 0, time.UTC)
	_ = os.Chtimes(path, mtime, mtime)

	_, updated := NewReader(path, slog.Default()).Accounts()
	if updated == nil || *updated != "2026-07-03T13:00:00.000Z" {
		t.Fatalf("expected mtime fallback, got %v", updated)
	}
}

func TestReader_MalformedRewriteKeepsLastGood(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "codex-lb-accounts.json")
	good := `{"schemaVersion":1,"accountsUpdatedAt":"2026-07-03T13:00:00Z","accounts":[{"number":1,"accountId":"aid1","email":"a@x","status":"active","fiveHourPct":0.1}]}`
	if err := os.WriteFile(path, []byte(good), 0o600); err != nil {
		t.Fatalf("write good file: %v", err)
	}
	r := NewReader(path, slog.Default())
	r.checkEvery = 0
	accts, updated := r.Accounts()
	if len(accts) != 1 || updated == nil {
		t.Fatalf("first read = (%+v,%v), want 1 account + updated", accts, updated)
	}

	future := time.Now().Add(2 * time.Second)
	if err := os.WriteFile(path, []byte(`not json`), 0o600); err != nil {
		t.Fatalf("write malformed file: %v", err)
	}
	_ = os.Chtimes(path, future, future)
	accts, updated2 := r.Accounts()
	if len(accts) != 1 || accts[0].Email != "a@x" {
		t.Fatalf("malformed rewrite should keep last-good accounts, got %+v", accts)
	}
	if updated2 == nil || *updated2 != *updated {
		t.Fatalf("malformed rewrite should keep last-good updated_at, got %v want %v", updated2, updated)
	}
}

func TestNormalizeStatusAliases(t *testing.T) {
	cases := map[string]string{
		" active ":        "ok",
		"enabled":         "ok",
		"logged-in":       "ok",
		"disabled":        "paused",
		"inactive":        "paused",
		"auth required":   "reauth_required",
		"reauthrequired":  "reauth_required",
		"token-expired":   "reauth_required",
		"rateLimited":     "rate_limited",
		"":                "unavailable",
		"reauth_required": "reauth_required",
	}
	for input, want := range cases {
		if got := normalizeStatus(input); got != want {
			t.Fatalf("normalizeStatus(%q) = %q, want %q", input, got, want)
		}
	}
}
