// Package codexaccounts reads a codex-lb-accounts derived JSON file (written
// by scripts/codex-lb-accounts-refresh.py) and exposes per-account Codex
// usage. It never logs into codex-lb or does network I/O — a separate
// launchd job keeps the file fresh (see scripts/).
package codexaccounts

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/codemoo/token-terrier/server-go/internal/wire"
)

// codex-lb-accounts derived JSON shape (schemaVersion 1). Only fields we use.
type derivedList struct {
	SchemaVersion   int              `json:"schemaVersion"`
	AccountsUpdated string           `json:"accountsUpdatedAt"`
	Accounts        []derivedAccount `json:"accounts"`
}

type derivedAccount struct {
	Number           int      `json:"number"`
	AccountID        string   `json:"accountId"`
	Email            string   `json:"email"`
	Alias            string   `json:"alias"`
	DisplayName      string   `json:"displayName"`
	Status           string   `json:"status"`
	FiveHourPct      *float64 `json:"fiveHourPct"`
	SevenDayPct      *float64 `json:"sevenDayPct"`
	ResetAtPrimary   *string  `json:"resetAtPrimary"`
	ResetAtSecondary *string  `json:"resetAtSecondary"`
	TotalTokens      *int64   `json:"totalTokens"`
	TokensPerHour    *float64 `json:"tokensPerHour"`
	LastRefreshAt    *string  `json:"lastRefreshAt"`
}

// parseAccounts converts a codex-lb-accounts derived payload to
// wire.AccountUsage. Returns (nil, nil) when there are zero accounts; error
// on malformed JSON or an unsupported schemaVersion.
func parseAccounts(data []byte) ([]wire.AccountUsage, string, error) {
	var list derivedList
	if err := json.Unmarshal(data, &list); err != nil {
		return nil, "", err
	}
	if list.SchemaVersion != 1 {
		return nil, "", fmt.Errorf("unsupported codex-lb-accounts schemaVersion %d", list.SchemaVersion)
	}
	if len(list.Accounts) == 0 {
		return nil, "", nil
	}
	out := make([]wire.AccountUsage, 0, len(list.Accounts))
	for _, a := range list.Accounts {
		acc := wire.AccountUsage{
			Number:        a.Number,
			Email:         firstNonEmpty(a.Alias, a.DisplayName, a.Email),
			Active:        isActiveStatus(a.Status),
			Status:        normalizeStatus(a.Status),
			FiveHour:      toWindow(a.FiveHourPct, a.ResetAtPrimary),
			SevenDay:      toWindow(a.SevenDayPct, a.ResetAtSecondary),
			TokensPerHour: a.TokensPerHour,
			TotalTokens:   a.TotalTokens,
			LastRefreshAt: normalizeTimestamp(a.LastRefreshAt),
		}
		out = append(out, acc)
	}
	return out, list.AccountsUpdated, nil
}

// toWindow builds an AccountWindow from a nullable used-pct and reset
// timestamp. pct is passed through as-is — the refresher (not this reader)
// is responsible for converting codex-lb's remaining-pct into used-pct.
func toWindow(pct *float64, resetsAt *string) *wire.AccountWindow {
	if pct == nil {
		return nil
	}
	return &wire.AccountWindow{
		UsedPct:  clampUnit(*pct),
		ResetsAt: normalizeTimestamp(resetsAt),
	}
}

// normalizeStatus maps codex-lb account status to the same vocabulary used
// by claude-swap accounts ("ok" for a healthy/active account). Known
// codex-lb aliases are folded so older refresher outputs and newer
// dashboard shapes render consistently.
func normalizeStatus(status string) string {
	trimmed := normalizeStatusToken(status)
	switch trimmed {
	case "active", "enabled", "healthy", "logged_in", "ok":
		return "ok"
	case "disabled", "inactive", "suspended":
		return "paused"
	case "auth_required", "auth_expired", "login_required", "reauth", "reauthrequired", "token_expired", "unauthorized":
		return "reauth_required"
	case "ratelimited":
		return "rate_limited"
	case "":
		return "unavailable"
	default:
		return trimmed
	}
}

func normalizeStatusToken(status string) string {
	trimmed := strings.ToLower(strings.TrimSpace(status))
	trimmed = strings.ReplaceAll(trimmed, "-", "_")
	trimmed = strings.ReplaceAll(trimmed, " ", "_")
	return trimmed
}

func isActiveStatus(status string) bool {
	return normalizeStatus(status) == "ok"
}

func normalizeTimestamp(raw *string) *string {
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
	if seconds, err := strconv.ParseInt(s, 10, 64); err == nil && seconds > 0 {
		out := wire.FormatTime(time.Unix(seconds, 0).UTC())
		return &out
	}
	return nil
}

func normalizeTimestampString(raw string) *string {
	return normalizeTimestamp(&raw)
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

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if trimmed := strings.TrimSpace(v); trimmed != "" {
			return trimmed
		}
	}
	return ""
}

// Reader loads the codex-lb-accounts derived file, caching the parsed result
// and re-reading only when the file's mtime changes. Concurrency-safe. All
// checks are throttled to at most once per checkEvery to keep hot burn-event
// paths cheap.
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

// NewReader builds a Reader for the given codex-lb-accounts derived file
// path.
func NewReader(path string, logger *slog.Logger) *Reader {
	if logger == nil {
		logger = slog.Default()
	}
	return &Reader{path: path, logger: logger, checkEvery: 2 * time.Second}
}

// Accounts returns the current accounts and accountsUpdatedAt, or (nil, nil)
// when the file is absent, malformed, wrong-schema, or has no accounts.
// Never logs emails — count only.
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
		if errors.Is(err, fs.ErrNotExist) {
			// Genuine absence (e.g. refresher not installed) → feature dormant.
			r.cachedAccts, r.cachedUpdated, r.lastMod = nil, nil, time.Time{}
			return nil, nil
		}
		// Transient stat error (e.g. permission flicker): keep last-good and
		// don't advance lastMod, so a later successful stat re-parses.
		return r.cachedAccts, r.cachedUpdated
	}
	if !r.lastMod.IsZero() && info.ModTime().Equal(r.lastMod) {
		return r.cachedAccts, r.cachedUpdated
	}

	data, err := os.ReadFile(r.path)
	if err != nil {
		return r.cachedAccts, r.cachedUpdated // keep last-good on a transient read error
	}
	accts, updatedAt, perr := parseAccounts(data)
	r.lastMod = info.ModTime()
	if perr != nil {
		r.logger.Debug("codex-lb accounts parse failed", "err", perr)
		return r.cachedAccts, r.cachedUpdated
	}
	r.cachedAccts = accts
	if accts == nil {
		r.cachedUpdated = nil
	} else if u := normalizeTimestampString(updatedAt); u != nil {
		r.cachedUpdated = u
	} else {
		u := wire.FormatTime(info.ModTime().UTC())
		r.cachedUpdated = &u
	}
	r.logger.Debug("codex-lb accounts loaded", "count", len(accts))
	return r.cachedAccts, r.cachedUpdated
}
