// Command daemon serves local token usage data over HTTP/SSE.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	_ "net/http/pprof" // registers /debug/pprof/* on http.DefaultServeMux for the localhost-only listener below
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/codemoo/token-terrier/server-go/internal/api"
	"github.com/codemoo/token-terrier/server-go/internal/auth"
	"github.com/codemoo/token-terrier/server-go/internal/burn"
	"github.com/codemoo/token-terrier/server-go/internal/hermes"
	"github.com/codemoo/token-terrier/server-go/internal/jsonl"
	"github.com/codemoo/token-terrier/server-go/internal/sse"
	"github.com/codemoo/token-terrier/server-go/internal/state"
	"github.com/codemoo/token-terrier/server-go/internal/usage"
	"github.com/codemoo/token-terrier/server-go/internal/wire"
)

const (
	periodicRefreshInterval = 60 * time.Second
	// authFailureThreshold caps how many consecutive auth-expired refreshes
	// the daemon tolerates before exiting for its supervisor to restart it. With a
	// 60s refresh ticker that's roughly N minutes of being stuck. Deliberately
	// generous so a real user-initiated logout doesn't cause a thrash.
	authFailureThreshold = 30
	// authFailureCheckInterval cadence at which the guard polls per-provider
	// counters. Independent of refresh ticker so it fires even if refresh
	// itself ever wedges.
	authFailureCheckInterval = time.Minute
)

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))

	tokens, created, tokenPath, err := wire.LoadOrCreateBearerTokens()
	if err != nil {
		logger.Error("bearer token store", "err", err)
		os.Exit(1)
	}
	if created {
		fmt.Fprintf(os.Stdout, "Generated bearer tokens at %s\n", tokenPath)
		fmt.Fprintf(os.Stdout, "TOKEN_USAGE_CLAUDE_TOKEN=%s\n", tokens.Claude)
		fmt.Fprintf(os.Stdout, "TOKEN_USAGE_CODEX_TOKEN=%s\n", tokens.Codex)
	}

	producer := wire.CurrentProducer()

	home, _ := os.UserHomeDir()
	claudeCred := strings.TrimSpace(os.Getenv("TOKEN_USAGE_CLAUDE_CRED"))
	if claudeCred == "" {
		claudeCred = filepath.Join(home, ".claude", ".credentials.json")
	}
	codexCred := strings.TrimSpace(os.Getenv("TOKEN_USAGE_CODEX_CRED"))
	if codexCred == "" {
		codexCred = filepath.Join(home, ".codex", "auth.json")
	}
	credSource := &auth.LocalSource{
		ClaudePath: claudeCred,
		CodexPath:  codexCred,
	}
	logger.Info("credential source: local filesystem")
	credStore := auth.NewCredentialStore(credSource)
	usageClient := usage.NewClient(producer)
	refresher := auth.NewRefresher(credStore)

	// One BurnTracker per provider — they're independent (different sliding
	// windows for different providers' event streams).
	now := time.Now()
	claudeBurn := burn.New(time.Local, now)
	codexBurn := burn.New(time.Local, now)

	// Adapter: state package wants a Refresher interface; auth.Refresher
	// satisfies it via its Refresh method but Go doesn't auto-bind across
	// the package boundary. Tiny shim.
	stateRefresher := refresherAdapter{r: refresher}

	claudeState := state.New(wire.ProviderClaude, credStore, usageClient, stateRefresher, claudeBurn, producer, logger)
	codexState := state.New(wire.ProviderCodex, credStore, usageClient, stateRefresher, codexBurn, producer, logger)
	claudeHub := sse.NewHub()
	codexHub := sse.NewHub()
	srv := api.New(tokens, producer, claudeState, codexState, claudeHub, codexHub, logger)

	host := strings.TrimSpace(os.Getenv("TOKEN_USAGE_BIND"))
	if host == "" {
		host = "127.0.0.1"
	}
	port := 18910
	if v := os.Getenv("TOKEN_USAGE_PORT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n < 65536 {
			port = n
		}
	}
	addr := fmt.Sprintf("%s:%d", host, port)

	httpServer := &http.Server{
		Addr:              addr,
		Handler:           srv.Routes(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	rootCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var wg sync.WaitGroup

	if os.Getenv("TOKEN_USAGE_DISABLE_JSONL") != "1" {
		startJSONLPoller(rootCtx, &wg, claudeState, codexState, claudeHub, codexHub, logger)
	}
	// Hermes SQLite poller captures broader API usage when Hermes is present.
	// Set TOKEN_USAGE_DISABLE_HERMES=1 to skip it.
	if os.Getenv("TOKEN_USAGE_DISABLE_HERMES") != "1" {
		startHermesPoller(rootCtx, &wg, claudeState, codexState, claudeHub, codexHub, logger)
	}

	startPeriodicRefresh(rootCtx, &wg, claudeState, claudeHub, wire.ProviderClaude, logger)
	startPeriodicRefresh(rootCtx, &wg, codexState, codexHub, wire.ProviderCodex, logger)
	startAuthFailureGuard(rootCtx, &wg, claudeState, codexState, logger)
	startPprofListener(logger)

	go func() {
		<-rootCtx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := httpServer.Shutdown(shutdownCtx); err != nil {
			logger.Error("http shutdown", "err", err)
		}
		claudeHub.Close()
		codexHub.Close()
	}()

	logger.Info("starting token-terrier server",
		"bind", host,
		"port", port,
		"producer_id", producer.ID,
		"producer_tz", producer.TimeZone)

	if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Error("http listen", "err", err)
		os.Exit(1)
	}
	wg.Wait()
	logger.Info("stopped")
}

// refresherAdapter bridges auth.Refresher → state.Refresher.
type refresherAdapter struct {
	r *auth.Refresher
}

func (a refresherAdapter) Refresh(ctx context.Context, c auth.OAuthCredential) (auth.OAuthCredential, error) {
	return a.r.Refresh(ctx, c)
}

func startPeriodicRefresh(ctx context.Context, wg *sync.WaitGroup, st *state.State, hub *sse.Hub, provider wire.Provider, logger *slog.Logger) {
	wg.Add(1)
	go func() {
		defer wg.Done()
		t := time.NewTicker(periodicRefreshInterval)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				refreshCtx, cancel := context.WithTimeout(ctx, 25*time.Second)
				update := st.Refresh(refreshCtx, time.Now())
				cancel()
				if update.EmitAuthExpired {
					hub.PublishAuthExpired(provider, update.Snapshot.Seq, update.Snapshot.Status.State)
				}
				if err := hub.PublishSnapshot(update.Snapshot); err != nil {
					logger.Warn("hub publish", "provider", provider, "err", err)
				}
			}
		}
	}()
}

// startJSONLPoller wires the JSONL poller into per-provider
// state ingestion. Each token event bumps the burn rate and broadcasts a
// fresh snapshot through the SSE hub.
func startJSONLPoller(ctx context.Context, wg *sync.WaitGroup, claude, codex *state.State, claudeHub, codexHub *sse.Hub, logger *slog.Logger) {
	emit := makeEventEmitter(claude, codex, claudeHub, codexHub, logger, "jsonl")
	poller := jsonl.NewPoller(emit, logger)
	wg.Add(1)
	go func() {
		defer wg.Done()
		poller.Run(ctx)
	}()
}

// startHermesPoller wires Hermes' SQLite session deltas into the same per-
// provider state ingestion JSONL uses. Hermes session keys are namespaced
// (`hermes:<id>`) so they stay distinct from JSONL session paths in the
// today_sessions count.
func startHermesPoller(ctx context.Context, wg *sync.WaitGroup, claude, codex *state.State, claudeHub, codexHub *sse.Hub, logger *slog.Logger) {
	emit := makeEventEmitter(claude, codex, claudeHub, codexHub, logger, "hermes")
	poller := hermes.NewPoller(emit, logger)
	wg.Add(1)
	go func() {
		defer wg.Done()
		poller.Run(ctx)
	}()
}

// startAuthFailureGuard watches per-provider consecutive-auth-expired
// counters and triggers os.Exit(1) once either provider has been stuck for
// authFailureThreshold consecutive refreshes. A process supervisor can then
// bounce the process — recovering from any in-memory state corruption
// (stale token cache, hung HTTP keep-alive, etc.) that re-fetching alone
// can't resolve.
//
// This guard makes the recovery automatic when the daemon gets stuck on stale
// token state and a clean process restart would recover it.
func startAuthFailureGuard(ctx context.Context, wg *sync.WaitGroup, claude, codex *state.State, logger *slog.Logger) {
	wg.Add(1)
	go func() {
		defer wg.Done()
		t := time.NewTicker(authFailureCheckInterval)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				cc := claude.ConsecutiveAuthExpired()
				cx := codex.ConsecutiveAuthExpired()
				if cc >= authFailureThreshold || cx >= authFailureThreshold {
					logger.Error("self-recovery: auth-expired stuck — exiting for supervisor restart",
						"claude_consecutive", cc,
						"codex_consecutive", cx,
						"threshold", authFailureThreshold)
					// os.Exit skips deferred WaitGroup.Done in this goroutine,
					// but that's fine — the process is going away anyway.
					os.Exit(1)
				}
			}
		}
	}()
}

// startPprofListener exposes net/http/pprof on a localhost-only port for
// heap/goroutine profiling. Disabled by setting
// TOKEN_USAGE_DISABLE_PPROF=1. Default port 6060; override with
// TOKEN_USAGE_PPROF_PORT.
//
//	go tool pprof http://127.0.0.1:6060/debug/pprof/heap
func startPprofListener(logger *slog.Logger) {
	if os.Getenv("TOKEN_USAGE_DISABLE_PPROF") == "1" {
		return
	}
	port := 6060
	if v := os.Getenv("TOKEN_USAGE_PPROF_PORT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n < 65536 {
			port = n
		}
	}
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	go func() {
		// Dedicated listener — never expose pprof on the public bearer-
		// guarded handler. http.DefaultServeMux already has pprof routes
		// registered via the blank import above.
		s := &http.Server{
			Addr:              addr,
			Handler:           http.DefaultServeMux,
			ReadHeaderTimeout: 10 * time.Second,
		}
		logger.Info("pprof listener", "addr", addr)
		if err := s.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Warn("pprof listener", "err", err)
		}
	}()
}

// makeEventEmitter returns a closure that ingests an event into the right
// provider's state and publishes the resulting snapshot through its hub.
func makeEventEmitter(claude, codex *state.State, claudeHub, codexHub *sse.Hub, logger *slog.Logger, source string) func(jsonl.TokenEvent) {
	return func(ev jsonl.TokenEvent) {
		now := time.Now()
		var snap wire.UsageSnapshot
		var hub *sse.Hub
		switch ev.Provider {
		case wire.ProviderClaude:
			snap = claude.IngestEvent(ev, now)
			hub = claudeHub
		case wire.ProviderCodex:
			snap = codex.IngestEvent(ev, now)
			hub = codexHub
		default:
			return
		}
		if err := hub.PublishSnapshot(snap); err != nil {
			logger.Warn("hub publish ("+source+")", "provider", ev.Provider, "err", err)
		}
	}
}
