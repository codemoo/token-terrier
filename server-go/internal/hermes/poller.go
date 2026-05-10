// Package hermes polls ~/.hermes/state.db for completed/active
// LLM sessions and emits delta TokenEvents into the burn tracker.
//
// Mirrors Sources/TokenUsageCore/SQLite/HermesSQLiteWatcher.swift in spirit:
// keeps a per-session baseline of cumulative fresh tokens (input + output +
// reasoning), and on each scan emits whichever positive delta has appeared.
//
// Why we need it on top of jsonl.Poller: Hermes tracks ALL of the user's
// LLM API calls in one place — codex CLI sessions can live in both, but custom
// scripts and other tools that go through Hermes show up only here.
package hermes

import (
	"context"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/codemoo/token-terrier/server-go/internal/jsonl"
	"github.com/codemoo/token-terrier/server-go/internal/wire"
)

// Poller queries the local Hermes state database every PollInterval and emits
// TokenEvents for fresh-token deltas.
type Poller struct {
	DBPath       string
	PollInterval time.Duration

	logger *slog.Logger
	emit   func(jsonl.TokenEvent)

	mu       sync.Mutex
	baseline map[string]int // sessionID → last fresh tokens observed
	first    bool           // first tick → only baseline, don't replay history
}

// NewPoller builds a Hermes poller. Path defaults to ~/.hermes/state.db
// under the current user's home dir; override with TOKEN_USAGE_HERMES_DB.
func NewPoller(emit func(jsonl.TokenEvent), logger *slog.Logger) *Poller {
	if logger == nil {
		logger = slog.Default()
	}
	dbPath := strings.TrimSpace(os.Getenv("TOKEN_USAGE_HERMES_DB"))
	if dbPath == "" {
		home, _ := os.UserHomeDir()
		dbPath = filepath.Join(home, ".hermes", "state.db")
	}
	return &Poller{
		DBPath:       dbPath,
		PollInterval: 30 * time.Second,
		logger:       logger,
		emit:         emit,
		baseline:     map[string]int{},
		first:        true,
	}
}

// Run blocks until ctx cancels.
func (p *Poller) Run(ctx context.Context) {
	t := time.NewTicker(p.PollInterval)
	defer t.Stop()
	// Run one tick immediately to establish the baseline; without this the
	// first delta-emit happens 30 seconds after startup.
	if rows := p.tick(ctx); rows >= 0 {
		p.logger.Info("hermes poller bootstrap complete", "active_sessions", rows)
	}
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			p.tick(ctx)
		}
	}
}

// tick returns the number of active rows seen, or -1 on query failure.
func (p *Poller) tick(ctx context.Context) int {
	rows, err := p.query(ctx)
	if err != nil {
		p.logger.Debug("hermes query failed", "err", err)
		return -1
	}

	p.mu.Lock()
	wasFirst := p.first
	active := make(map[string]struct{}, len(rows))
	for _, row := range rows {
		// row.HasEnded → emit final delta and drop from baseline
		if row.HasEnded {
			if prev, ok := p.baseline[row.ID]; ok {
				p.dispatchLocked(row, prev)
				delete(p.baseline, row.ID)
			}
			continue
		}

		active[row.ID] = struct{}{}
		if prev, ok := p.baseline[row.ID]; ok {
			p.dispatchLocked(row, prev)
			p.baseline[row.ID] = row.FreshTokens
		} else {
			p.baseline[row.ID] = row.FreshTokens
			if !wasFirst {
				// New active session discovered after startup — emit
				// its full token count once. (On the very first tick
				// we just record baselines; no historical replay.)
				p.dispatchLocked(row, 0)
			}
		}
	}

	// Drop baselines for sessions no longer active and not seen as ended
	// (e.g., DB row deleted). Without this the baseline map grows.
	for id := range p.baseline {
		if _, stillActive := active[id]; !stillActive {
			delete(p.baseline, id)
		}
	}
	p.first = false
	p.mu.Unlock()
	return len(active)
}

// dispatchLocked computes the delta and emits one TokenEvent if positive.
// Caller holds p.mu.
//
// Dedup rule: skip rows whose source is already covered by another data
// stream the daemon ingests:
//
//   - codex `source='cli'`: written by `codex` CLI which ALSO appends each
//     `token_count` event to ~/.codex/sessions/.../*.jsonl. JSONLPoller picks
//     those up at 5s granularity. Counting both = ~2× over-count for the
//     same session.
//   - codex `source='discord'`, `source='web'`, etc.: NOT in JSONL, must
//     emit so non-CLI codex usage is captured.
//   - claude (anthropic): if present, let it through — Claude Code's JSONL is
//     in a different directory and uses different session keys.
func (p *Poller) dispatchLocked(row sessionRow, previous int) {
	delta := row.FreshTokens - previous
	if delta <= 0 {
		return
	}
	provider := mapProvider(row.BillingProvider)
	if provider == "" {
		return
	}
	if provider == wire.ProviderCodex && strings.EqualFold(row.Source, "cli") {
		// Already counted by jsonl.Poller — skip.
		return
	}
	p.emit(jsonl.TokenEvent{
		Provider:   provider,
		Timestamp:  time.Now(),
		Tokens:     delta,
		Model:      row.Model,
		SessionKey: "hermes:" + row.ID, // namespace sessions to avoid colliding with JSONL paths
	})
}

type sessionRow struct {
	ID              string
	Source          string // "cli", "discord", etc. — used for dedup against JSONL
	BillingProvider string
	Model           string
	FreshTokens     int
	HasEnded        bool
}

// query runs the Hermes session query with sqlite3 in read-only mode.
func (p *Poller) query(ctx context.Context) ([]sessionRow, error) {
	// Use \x01 as separator so paths/values can contain pipe / tab safely.
	const sep = "\x01"
	sql := `PRAGMA query_only=ON;SELECT id, source, billing_provider, model, input_tokens, output_tokens, reasoning_tokens, ended_at FROM sessions ORDER BY id;`
	cmd := exec.CommandContext(ctx, "sqlite3", "-readonly", "-separator", sep, p.DBPath, sql)
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}

	rows := make([]sessionRow, 0, 64)
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" {
			continue
		}
		parts := strings.Split(line, sep)
		if len(parts) < 8 {
			continue
		}
		input, _ := strconv.ParseInt(parts[4], 10, 64)
		output, _ := strconv.ParseInt(parts[5], 10, 64)
		reasoning, _ := strconv.ParseInt(parts[6], 10, 64)
		hasEnded := strings.TrimSpace(parts[7]) != ""
		rows = append(rows, sessionRow{
			ID:              parts[0],
			Source:          parts[1],
			BillingProvider: parts[2],
			Model:           parts[3],
			FreshTokens:     freshTokens(input, output, reasoning),
			HasEnded:        hasEnded,
		})
	}
	return rows, nil
}

func freshTokens(input, output, reasoning int64) int {
	var total int64
	for _, v := range []int64{input, output, reasoning} {
		if v < 0 {
			continue
		}
		total += v
	}
	if total < 0 || total > int64(int(^uint(0)>>1)) {
		return int(^uint(0) >> 1) // saturate at maxInt
	}
	return int(total)
}

// mapProvider matches Swift's lowercased substring rule: if billing_provider
// contains "codex" → codex; "anthropic" → claude; else unmapped.
func mapProvider(billingProvider string) wire.Provider {
	n := strings.ToLower(strings.TrimSpace(billingProvider))
	n = strings.ReplaceAll(n, "_", "-")
	if strings.Contains(n, "codex") {
		return wire.ProviderCodex
	}
	if strings.Contains(n, "anthropic") {
		return wire.ProviderClaude
	}
	return ""
}
