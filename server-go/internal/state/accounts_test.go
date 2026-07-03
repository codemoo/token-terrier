package state

import (
	"testing"
	"time"

	"github.com/codemoo/token-terrier/server-go/internal/jsonl"
	"github.com/codemoo/token-terrier/server-go/internal/wire"
)

type fakeAccounts struct {
	accts   []wire.AccountUsage
	updated *string
}

func (f fakeAccounts) Accounts() ([]wire.AccountUsage, *string) { return f.accts, f.updated }

func newTestState(provider wire.Provider) *State {
	return New(provider, nil, nil, NoopRefresher{}, nil, wire.ProducerInfo{ID: "h", TimeZone: "UTC"}, nil)
}

func TestIngestEventDecoratesClaudeAccounts(t *testing.T) {
	s := newTestState(wire.ProviderClaude)
	up := "2026-07-03T09:00:00.000Z"
	s.SetAccountsProvider(fakeAccounts{
		accts:   []wire.AccountUsage{{Number: 1, Email: "a@b.com", Active: true, Status: "ok"}},
		updated: &up,
	})
	snap := s.IngestEvent(jsonl.TokenEvent{Provider: wire.ProviderClaude, Tokens: 10, Timestamp: time.Now()}, time.Now())
	if len(snap.Accounts) != 1 || snap.Accounts[0].Email != "a@b.com" {
		t.Fatalf("expected decorated accounts, got %+v", snap.Accounts)
	}
	if snap.AccountsUpdated == nil || *snap.AccountsUpdated != up {
		t.Fatalf("expected accounts_updated_at, got %v", snap.AccountsUpdated)
	}
}

func TestNoProviderLeavesAccountsNil(t *testing.T) {
	s := newTestState(wire.ProviderClaude)
	snap := s.IngestEvent(jsonl.TokenEvent{Provider: wire.ProviderClaude, Tokens: 5, Timestamp: time.Now()}, time.Now())
	if snap.Accounts != nil || snap.AccountsUpdated != nil {
		t.Fatalf("no provider → nil accounts, got %+v / %v", snap.Accounts, snap.AccountsUpdated)
	}
}

func TestCodexNeverDecorated(t *testing.T) {
	s := newTestState(wire.ProviderCodex)
	s.SetAccountsProvider(fakeAccounts{accts: []wire.AccountUsage{{Number: 1, Email: "x@y.com"}}})
	// Latest is safe without credentials/usage client for this assertion.
	snap := s.Latest(time.Now())
	if snap.Accounts != nil {
		t.Fatalf("codex must never carry accounts, got %+v", snap.Accounts)
	}
}
