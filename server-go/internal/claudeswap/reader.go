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
