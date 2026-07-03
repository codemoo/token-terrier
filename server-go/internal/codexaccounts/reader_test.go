package codexaccounts

import (
	"math"
	"os"
	"path/filepath"
	"testing"

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
      {"number":1,"accountId":"aid1","email":"a@x","alias":"Work","status":"active","fiveHourPct":10,"sevenDayPct":92,"resetAtPrimary":"2026-07-03T15:00:00Z","resetAtSecondary":"2026-07-07T02:00:00Z","totalTokens":123,"tokensPerHour":45.6},
      {"number":2,"accountId":"aid2","email":"b@x","alias":"","status":"paused","fiveHourPct":null,"sevenDayPct":0}]}`

	accts, updated := readerFromString(t, js).Accounts()

	if updated == nil || *updated != "2026-07-03T13:00:00Z" {
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
	if accts[0].FiveHour == nil || math.Abs(accts[0].FiveHour.UsedPct-10) > 1e-9 {
		t.Errorf("expected FiveHour.UsedPct passthrough 10 (no re-conversion), got %+v", accts[0].FiveHour)
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
