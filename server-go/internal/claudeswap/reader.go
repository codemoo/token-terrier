// Package claudeswap reads a claude-swap `--list --json` snapshot file and
// exposes per-account Claude usage. It never executes cswap or does network
// I/O — a separate launchd job keeps the file fresh (see scripts/).
package claudeswap

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"sync"
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
