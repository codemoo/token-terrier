# claude-swap Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show every claude-swap-managed Claude account's 5h/7d usage in the menu bar's Claude Code section, fed by a file the server-go daemon reads (never executing `cswap` itself).

**Architecture:** A separate launchd job runs `cswap --list --json` every 5 min and atomically writes it to `~/.config/token-usage/claude-swap-accounts.json`. The daemon's new `internal/claudeswap` reader parses that file (mtime-cached, throttled) and exposes `Accounts()`. The Claude `state.State` decorates every emitted snapshot with an additive `accounts[]` field via thin public wrappers (so `sse`/`api` packages are untouched). The Swift menu bar renders per-account rows under the existing Claude card. The daemon never runs `cswap` and never does network I/O for this feature.

**Tech Stack:** Go 1.23 (server-go), Swift/SwiftUI (menu bar app), POSIX sh (refresher scripts), launchd.

**Spec:** `docs/superpowers/specs/2026-07-03-claude-swap-integration-design.md`

## Global Constraints

- **Additive/backward-compatible:** when claude-swap is absent, `/claude/snapshot` and `/codex/*` JSON must be byte-identical to today. New wire fields use `omitempty` (Go) / optional-nil (Swift).
- **Daemon is read-only:** server-go must NOT exec `cswap`, must NOT do network I/O for this feature. File reads only.
- **`accounts[]` is Claude-only:** never attach to Codex snapshots.
- **pct conversion:** cswap `pct` is 0–100; wire `used_pct` is 0–1. Always divide by 100 and clamp to [0,1].
- **schema guard:** only accept `schemaVersion == 1`; anything else → feature dormant (no accounts).
- **resets_at normalization:** convert cswap's RFC3339(+offset, micros) to token-run canonical via `wire.FormatTime` so the Swift `SnapshotDateFormatter` can parse it; drop unparseable timestamps.
- **Privacy:** never log emails or the account list. Log counts only. Contract file + generated plist are `0600` / user-only.
- **Email in UI:** display full email in the menu bar (no masking) — user-confirmed 2026-07-03.
- **Go module path:** `github.com/codemoo/token-terrier/server-go`.
- **Build/test:** Go — `cd server-go && go test ./... && go build ./cmd/daemon`. Swift — `swift build && swift test` from repo root.
- **AGENTS.md:** do not commit machine-specific launchd plists (the generated plist lives untracked in `launchd/`); scripts that *generate* them are generic and may be committed.

---

### Task 1: Wire types — `AccountUsage`, `AccountWindow`, snapshot fields (Go)

**Files:**
- Modify: `server-go/internal/wire/types.go` (add types after `QuotaWindow`/`RollingWindow`; add 2 fields to `UsageSnapshot` after `Status`)
- Test: `server-go/internal/wire/types_test.go` (create)

**Interfaces:**
- Produces: `wire.AccountWindow{UsedPct float64; ResetsAt *string}`, `wire.AccountUsage{Number int; Email string; Active bool; Status string; FiveHour *AccountWindow; SevenDay *AccountWindow}`, and `UsageSnapshot.Accounts []AccountUsage` / `UsageSnapshot.AccountsUpdated *string`. Consumed by Tasks 2–5.

- [ ] **Step 1: Write the failing test**

Create `server-go/internal/wire/types_test.go`:

```go
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server-go && go test ./internal/wire/ -run TestUsageSnapshot -v`
Expected: FAIL — `AccountUsage`/`AccountWindow` undefined, `Accounts` field missing.

- [ ] **Step 3: Add the types and fields**

In `server-go/internal/wire/types.go`, after the `RollingWindow` block (around line 61), add:

```go
// AccountWindow is one quota window for a single claude-swap account.
type AccountWindow struct {
	UsedPct  float64 `json:"used_pct"`
	ResetsAt *string `json:"resets_at"`
}

// AccountUsage is one claude-swap-managed Claude account's usage, as surfaced
// under a Claude snapshot's accounts[]. Status mirrors cswap usageStatus:
// ok | token_expired | api_key | keychain_unavailable | no_credentials | unavailable.
type AccountUsage struct {
	Number   int            `json:"number"`
	Email    string         `json:"email"`
	Active   bool           `json:"active"`
	Status   string         `json:"status"`
	FiveHour *AccountWindow `json:"five_hour"`
	SevenDay *AccountWindow `json:"seven_day"`
}
```

Then in the `UsageSnapshot` struct, add two fields immediately after `Status SnapshotStatus \`json:"status"\``:

```go
	// Accounts is Claude-only, present only when claude-swap is detected.
	// omitempty keeps codex + no-swap snapshots byte-identical to before.
	Accounts        []AccountUsage `json:"accounts,omitempty"`
	AccountsUpdated *string        `json:"accounts_updated_at,omitempty"`
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd server-go && go test ./internal/wire/ -run TestUsageSnapshot -v`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add server-go/internal/wire/types.go server-go/internal/wire/types_test.go
git commit -m "feat(wire): add additive Claude accounts[] snapshot fields"
```

---

### Task 2: claudeswap parse function (Go)

**Files:**
- Create: `server-go/internal/claudeswap/reader.go` (parse helpers only in this task)
- Test: `server-go/internal/claudeswap/reader_test.go`

**Interfaces:**
- Produces: `parseAccounts(data []byte) ([]wire.AccountUsage, error)` — consumed by Task 3's `Reader`. Returns `(nil, nil)` for zero accounts; error for malformed JSON or `schemaVersion != 1`.

- [ ] **Step 1: Write the failing test**

Create `server-go/internal/claudeswap/reader_test.go`:

```go
package claudeswap

import (
	"math"
	"testing"
)

const sampleTwoAccounts = `{
  "schemaVersion": 1,
  "activeAccountNumber": 2,
  "accounts": [
    {"number":1,"email":"a@b.com","active":false,"usageStatus":"ok",
     "usage":{"fiveHour":{"pct":7.0,"resetsAt":"2026-07-03T12:00:00.318548+00:00"},
              "sevenDay":{"pct":29.0,"resetsAt":"2026-07-04T18:00:00.000+00:00"}}},
    {"number":2,"email":"c@d.com","active":true,"usageStatus":"ok",
     "usage":{"fiveHour":{"pct":50.0,"resetsAt":"2026-07-03T12:00:00Z"},
              "sevenDay":{"pct":80.0,"resetsAt":"2026-07-04T18:00:00Z"}}}
  ]
}`

func TestParseAccountsConvertsPctAndNormalizesReset(t *testing.T) {
	accts, err := parseAccounts([]byte(sampleTwoAccounts))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(accts) != 2 {
		t.Fatalf("len = %d, want 2", len(accts))
	}
	a := accts[0]
	if a.Number != 1 || a.Email != "a@b.com" || a.Active || a.Status != "ok" {
		t.Fatalf("account0 identity wrong: %+v", a)
	}
	if a.FiveHour == nil || math.Abs(a.FiveHour.UsedPct-0.07) > 1e-9 {
		t.Fatalf("5h pct = %v, want 0.07", a.FiveHour)
	}
	if a.FiveHour.ResetsAt == nil || *a.FiveHour.ResetsAt != "2026-07-03T12:00:00.318Z" {
		t.Fatalf("5h reset = %v, want normalized millis Z", a.FiveHour.ResetsAt)
	}
	if accts[1].SevenDay == nil || math.Abs(accts[1].SevenDay.UsedPct-0.80) > 1e-9 {
		t.Fatalf("acct1 7d = %v, want 0.80", accts[1].SevenDay)
	}
}

func TestParseAccountsRejectsWrongSchema(t *testing.T) {
	if _, err := parseAccounts([]byte(`{"schemaVersion":2,"accounts":[]}`)); err == nil {
		t.Fatal("expected error for schemaVersion 2")
	}
}

func TestParseAccountsZeroAccountsIsNilNoError(t *testing.T) {
	accts, err := parseAccounts([]byte(`{"schemaVersion":1,"accounts":[]}`))
	if err != nil {
		t.Fatalf("err = %v, want nil", err)
	}
	if accts != nil {
		t.Fatalf("accts = %v, want nil", accts)
	}
}

func TestParseAccountsNonOKStatusHasNilWindows(t *testing.T) {
	data := `{"schemaVersion":1,"accounts":[
	  {"number":3,"email":"e@f.com","active":false,"usageStatus":"api_key","usage":null}]}`
	accts, err := parseAccounts([]byte(data))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(accts) != 1 || accts[0].Status != "api_key" {
		t.Fatalf("status wrong: %+v", accts)
	}
	if accts[0].FiveHour != nil || accts[0].SevenDay != nil {
		t.Fatalf("expected nil windows for api_key account")
	}
}

func TestParseAccountsMalformedJSONErrors(t *testing.T) {
	if _, err := parseAccounts([]byte(`not json`)); err == nil {
		t.Fatal("expected error for malformed json")
	}
}

func TestParseAccountsUnparseableResetDropped(t *testing.T) {
	data := `{"schemaVersion":1,"accounts":[
	  {"number":1,"email":"a@b.com","active":true,"usageStatus":"ok",
	   "usage":{"fiveHour":{"pct":10.0,"resetsAt":"garbage"}}}]}`
	accts, err := parseAccounts([]byte(data))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if accts[0].FiveHour == nil {
		t.Fatal("window should exist even if reset unparseable")
	}
	if accts[0].FiveHour.ResetsAt != nil {
		t.Fatalf("unparseable reset should be nil, got %v", *accts[0].FiveHour.ResetsAt)
	}
	if accts[0].SevenDay != nil {
		t.Fatal("absent sevenDay should be nil")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server-go && go test ./internal/claudeswap/ -v`
Expected: FAIL — package/`parseAccounts` undefined (build error).

- [ ] **Step 3: Write the parse implementation**

Create `server-go/internal/claudeswap/reader.go`:

```go
// Package claudeswap reads a claude-swap `--list --json` snapshot file and
// exposes per-account Claude usage. It never executes cswap or does network
// I/O — a separate launchd job keeps the file fresh (see scripts/).
package claudeswap

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/codemoo/token-terrier/server-go/internal/wire"
)

// cswap `--list --json` shape (schemaVersion 1). Only fields we use.
type cswapList struct {
	SchemaVersion int            `json:"schemaVersion"`
	Accounts      []cswapAccount `json:"accounts"`
}

type cswapAccount struct {
	Number      int         `json:"number"`
	Email       string      `json:"email"`
	Active      bool        `json:"active"`
	UsageStatus string      `json:"usageStatus"`
	Usage       *cswapUsage `json:"usage"`
}

type cswapUsage struct {
	FiveHour *cswapWindow `json:"fiveHour"`
	SevenDay *cswapWindow `json:"sevenDay"`
}

type cswapWindow struct {
	Pct      float64 `json:"pct"`
	ResetsAt *string `json:"resetsAt"`
}

// parseAccounts converts a cswap --list --json payload to wire.AccountUsage.
// Returns (nil, nil) when there are zero accounts; error on malformed JSON or
// an unsupported schemaVersion.
func parseAccounts(data []byte) ([]wire.AccountUsage, error) {
	var list cswapList
	if err := json.Unmarshal(data, &list); err != nil {
		return nil, err
	}
	if list.SchemaVersion != 1 {
		return nil, fmt.Errorf("unsupported claude-swap schemaVersion %d", list.SchemaVersion)
	}
	if len(list.Accounts) == 0 {
		return nil, nil
	}
	out := make([]wire.AccountUsage, 0, len(list.Accounts))
	for _, a := range list.Accounts {
		acc := wire.AccountUsage{
			Number: a.Number,
			Email:  a.Email,
			Active: a.Active,
			Status: a.UsageStatus,
		}
		if a.Usage != nil {
			acc.FiveHour = toWindow(a.Usage.FiveHour)
			acc.SevenDay = toWindow(a.Usage.SevenDay)
		}
		out = append(out, acc)
	}
	return out, nil
}

func toWindow(w *cswapWindow) *wire.AccountWindow {
	if w == nil {
		return nil
	}
	return &wire.AccountWindow{
		UsedPct:  clampUnit(w.Pct / 100.0),
		ResetsAt: normalizeReset(w.ResetsAt),
	}
}

// normalizeReset reformats a cswap RFC3339(+offset, fractional) timestamp to
// token-run's canonical millisecond-Z form so the Swift date parser accepts
// it. Unparseable / empty → nil (tolerated).
func normalizeReset(raw *string) *string {
	if raw == nil {
		return nil
	}
	s := strings.TrimSpace(*raw)
	if s == "" {
		return nil
	}
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339} {
		if t, err := time.Parse(layout, s); err == nil {
			out := wire.FormatTime(t.UTC())
			return &out
		}
	}
	return nil
}

func clampUnit(v float64) float64 {
	if v < 0 {
		return 0
	}
	if v > 1 {
		return 1
	}
	return v
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd server-go && go test ./internal/claudeswap/ -v`
Expected: PASS (all 6 tests).

- [ ] **Step 5: Commit**

```bash
git add server-go/internal/claudeswap/reader.go server-go/internal/claudeswap/reader_test.go
git commit -m "feat(claudeswap): parse cswap --list --json into wire.AccountUsage"
```

---

### Task 3: claudeswap `Reader` — file read, mtime cache, throttle (Go)

**Files:**
- Modify: `server-go/internal/claudeswap/reader.go` (add `Reader` type)
- Modify: `server-go/internal/claudeswap/reader_test.go` (add file-level tests)

**Interfaces:**
- Consumes: `parseAccounts` (Task 2).
- Produces: `NewReader(path string, logger *slog.Logger) *Reader` and method `(*Reader) Accounts() ([]wire.AccountUsage, *string)`. This satisfies the `state.AccountsProvider` interface defined in Task 4. Returns `(nil, nil)` when the file is missing, empty of accounts, wrong schema, or malformed.

- [ ] **Step 1: Write the failing test**

Append to `server-go/internal/claudeswap/reader_test.go`. First extend the existing import block from `import "math"` ... to:

```go
import (
	"math"
	"os"
	"path/filepath"
	"testing"
	"time"
)
```

Then append these functions:

```go
func TestReaderReadsFileAndReportsUpdatedAt(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "accounts.json")
	if err := os.WriteFile(path, []byte(sampleTwoAccounts), 0o600); err != nil {
		t.Fatal(err)
	}
	r := NewReader(path, nil)
	accts, updated := r.Accounts()
	if len(accts) != 2 {
		t.Fatalf("len = %d, want 2", len(accts))
	}
	if updated == nil || *updated == "" {
		t.Fatal("expected non-nil accounts_updated_at from file mtime")
	}
}

func TestReaderMissingFileReturnsNil(t *testing.T) {
	r := NewReader(filepath.Join(t.TempDir(), "nope.json"), nil)
	accts, updated := r.Accounts()
	if accts != nil || updated != nil {
		t.Fatalf("missing file → (nil,nil), got (%v,%v)", accts, updated)
	}
}

func TestReaderReparsesOnMtimeChange(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "accounts.json")
	if err := os.WriteFile(path, []byte(`{"schemaVersion":1,"accounts":[
	  {"number":1,"email":"a@b.com","active":true,"usageStatus":"ok","usage":null}]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	r := NewReader(path, nil)
	r.checkEvery = 0 // disable throttle for the test
	if accts, _ := r.Accounts(); len(accts) != 1 {
		t.Fatalf("first read len = %d, want 1", len(accts))
	}
	// Rewrite with two accounts and a newer mtime.
	future := time.Now().Add(2 * time.Second)
	if err := os.WriteFile(path, []byte(sampleTwoAccounts), 0o600); err != nil {
		t.Fatal(err)
	}
	_ = os.Chtimes(path, future, future)
	if accts, _ := r.Accounts(); len(accts) != 2 {
		t.Fatalf("after rewrite len = %d, want 2", len(accts))
	}
}

func TestReaderWrongSchemaReturnsNil(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "accounts.json")
	_ = os.WriteFile(path, []byte(`{"schemaVersion":9,"accounts":[]}`), 0o600)
	r := NewReader(path, nil)
	if accts, updated := r.Accounts(); accts != nil || updated != nil {
		t.Fatalf("wrong schema → (nil,nil), got (%v,%v)", accts, updated)
	}
}
```

Note: Task 2's test file imports only `math` and `testing`. This step's import block replaces that with the five imports shown above (`math`, `os`, `path/filepath`, `testing`, `time`).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server-go && go test ./internal/claudeswap/ -run TestReader -v`
Expected: FAIL — `NewReader`/`Reader` undefined.

- [ ] **Step 3: Add the `Reader` type**

Append to `server-go/internal/claudeswap/reader.go` (and add `"log/slog"`, `"os"`, `"sync"` to imports):

```go
// Reader loads the claude-swap accounts file, caching the parsed result and
// re-reading only when the file's mtime changes. Concurrency-safe. All checks
// are throttled to at most once per checkEvery to keep hot burn-event paths
// cheap.
type Reader struct {
	path       string
	logger     *slog.Logger
	checkEvery time.Duration

	mu            sync.Mutex
	cachedAccts   []wire.AccountUsage
	cachedUpdated *string
	lastMod       time.Time
	lastCheck     time.Time
	checked       bool
}

// NewReader builds a Reader for the given accounts file path.
func NewReader(path string, logger *slog.Logger) *Reader {
	if logger == nil {
		logger = slog.Default()
	}
	return &Reader{path: path, logger: logger, checkEvery: 2 * time.Second}
}

// Accounts returns the current accounts and their file mtime (RFC3339), or
// (nil, nil) when the file is absent, malformed, wrong-schema, or has no
// accounts. Never logs emails — count only.
func (r *Reader) Accounts() ([]wire.AccountUsage, *string) {
	r.mu.Lock()
	defer r.mu.Unlock()

	now := time.Now()
	if r.checked && now.Sub(r.lastCheck) < r.checkEvery {
		return r.cachedAccts, r.cachedUpdated
	}
	r.checked = true
	r.lastCheck = now

	info, err := os.Stat(r.path)
	if err != nil {
		r.cachedAccts, r.cachedUpdated, r.lastMod = nil, nil, time.Time{}
		return nil, nil
	}
	if !r.lastMod.IsZero() && info.ModTime().Equal(r.lastMod) {
		return r.cachedAccts, r.cachedUpdated
	}

	data, err := os.ReadFile(r.path)
	if err != nil {
		return r.cachedAccts, r.cachedUpdated // keep last-good on a transient read error
	}
	accts, perr := parseAccounts(data)
	r.lastMod = info.ModTime()
	if perr != nil {
		r.logger.Debug("claude-swap accounts parse failed", "err", perr)
		r.cachedAccts, r.cachedUpdated = nil, nil
		return nil, nil
	}
	r.cachedAccts = accts
	if accts == nil {
		r.cachedUpdated = nil
	} else {
		u := wire.FormatTime(info.ModTime().UTC())
		r.cachedUpdated = &u
	}
	r.logger.Debug("claude-swap accounts loaded", "count", len(accts))
	return r.cachedAccts, r.cachedUpdated
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd server-go && go test ./internal/claudeswap/ -v`
Expected: PASS (all tests, including Task 2's).

- [ ] **Step 5: Commit**

```bash
git add server-go/internal/claudeswap/reader.go server-go/internal/claudeswap/reader_test.go
git commit -m "feat(claudeswap): mtime-cached Reader with Accounts() accessor"
```

---

### Task 4: state — `AccountsProvider` + snapshot decoration (Go)

**Files:**
- Modify: `server-go/internal/state/usage_state.go` (add interface + field + setter + `decorateAccounts`; rename `Refresh`→`refreshInner`, `IngestEvent`→`ingestEventInner`, `Latest`→`latestInner`; add thin public wrappers)
- Test: `server-go/internal/state/accounts_test.go` (create)

**Interfaces:**
- Consumes: any `AccountsProvider` (Task 3's `*claudeswap.Reader` satisfies it).
- Produces: `state.AccountsProvider` interface (`Accounts() ([]wire.AccountUsage, *string)`), `(*State).SetAccountsProvider(AccountsProvider)`. Public `Refresh`/`IngestEvent`/`Latest` signatures unchanged. Used by Task 5.

**Deadlock note:** `ingestEventInner`/`latestInner` return while holding `s.mu`. Decoration must run in the OUTER public wrapper, after the inner method has unlocked, because `decorateAccounts` briefly re-locks `s.mu` (sync.Mutex is not reentrant).

- [ ] **Step 1: Write the failing test**

Create `server-go/internal/state/accounts_test.go`:

```go
package state

import (
	"context"
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server-go && go test ./internal/state/ -run 'TestIngestEventDecorates|TestNoProvider|TestCodexNever' -v`
Expected: FAIL — `SetAccountsProvider` undefined.

- [ ] **Step 3: Rename inner methods + add decoration**

In `server-go/internal/state/usage_state.go`:

(a) Add the field to the `State` struct (after `localUsage LocalSnapshotter` around line 39):

```go
	accounts AccountsProvider
```

(b) Add the interface (near `LocalSnapshotter`, around line 78):

```go
// AccountsProvider optionally supplies per-account usage rows to attach to a
// Claude snapshot (claude-swap integration). Implemented by
// internal/claudeswap.Reader.
type AccountsProvider interface {
	Accounts() ([]wire.AccountUsage, *string)
}
```

(c) Add setter + decorator + public wrappers (place near `SetLocalSnapshotter`, around line 108):

```go
// SetAccountsProvider configures the per-account usage source (Claude only).
func (s *State) SetAccountsProvider(p AccountsProvider) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.accounts = p
}

// decorateAccounts attaches accounts[] to a Claude snapshot. No-op for Codex
// or when no provider is set. MUST be called with s.mu UNLOCKED.
func (s *State) decorateAccounts(snap wire.UsageSnapshot) wire.UsageSnapshot {
	if snap.Provider != wire.ProviderClaude {
		return snap
	}
	s.mu.Lock()
	ap := s.accounts
	s.mu.Unlock()
	if ap == nil {
		return snap
	}
	accts, updated := ap.Accounts()
	snap.Accounts = accts
	snap.AccountsUpdated = updated
	return snap
}

// Refresh runs the fetch/cache/sticky pipeline, then attaches accounts[].
func (s *State) Refresh(ctx context.Context, now time.Time) UsageUpdate {
	u := s.refreshInner(ctx, now)
	u.Snapshot = s.decorateAccounts(u.Snapshot)
	return u
}

// IngestEvent records a token event, then attaches accounts[].
func (s *State) IngestEvent(ev jsonl.TokenEvent, now time.Time) wire.UsageSnapshot {
	return s.decorateAccounts(s.ingestEventInner(ev, now))
}

// Latest returns the cached snapshot with live burn + accounts[].
func (s *State) Latest(now time.Time) wire.UsageSnapshot {
	return s.decorateAccounts(s.latestInner(now))
}
```

(d) Rename the three existing methods to their inner forms (signatures otherwise unchanged):
- `func (s *State) Refresh(` → `func (s *State) refreshInner(` (around line 188)
- `func (s *State) IngestEvent(` → `func (s *State) ingestEventInner(` (around line 113)
- `func (s *State) Latest(` → `func (s *State) latestInner(` (around line 150)

No internal callers reference these by the public name (tryLocalSnapshot is called by refreshInner and is unchanged), so renaming is safe.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server-go && go test ./internal/state/ -v`
Expected: PASS (new accounts tests + all existing state tests).

- [ ] **Step 5: Commit**

```bash
git add server-go/internal/state/usage_state.go server-go/internal/state/accounts_test.go
git commit -m "feat(state): decorate Claude snapshots with claude-swap accounts[]"
```

---

### Task 5: Wire the reader into the daemon (Go)

**Files:**
- Modify: `server-go/cmd/daemon/main.go` (import + env + `SetAccountsProvider`)

**Interfaces:**
- Consumes: `claudeswap.NewReader` (Task 3), `state.SetAccountsProvider` (Task 4).
- Produces: env vars `TOKEN_USAGE_CLAUDE_SWAP_ACCOUNTS` (path override) and `TOKEN_USAGE_DISABLE_CLAUDE_SWAP` (set `1` to disable).

- [ ] **Step 1: Add the import**

In `server-go/cmd/daemon/main.go` import block (after the `codexlb` import, line 23):

```go
	"github.com/codemoo/token-terrier/server-go/internal/claudeswap"
```

- [ ] **Step 2: Wire the provider**

Immediately after `codexState.SetLocalSnapshotter(codexlb.NewSnapshotter(producer, logger))` (line 92), add:

```go
	if os.Getenv("TOKEN_USAGE_DISABLE_CLAUDE_SWAP") != "1" {
		swapPath := strings.TrimSpace(os.Getenv("TOKEN_USAGE_CLAUDE_SWAP_ACCOUNTS"))
		if swapPath == "" {
			swapPath = filepath.Join(home, ".config", "token-usage", "claude-swap-accounts.json")
		}
		claudeState.SetAccountsProvider(claudeswap.NewReader(swapPath, logger))
	}
```

(`home`, `os`, `strings`, `filepath` are already imported and in scope.)

- [ ] **Step 3: Build + verify no accounts when file absent**

```bash
cd server-go && go build ./cmd/daemon && go test ./...
```
Expected: build succeeds, all tests pass.

Manual smoke (file absent → byte-identical to today):

```bash
cd server-go
TOKEN_USAGE_PORT=18999 TOKEN_USAGE_DISABLE_PPROF=1 TOKEN_USAGE_CLAUDE_SWAP_ACCOUNTS=/tmp/does-not-exist.json ./daemon &
DPID=$!; sleep 1
TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/token-usage/tokens.json'))['claude'])")
curl -s -H "Authorization: Bearer $TOK" http://127.0.0.1:18999/claude/snapshot | python3 -c "import sys,json;d=json.load(sys.stdin);print('accounts key present:', 'accounts' in d)"
kill $DPID
```
Expected: `accounts key present: False`.

- [ ] **Step 4: Verify accounts appear when a sample file exists**

```bash
cd server-go
cat > /tmp/cswap-sample.json <<'EOF'
{"schemaVersion":1,"activeAccountNumber":2,"accounts":[
 {"number":1,"email":"a@b.com","active":false,"usageStatus":"ok","usage":{"fiveHour":{"pct":7.0,"resetsAt":"2026-07-03T12:00:00Z"},"sevenDay":{"pct":29.0,"resetsAt":"2026-07-04T18:00:00Z"}}},
 {"number":2,"email":"c@d.com","active":true,"usageStatus":"ok","usage":{"fiveHour":{"pct":50.0,"resetsAt":"2026-07-03T12:00:00Z"},"sevenDay":{"pct":80.0,"resetsAt":"2026-07-04T18:00:00Z"}}}]}
EOF
TOKEN_USAGE_PORT=18999 TOKEN_USAGE_DISABLE_PPROF=1 TOKEN_USAGE_CLAUDE_SWAP_ACCOUNTS=/tmp/cswap-sample.json ./daemon &
DPID=$!; sleep 1
TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/token-usage/tokens.json'))['claude'])")
curl -s -H "Authorization: Bearer $TOK" http://127.0.0.1:18999/claude/snapshot | python3 -c "import sys,json;d=json.load(sys.stdin);print('n accounts:',len(d.get('accounts',[])));print('acct0 5h used_pct:',d['accounts'][0]['five_hour']['used_pct'])"
kill $DPID
```
Expected: `n accounts: 2` and `acct0 5h used_pct: 0.07`.

- [ ] **Step 5: Commit**

```bash
git add server-go/cmd/daemon/main.go
git commit -m "feat(daemon): wire claude-swap accounts reader into Claude state"
```

---

### Task 6: Swift decode — `AccountUsage`/`AccountWindow` + snapshot fields (Swift)

**Files:**
- Modify: `Sources/TokenUsageCore/State/Snapshot.swift` (add two structs; add two optional fields + CodingKeys + init defaults to `UsageSnapshot`)
- Test: `Tests/TokenUsageCoreTests/WireDecodeTests.swift` (add a decode test)

**Interfaces:**
- Produces: `AccountUsage`, `AccountWindow` (Codable/Equatable/Sendable) and `UsageSnapshot.accounts: [AccountUsage]?` / `UsageSnapshot.accountsUpdatedAt: String?`. Consumed by Task 7.

- [ ] **Step 1: Write the failing test**

Add to `Tests/TokenUsageCoreTests/WireDecodeTests.swift` (inside the existing test type; mirror the file's existing XCTest/Testing style):

```swift
func testDecodesClaudeAccounts() throws {
    let json = """
    {"schema":1,"seq":1,"generated_at_utc":"2026-07-03T09:00:00.000Z",
     "producer_id":"h","producer_tz":"UTC","provider":"claude",
     "burn_rate_per_min":0,"burn_state":"idle","today_total_tokens":0,"today_sessions":0,
     "rolling_5h":{"used_pct":0,"remaining_seconds":0,"resets_at":null},
     "weekly":{"used_pct":0,"remaining_seconds":0,"resets_at":null},
     "quota_windows":[],"credits":null,
     "extras":{"login_method":null,"account_email":null,"rate_limit_tier":null,"extra_rate_windows":[]},
     "status":{"state":"ok","data_source":"api_only","stale":false},
     "accounts":[
       {"number":1,"email":"a@b.com","active":false,"status":"ok",
        "five_hour":{"used_pct":0.07,"resets_at":"2026-07-03T12:00:00.000Z"},
        "seven_day":{"used_pct":0.29,"resets_at":null}},
       {"number":2,"email":"c@d.com","active":true,"status":"api_key",
        "five_hour":null,"seven_day":null}],
     "accounts_updated_at":"2026-07-03T08:55:00.000Z"}
    """
    let snap = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
    XCTAssertEqual(snap.accounts?.count, 2)
    XCTAssertEqual(snap.accounts?[0].email, "a@b.com")
    XCTAssertEqual(snap.accounts?[0].fiveHour?.usedPct, 0.07)
    XCTAssertEqual(snap.accounts?[1].status, "api_key")
    XCTAssertNil(snap.accounts?[1].fiveHour)
    XCTAssertEqual(snap.accountsUpdatedAt, "2026-07-03T08:55:00.000Z")
}

func testDecodesSnapshotWithoutAccounts() throws {
    let json = """
    {"schema":1,"seq":1,"generated_at_utc":"2026-07-03T09:00:00.000Z",
     "producer_id":"h","producer_tz":"UTC","provider":"claude",
     "burn_rate_per_min":0,"burn_state":"idle","today_total_tokens":0,"today_sessions":0,
     "rolling_5h":{"used_pct":0,"remaining_seconds":0,"resets_at":null},
     "weekly":{"used_pct":0,"remaining_seconds":0,"resets_at":null},
     "quota_windows":[],"credits":null,
     "extras":{"login_method":null,"account_email":null,"rate_limit_tier":null,"extra_rate_windows":[]},
     "status":{"state":"ok","data_source":"api_only","stale":false}}
    """
    let snap = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
    XCTAssertNil(snap.accounts)
    XCTAssertNil(snap.accountsUpdatedAt)
}
```

> If `WireDecodeTests.swift` uses swift-testing (`@Test`/`#expect`) rather than XCTest, translate these two into that style to match the file.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WireDecodeTests`
Expected: FAIL — `accounts`/`accountsUpdatedAt` not members of `UsageSnapshot`.

- [ ] **Step 3: Add the Swift types and fields**

In `Sources/TokenUsageCore/State/Snapshot.swift`, before `UsageSnapshot` (after the `Credits` struct, around line 60), add:

```swift
/// One quota window for a single claude-swap account.
public struct AccountWindow: Codable, Equatable, Sendable {
    public let usedPct: Double
    public let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case usedPct = "used_pct"
        case resetsAt = "resets_at"
    }

    public init(usedPct: Double, resetsAt: String?) {
        self.usedPct = usedPct
        self.resetsAt = resetsAt
    }
}

/// One claude-swap-managed Claude account's usage (menu-bar per-account rows).
public struct AccountUsage: Codable, Equatable, Sendable {
    public let number: Int
    public let email: String
    public let active: Bool
    public let status: String
    public let fiveHour: AccountWindow?
    public let sevenDay: AccountWindow?

    enum CodingKeys: String, CodingKey {
        case number
        case email
        case active
        case status
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    public init(number: Int, email: String, active: Bool, status: String,
                fiveHour: AccountWindow?, sevenDay: AccountWindow?) {
        self.number = number
        self.email = email
        self.active = active
        self.status = status
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}
```

In `UsageSnapshot`, add two stored properties after `public let status: SnapshotStatus` (line 131):

```swift
    public let accounts: [AccountUsage]?
    public let accountsUpdatedAt: String?
```

Add to `CodingKeys` (after `case status`, line 149):

```swift
        case accounts
        case accountsUpdatedAt = "accounts_updated_at"
```

Add to the memberwise `init` — new parameters with defaults (after `status: SnapshotStatus)` in the signature, line 168, insert before the closing `)`):

```swift
        status: SnapshotStatus,
        accounts: [AccountUsage]? = nil,
        accountsUpdatedAt: String? = nil)
```

And assign in the init body (after `self.status = status`, line 185):

```swift
        self.accounts = accounts
        self.accountsUpdatedAt = accountsUpdatedAt
```

(The `degraded(...)` factory keeps working unchanged — the new params default to nil. Synthesized `Codable` decodes absent optional keys as nil.)

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WireDecodeTests`
Expected: PASS (both new tests + existing decode tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/TokenUsageCore/State/Snapshot.swift Tests/TokenUsageCoreTests/WireDecodeTests.swift
git commit -m "feat(core): decode additive Claude accounts[] in UsageSnapshot"
```

---

### Task 7: Menu bar — per-account rows in the Claude card (Swift)

**Files:**
- Modify: `Sources/token-run-menubar/MenuBarContentView.swift` (add accounts section + a pure `accountStatusLabel` helper)
- Test: `Tests/TokenUsageCoreTests/` — add a tiny test for the pure helper only if the helper is placed in `TokenUsageCore`. To keep it testable, put `accountStatusLabel(_:)` as a `public` free function in `Sources/TokenUsageCore/State/Snapshot.swift` and test it.

**Interfaces:**
- Consumes: `UsageSnapshot.accounts`, `AccountUsage`, `AccountWindow` (Task 6).
- Produces: `public func accountStatusLabel(_ status: String) -> String?` in TokenUsageCore (nil when status == "ok"). UI rendering has no downstream consumers.

- [ ] **Step 1: Write the failing test for the pure helper**

Add to `Tests/TokenUsageCoreTests/WireDecodeTests.swift` (or a suitable existing test file):

```swift
func testAccountStatusLabel() {
    XCTAssertNil(accountStatusLabel("ok"))
    XCTAssertEqual(accountStatusLabel("api_key"), "할당량 없음")
    XCTAssertEqual(accountStatusLabel("token_expired"), "토큰 만료")
    XCTAssertEqual(accountStatusLabel("keychain_unavailable"), "키체인 잠김")
    XCTAssertEqual(accountStatusLabel("no_credentials"), "자격증명 없음")
    XCTAssertEqual(accountStatusLabel("unavailable"), "조회 실패")
    XCTAssertEqual(accountStatusLabel("something_new"), "조회 실패")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter testAccountStatusLabel`
Expected: FAIL — `accountStatusLabel` undefined.

- [ ] **Step 3: Add the pure helper**

Append to `Sources/TokenUsageCore/State/Snapshot.swift` (top level, outside any type):

```swift
/// Human-readable Korean label for a non-ok claude-swap account status.
/// Returns nil when status == "ok" (render usage bars instead).
public func accountStatusLabel(_ status: String) -> String? {
    switch status {
    case "ok": return nil
    case "api_key": return "할당량 없음"
    case "token_expired": return "토큰 만료"
    case "keychain_unavailable": return "키체인 잠김"
    case "no_credentials": return "자격증명 없음"
    default: return "조회 실패"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter testAccountStatusLabel`
Expected: PASS.

- [ ] **Step 5: Render the accounts section**

In `Sources/token-run-menubar/MenuBarContentView.swift`, inside `providerCard`, in the OK branch (the `else` after `degradedMessage`), after the credits block (line 72, before the closing `}` of that `else` at line 73), add:

```swift
                    if provider == .claude,
                       let accounts = snapshot.accounts, !accounts.isEmpty {
                        Divider().padding(.vertical, 2)
                        ForEach(accounts, id: \.number) { account in
                            accountRow(account)
                        }
                    }
```

Then add these two helper methods to `MenuBarContentView` (after `metricsRow`, around line 94):

```swift
    @ViewBuilder
    private func accountRow(_ account: AccountUsage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: account.active ? "largecircle.fill.circle" : "circle")
                    .font(.caption2)
                    .foregroundStyle(account.active ? Color.accentColor : .secondary)
                Text(account.email)
                    .font(.caption2)
                    .foregroundStyle(account.active ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            if let label = accountStatusLabel(account.status) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                accountMiniBar(label: "5h", window: account.fiveHour)
                accountMiniBar(label: "주간", window: account.sevenDay)
            }
        }
    }

    @ViewBuilder
    private func accountMiniBar(label: String, window: AccountWindow?) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            ProgressView(value: window?.usedPct ?? 0)
                .progressViewStyle(.linear)
            Text("\(Int((window?.usedPct ?? 0) * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
    }
```

- [ ] **Step 6: Build the app + verify test suite**

Run: `swift build && swift test`
Expected: build succeeds; all tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/token-run-menubar/MenuBarContentView.swift Sources/TokenUsageCore/State/Snapshot.swift Tests/TokenUsageCoreTests/WireDecodeTests.swift
git commit -m "feat(menubar): render per-account Claude usage rows"
```

---

### Task 8: Refresher script + installer (shell + launchd)

**Files:**
- Create: `scripts/claude-swap-refresh.sh`
- Create: `scripts/install-claude-swap-refresh.sh`

**Interfaces:**
- Produces: `~/.config/token-usage/claude-swap-accounts.json` (0600), refreshed on a schedule. Consumed at runtime by Task 5's reader.

- [ ] **Step 1: Write the refresher script**

Create `scripts/claude-swap-refresh.sh`:

```sh
#!/bin/sh
# Refresh the claude-swap accounts snapshot that token-terrier reads.
# Runs `cswap --list --json` and atomically writes it to the accounts file.
# The daemon NEVER runs cswap itself — this script is the only thing that does.
# Never prints emails / account data (privacy).
set -eu

CSWAP="${CSWAP_BIN:-$HOME/.local/bin/cswap}"
OUT="${TOKEN_USAGE_CLAUDE_SWAP_ACCOUNTS:-$HOME/.config/token-usage/claude-swap-accounts.json}"
LOCK="${OUT}.lock"

# Single-flight: if a previous run is still going (e.g. cswap blocked on a
# Keychain prompt), skip this tick rather than pile up. The stale file just
# ages; the daemon marks it accordingly. Never blocks anything else.
if ! mkdir "$LOCK" 2>/dev/null; then
	exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

if [ ! -x "$CSWAP" ]; then
	exit 0
fi

mkdir -p "$(dirname "$OUT")"
TMP="$(mktemp "${OUT}.XXXXXX")"

# Optional watchdog: kill cswap if it hangs (no `timeout` on stock macOS).
"$CSWAP" --list --json >"$TMP" 2>/dev/null &
CPID=$!
( sleep 25; kill "$CPID" 2>/dev/null || true ) &
WPID=$!
if wait "$CPID" 2>/dev/null && [ -s "$TMP" ]; then
	chmod 600 "$TMP"
	mv -f "$TMP" "$OUT"
else
	rm -f "$TMP"   # keep last-good file on failure/empty/timeout
fi
kill "$WPID" 2>/dev/null || true
```

- [ ] **Step 2: Verify the refresher runs and writes the file**

```bash
chmod +x scripts/claude-swap-refresh.sh
TOKEN_USAGE_CLAUDE_SWAP_ACCOUNTS=/tmp/claude-swap-accounts.json ./scripts/claude-swap-refresh.sh
python3 -c "import json;d=json.load(open('/tmp/claude-swap-accounts.json'));print('schemaVersion',d['schemaVersion'],'accounts',len(d['accounts']))"
ls -l /tmp/claude-swap-accounts.json   # expect -rw------- (0600)
```
Expected: `schemaVersion 1 accounts 2` and 0600 perms. (Requires `cswap` installed; on this Mac it is.)

Run shellcheck if available: `shellcheck scripts/claude-swap-refresh.sh` (expect no errors).

- [ ] **Step 3: Write the installer**

Create `scripts/install-claude-swap-refresh.sh`:

```sh
#!/bin/sh
# Install a LaunchAgent that runs scripts/claude-swap-refresh.sh every 5 min,
# keeping the claude-swap accounts file fresh for token-terrier.
# The generated plist is machine-local (untracked); this generator is generic.
set -eu

LABEL="ai.openclaw.token-usage-claude-swap-refresh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/scripts/claude-swap-refresh.sh"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
INTERVAL="${REFRESH_INTERVAL:-300}"
LOGDIR="${HOME}/Library/Logs/token-terrier"

chmod +x "$SCRIPT"
mkdir -p "$(dirname "$PLIST")" "$LOGDIR"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/sh</string>
		<string>${SCRIPT}</string>
	</array>
	<key>StartInterval</key><integer>${INTERVAL}</integer>
	<key>RunAtLoad</key><true/>
	<key>StandardOutPath</key><string>${LOGDIR}/claude-swap-refresh.out.log</string>
	<key>StandardErrorPath</key><string>${LOGDIR}/claude-swap-refresh.err.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/${LABEL}"
echo "installed ${LABEL} (every ${INTERVAL}s)"
```

- [ ] **Step 4: Commit (installer is generic; do NOT commit any generated plist)**

```bash
chmod +x scripts/install-claude-swap-refresh.sh
git add scripts/claude-swap-refresh.sh scripts/install-claude-swap-refresh.sh
git commit -m "feat(scripts): claude-swap accounts refresher + launchd installer"
```

---

### Task 9: Document the new data source

**Files:**
- Modify: `docs/data-sources.md` (add a claude-swap subsection under section (A))

**Interfaces:** none (docs only).

- [ ] **Step 1: Add the documentation**

In `docs/data-sources.md`, after the Claude API subsection under "(A) Quota / 5h / 주간 / credits — OAuth API", add:

```markdown
### Claude 계정별 사용량 — claude-swap (선택)

`claude-swap`(`cswap`) 이 설치돼 있고 refresher 가 돌면, Claude 스냅샷에 계정별
사용량(`accounts[]`)이 additive 로 붙는다. **데몬은 `cswap` 을 실행하지 않는다** —
별도 launchd job(`scripts/claude-swap-refresh.sh`, 기본 5분)이
`cswap --list --json`(schema v1) 을 `~/.config/token-usage/claude-swap-accounts.json`
(0600) 에 atomic 하게 기록하고, 데몬의 `internal/claudeswap` reader 가 그 파일만 읽는다.

- 변환: cswap `pct`(0~100) → `used_pct`(0~1), `resetsAt` → 정규 millis-Z.
- guard: `schemaVersion==1` 만 수용, 계정 0개/파일 없음/파싱 실패 시 accounts 미포함(기존 동작).
- top-line(5h/주간/burn)은 활성 계정(`~/.claude`) 기준 그대로. accounts[] 는 표시 전용.
- env: `TOKEN_USAGE_CLAUDE_SWAP_ACCOUNTS`(경로 override), `TOKEN_USAGE_DISABLE_CLAUDE_SWAP=1`(비활성).
- 설치: `scripts/install-claude-swap-refresh.sh`. 로그/응답에 email 미기록.
```

- [ ] **Step 2: Commit**

```bash
git add docs/data-sources.md
git commit -m "docs: document claude-swap per-account data source"
```

---

### Task 10: Local rollout on this Mac + end-to-end verification

**Files:** none (deployment).

**Context:** the live daemon on this Mac is the Go binary at `/private/tmp/token-terrier-daemon`, launched via nohup (was under tmux session `boxing`) with `TOKEN_USAGE_PORT=18910 TOKEN_USAGE_DISABLE_PPROF=1`, logging to `/private/tmp/token-terrier-daemon.log`. The menu bar app `app.token-terrier.menubar` connects via loopback SSE.

- [ ] **Step 1: Build the updated Go daemon into place**

```bash
cd /Users/hwanmooy/Dropbox/dev/token-run/server-go
go build -o /private/tmp/token-terrier-daemon.new ./cmd/daemon
```
Expected: builds cleanly.

- [ ] **Step 2: Install the refresher and confirm the accounts file**

```bash
cd /Users/hwanmooy/Dropbox/dev/token-run
./scripts/install-claude-swap-refresh.sh
sleep 2
python3 -c "import json;d=json.load(open('$HOME/.config/token-usage/claude-swap-accounts.json'));print('accounts',len(d['accounts']),'active',d['activeAccountNumber'])"
```
Expected: `accounts 2 active 2` (or current count).

- [ ] **Step 3: Swap the binary and restart the daemon**

```bash
# stop the running daemon
OLDPID=$(pgrep -f '/private/tmp/token-terrier-daemon$' || true)
[ -n "$OLDPID" ] && kill "$OLDPID"
for i in $(seq 1 20); do pgrep -f '/private/tmp/token-terrier-daemon$' >/dev/null || break; sleep 0.5; done
mv -f /private/tmp/token-terrier-daemon.new /private/tmp/token-terrier-daemon
cd /Users/hwanmooy/Dropbox/dev/token-run/server-go
TOKEN_USAGE_PORT=18910 TOKEN_USAGE_DISABLE_PPROF=1 nohup /private/tmp/token-terrier-daemon >> /private/tmp/token-terrier-daemon.log 2>&1 &
disown
sleep 2
curl -s http://127.0.0.1:18910/healthz
```
Expected: `{"ok":true}`.

- [ ] **Step 4: Verify accounts land in the live Claude snapshot**

```bash
TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/token-usage/tokens.json'))['claude'])")
curl -s -H "Authorization: Bearer $TOK" http://127.0.0.1:18910/claude/snapshot \
  | python3 -c "import sys,json;d=json.load(sys.stdin);a=d.get('accounts',[]);print('n',len(a));[print(x['number'],x['active'],round((x.get('five_hour') or {}).get('used_pct',0)*100),'%') for x in a]"
```
Expected: `n 2` with each account's 5h percentage. (Emails intentionally not printed.)

- [ ] **Step 5: Verify the menu bar shows both accounts**

Open the Token Terrier menu bar dropdown. Under **Claude Code**, confirm: the top-line 5h/주간 bars + running dog are unchanged (active account), and below them two account rows appear — each with email + 5h/주간 mini-bars, the active one marked. Confirm Codex section is unchanged.

If the app is running an older build, rebuild + relaunch it:
```bash
cd /Users/hwanmooy/Dropbox/dev/token-run
swift build -c release
# relaunch the menu bar app however it is normally launched (e.g. open the built .app)
```

- [ ] **Step 6: Confirm no emails in logs**

```bash
grep -iE "@|email" /private/tmp/token-terrier-daemon.log | tail -5 || echo "no email lines — good"
tail -3 "$HOME/Library/Logs/token-terrier/claude-swap-refresh.err.log" 2>/dev/null || true
```
Expected: no account emails in daemon logs.

- [ ] **Step 7: Final full test sweep + commit any doc note**

```bash
cd /Users/hwanmooy/Dropbox/dev/token-run
swift test && (cd server-go && go test ./...)
```
Expected: all green. (No commit needed for rollout unless notes were added.)

---

## Self-Review

**1. Spec coverage:**
- Refresher (launchd + scripts) → Task 8. ✓
- Accounts contract file (path, 0600, atomic, schema v1 raw) → Task 8 (writer) + Task 3 (reader path/guard). ✓
- Go reader (`internal/claudeswap`, schema guard, pct/100, resets normalize, mtime cache, count-only logs) → Tasks 2–3. ✓
- Wire additive fields (`accounts,omitempty` + `accounts_updated_at`) → Task 1. ✓
- State decoration (Claude-only, top-line unchanged, deadlock-safe wrappers) → Task 4. ✓
- Daemon wiring + env (`TOKEN_USAGE_CLAUDE_SWAP_ACCOUNTS`, `TOKEN_USAGE_DISABLE_CLAUDE_SWAP`) → Task 5. ✓
- Swift decode (optional, byte-identical when absent) → Task 6. ✓
- Menu bar per-account rendering + non-ok status labels + email shown → Task 7. ✓
- Edge cases: pct/100 (T2), status≠ok→nil windows (T2/T7), schema≠1 (T2/T3), 0 accounts (T2/T3), reset parse fail (T2), file missing/stale (T3), active identity (top-line untouched by design, T4). ✓
- Rate-limit isolation (daemon never fetches; refresher every 300s) → Tasks 5/8. ✓
- Privacy (no email logs) → Tasks 3/8, verified T10 step 6. ✓
- docs/data-sources.md → Task 9. ✓
- Local rollout + verify 2 accounts → Task 10. ✓

**2. Placeholder scan:** No TBD/TODO. The `import_extra_marker` in Task 3 is explicitly flagged as a placeholder to delete, with the real imports named. All code steps contain full code.

**3. Type consistency:** `Accounts()([]wire.AccountUsage, *string)` is identical in the `claudeswap.Reader` (T3), the `state.AccountsProvider` interface (T4), and the `fakeAccounts` test double (T4). Wire field names (`used_pct`, `five_hour`, `seven_day`, `accounts_updated_at`) match between Go (T1), the daemon JSON (T5 smoke), and Swift CodingKeys (T6). `accountStatusLabel` signature matches between T7 helper and its test.

## Execution Handoff

Choose an execution approach after review.
