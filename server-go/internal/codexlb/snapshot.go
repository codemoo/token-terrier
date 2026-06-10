// Package codexlb asks a local codex-lb instance for aggregate upstream quota
// usage and normalizes it into Token Terrier's Codex snapshot shape.
package codexlb

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/codemoo/token-terrier/server-go/internal/wire"
)

const (
	disableEnv = "TOKEN_USAGE_DISABLE_CODEX_LB"
	defaultURL = "http://127.0.0.1:2455"
)

// Snapshotter reads codex-lb's self-service usage endpoint.
type Snapshotter struct {
	BaseURL string
	APIKey  string
	Client  *http.Client

	producer wire.ProducerInfo
	logger   *slog.Logger
}

// NewSnapshotter builds a Snapshotter. The URL defaults to the local codex-lb
// server and can be overridden with TOKEN_USAGE_CODEX_LB_URL or
// CODEX_LB_BASE_URL. API keys are read from TOKEN_USAGE_CODEX_LB_API_KEY first,
// then CODEX_LB_API_KEY.
func NewSnapshotter(producer wire.ProducerInfo, logger *slog.Logger) *Snapshotter {
	if logger == nil {
		logger = slog.Default()
	}
	baseURL := firstNonEmpty(
		os.Getenv("TOKEN_USAGE_CODEX_LB_URL"),
		os.Getenv("CODEX_LB_BASE_URL"),
		defaultURL,
	)
	apiKey := firstNonEmpty(
		os.Getenv("TOKEN_USAGE_CODEX_LB_API_KEY"),
		os.Getenv("CODEX_LB_API_KEY"),
	)
	return &Snapshotter{
		BaseURL:  normalizeBaseURL(baseURL),
		APIKey:   strings.TrimSpace(apiKey),
		Client:   &http.Client{Timeout: 5 * time.Second},
		producer: producer,
		logger:   logger,
	}
}

// Snapshot returns a normalized Codex snapshot from codex-lb if available.
// ok=false means "no codex-lb data, fall back to the normal Codex API path".
func (s *Snapshotter) Snapshot(ctx context.Context, seq int, now time.Time) (snap wire.UsageSnapshot, ok bool) {
	if os.Getenv(disableEnv) == "1" {
		return wire.UsageSnapshot{}, false
	}
	if strings.TrimSpace(s.APIKey) == "" {
		return wire.UsageSnapshot{}, false
	}
	resp, err := s.fetchUsage(ctx)
	if err != nil {
		s.logger.Debug("codex-lb usage fetch failed", "err", err)
		return wire.UsageSnapshot{}, false
	}
	snap, ok = buildSnapshot(resp, seq, s.producer, now)
	if !ok {
		return wire.UsageSnapshot{}, false
	}
	return snap, true
}

func (s *Snapshotter) fetchUsage(ctx context.Context) (usageResponse, error) {
	if strings.TrimSpace(s.BaseURL) == "" {
		return usageResponse{}, errors.New("empty codex-lb URL")
	}
	endpoint := strings.TrimRight(s.BaseURL, "/") + "/v1/usage"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return usageResponse{}, err
	}
	req.Header.Set("Authorization", "Bearer "+s.APIKey)
	req.Header.Set("Accept", "application/json")

	client := s.Client
	if client == nil {
		client = http.DefaultClient
	}
	httpResp, err := client.Do(req)
	if err != nil {
		return usageResponse{}, err
	}
	defer httpResp.Body.Close()

	if httpResp.StatusCode < 200 || httpResp.StatusCode >= 300 {
		return usageResponse{}, fmt.Errorf("codex-lb usage status %d", httpResp.StatusCode)
	}
	var decoded usageResponse
	if err := json.NewDecoder(httpResp.Body).Decode(&decoded); err != nil {
		return usageResponse{}, err
	}
	return decoded, nil
}

type usageResponse struct {
	UpstreamLimits []upstreamLimit `json:"upstream_limits"`
}

type upstreamLimit struct {
	LimitType      string  `json:"limit_type"`
	LimitWindow    string  `json:"limit_window"`
	MaxValue       float64 `json:"max_value"`
	CurrentValue   float64 `json:"current_value"`
	RemainingValue float64 `json:"remaining_value"`
	ModelFilter    *string `json:"model_filter"`
	ResetAt        *string `json:"reset_at"`
	Source         string  `json:"source"`
}

func buildSnapshot(resp usageResponse, seq int, producer wire.ProducerInfo, now time.Time) (wire.UsageSnapshot, bool) {
	if len(resp.UpstreamLimits) == 0 {
		return wire.UsageSnapshot{}, false
	}

	rolling := wire.EmptyRollingWindow()
	weekly := wire.EmptyRollingWindow()
	quotaWindows := make([]wire.QuotaWindow, 0)
	seen := false

	for _, limit := range resp.UpstreamLimits {
		if !isAggregateCreditLimit(limit) || limit.MaxValue <= 0 {
			continue
		}
		usedPct := clamp(limit.CurrentValue/limit.MaxValue, 0, 1)
		resetAt := parseResetAt(limit.ResetAt)
		window := normalizedWindow(limit.LimitWindow)
		switch window {
		case "5h":
			rolling = rollingWindow(usedPct, resetAt, now)
			seen = true
		case "7d":
			weekly = rollingWindow(usedPct, resetAt, now)
			seen = true
		default:
			quotaWindows = append(quotaWindows, quotaWindow(window, usedPct, resetAt))
			seen = true
		}
	}
	if !seen {
		return wire.UsageSnapshot{}, false
	}

	loginMethod := "codex-lb"
	return wire.UsageSnapshot{
		Schema:           1,
		Seq:              seq,
		GeneratedAtUTC:   wire.FormatTime(now),
		ProducerID:       producer.ID,
		ProducerTimeZone: producer.TimeZone,
		Provider:         wire.ProviderCodex,
		BurnState:        "idle",
		Rolling5h:        rolling,
		Weekly:           weekly,
		QuotaWindows:     quotaWindows,
		Credits:          nil,
		Extras: wire.SnapshotExtras{
			LoginMethod:      &loginMethod,
			AccountEmail:     nil,
			RateLimitTier:    nil,
			ExtraRateWindows: []json.RawMessage{},
		},
		Status: wire.SnapshotStatus{
			State:      wire.StateOK,
			DataSource: wire.DataSourceAPIOnly,
			Stale:      false,
		},
	}, true
}

func rollingWindow(usedPct float64, resetAt time.Time, now time.Time) wire.RollingWindow {
	var resets *string
	if !resetAt.IsZero() {
		s := wire.FormatTime(resetAt)
		resets = &s
	}
	return wire.RollingWindow{
		UsedPct:          usedPct,
		RemainingSeconds: remainingSeconds(resetAt, now),
		ResetsAt:         resets,
	}
}

func quotaWindow(label string, usedPct float64, resetAt time.Time) wire.QuotaWindow {
	var resets *string
	if !resetAt.IsZero() {
		s := wire.FormatTime(resetAt)
		resets = &s
	}
	return wire.QuotaWindow{
		Label:    label,
		Scope:    label,
		UsedPct:  usedPct,
		ResetsAt: resets,
	}
}

func isAggregateCreditLimit(limit upstreamLimit) bool {
	return strings.EqualFold(limit.Source, "aggregate") && strings.EqualFold(limit.LimitType, "credits")
}

func normalizedWindow(window string) string {
	w := strings.ToLower(strings.TrimSpace(window))
	switch w {
	case "5hr", "5hrs", "5hour", "5hours", "primary":
		return "5h"
	case "7day", "7days", "week", "weekly", "secondary":
		return "7d"
	case "":
		return "unknown"
	default:
		return w
	}
}

func parseResetAt(value *string) time.Time {
	if value == nil {
		return time.Time{}
	}
	raw := strings.TrimSpace(*value)
	if raw == "" {
		return time.Time{}
	}
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339} {
		if t, err := time.Parse(layout, raw); err == nil {
			return t
		}
	}
	if seconds, err := strconv.ParseInt(raw, 10, 64); err == nil && seconds > 0 {
		return time.Unix(seconds, 0).UTC()
	}
	return time.Time{}
}

func remainingSeconds(resetAt time.Time, now time.Time) int {
	if resetAt.IsZero() || !resetAt.After(now) {
		return 0
	}
	return int(math.Round(resetAt.Sub(now).Seconds()))
}

func clamp(value, minValue, maxValue float64) float64 {
	if value < minValue {
		return minValue
	}
	if value > maxValue {
		return maxValue
	}
	return value
}

func normalizeBaseURL(raw string) string {
	base := strings.TrimSpace(raw)
	if base == "" {
		return defaultURL
	}
	if parsed, err := url.Parse(base); err == nil {
		parsed.Path = strings.TrimSuffix(parsed.Path, "/v1")
		parsed.RawQuery = ""
		parsed.Fragment = ""
		return strings.TrimRight(parsed.String(), "/")
	}
	return strings.TrimRight(strings.TrimSuffix(base, "/v1"), "/")
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}
