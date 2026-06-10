package codexlb

import (
	"context"
	"math"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/codemoo/token-terrier/server-go/internal/wire"
)

func TestBuildSnapshotUsesCodexLBAggregateCreditLimits(t *testing.T) {
	now := time.Date(2026, 6, 10, 9, 55, 0, 0, time.UTC)
	reset5h := "2026-06-10T13:18:50Z"
	reset7d := "2026-06-11T00:45:02Z"
	resp := usageResponse{UpstreamLimits: []upstreamLimit{
		{
			LimitType:      "credits",
			LimitWindow:    "5h",
			MaxValue:       2175,
			CurrentValue:   602,
			RemainingValue: 1573,
			ResetAt:        &reset5h,
			Source:         "aggregate",
		},
		{
			LimitType:      "credits",
			LimitWindow:    "7d",
			MaxValue:       73080,
			CurrentValue:   53500,
			RemainingValue: 19580,
			ResetAt:        &reset7d,
			Source:         "aggregate",
		},
	}}

	snap, ok := buildSnapshot(resp, 7, wire.ProducerInfo{ID: "host", TimeZone: "UTC"}, now)
	if !ok {
		t.Fatal("expected snapshot")
	}
	if snap.Provider != wire.ProviderCodex || snap.Seq != 7 {
		t.Fatalf("unexpected identity: provider=%s seq=%d", snap.Provider, snap.Seq)
	}
	if got, want := snap.Rolling5h.UsedPct, 602.0/2175.0; math.Abs(got-want) > 0.0001 {
		t.Fatalf("rolling used pct = %v, want %v", got, want)
	}
	if got, want := snap.Weekly.UsedPct, 53500.0/73080.0; math.Abs(got-want) > 0.0001 {
		t.Fatalf("weekly used pct = %v, want %v", got, want)
	}
	if snap.Rolling5h.ResetsAt == nil || *snap.Rolling5h.ResetsAt != "2026-06-10T13:18:50.000Z" {
		t.Fatalf("rolling reset = %v", snap.Rolling5h.ResetsAt)
	}
	if snap.Extras.LoginMethod == nil || *snap.Extras.LoginMethod != "codex-lb" {
		t.Fatalf("login method = %v, want codex-lb", snap.Extras.LoginMethod)
	}
}

func TestSnapshotterFetchesV1UsageWithBearerKey(t *testing.T) {
	var gotAuth string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/usage" {
			t.Fatalf("path = %s, want /v1/usage", r.URL.Path)
		}
		gotAuth = r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
			"upstream_limits": [
				{
					"limit_type": "credits",
					"limit_window": "5h",
					"max_value": 100,
					"current_value": 25,
					"remaining_value": 75,
					"reset_at": "2026-06-10T11:00:00Z",
					"source": "aggregate"
				}
			]
		}`))
	}))
	defer server.Close()

	s := &Snapshotter{
		BaseURL:  server.URL,
		APIKey:   "test-api-key",
		Client:   server.Client(),
		producer: wire.ProducerInfo{ID: "host", TimeZone: "UTC"},
	}
	snap, ok := s.Snapshot(context.Background(), 3, time.Date(2026, 6, 10, 10, 0, 0, 0, time.UTC))
	if !ok {
		t.Fatal("expected snapshot")
	}
	if gotAuth != "Bearer test-api-key" {
		t.Fatalf("authorization = %q", gotAuth)
	}
	if got, want := snap.Rolling5h.UsedPct, 0.25; math.Abs(got-want) > 0.0001 {
		t.Fatalf("rolling used pct = %v, want %v", got, want)
	}
}

func TestSnapshotterFallsBackWithoutAPIKey(t *testing.T) {
	s := &Snapshotter{BaseURL: "http://127.0.0.1:2455"}
	if _, ok := s.Snapshot(context.Background(), 1, time.Now()); ok {
		t.Fatal("expected no snapshot without API key")
	}
}

func TestNormalizeBaseURLStripsV1Path(t *testing.T) {
	if got, want := normalizeBaseURL("http://localhost:2455/v1"), "http://localhost:2455"; got != want {
		t.Fatalf("base URL = %q, want %q", got, want)
	}
}
