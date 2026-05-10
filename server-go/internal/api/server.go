// Package api wires HTTP routes for the server.
package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"github.com/codemoo/token-terrier/server-go/internal/sse"
	"github.com/codemoo/token-terrier/server-go/internal/state"
	"github.com/codemoo/token-terrier/server-go/internal/wire"
)

// Server bundles runtime state needed by HTTP handlers.
type Server struct {
	Tokens   wire.BearerTokens
	Producer wire.ProducerInfo
	Logger   *slog.Logger

	// per-provider live state and SSE hub
	claudeState *state.State
	codexState  *state.State
	claudeHub   *sse.Hub
	codexHub    *sse.Hub
}

// New constructs a Server. Caller passes per-provider state + hub so the
// main can wire the same instances into periodic-refresh tasks.
func New(
	tokens wire.BearerTokens,
	producer wire.ProducerInfo,
	claude, codex *state.State,
	claudeHub, codexHub *sse.Hub,
	logger *slog.Logger,
) *Server {
	if logger == nil {
		logger = slog.Default()
	}
	return &Server{
		Tokens:      tokens,
		Producer:    producer,
		Logger:      logger,
		claudeState: claude,
		codexState:  codex,
		claudeHub:   claudeHub,
		codexHub:    codexHub,
	}
}

// Routes returns the HTTP handler ready to mount on a listener.
func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.handleHealthz)
	mux.HandleFunc("GET /version", s.handleVersion)
	mux.HandleFunc("GET /claude/snapshot", s.requireBearer(wire.ProviderClaude, s.handleSnapshot))
	mux.HandleFunc("GET /codex/snapshot", s.requireBearer(wire.ProviderCodex, s.handleSnapshot))
	mux.HandleFunc("GET /claude/sse", s.requireBearer(wire.ProviderClaude, s.handleSSE))
	mux.HandleFunc("GET /codex/sse", s.requireBearer(wire.ProviderCodex, s.handleSSE))
	return mux
}

func (s *Server) requireBearer(provider wire.Provider, next func(http.ResponseWriter, *http.Request, wire.Provider)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !wire.IsAuthorized(r.Header.Get("Authorization"), s.Tokens.Token(provider)) {
			writeJSONError(w, http.StatusUnauthorized, "unauthorized", "")
			return
		}
		next(w, r, provider)
	}
}

func (s *Server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) handleVersion(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"name":    "token-terrier-server",
		"schema":  "1",
		"version": "0.7.0-go-hermes-dedup",
	})
}

// handleSnapshot fetches via UsageState (cache + sticky + retry-under-refresh
// + 429 backoff) and publishes the result through the SSE hub so subscribers
// also get the freshly-fetched snapshot. Returns the same snapshot to the
// caller in case they don't have an SSE connection.
func (s *Server) handleSnapshot(w http.ResponseWriter, r *http.Request, provider wire.Provider) {
	ctx, cancel := context.WithTimeout(r.Context(), 25*time.Second)
	defer cancel()
	st := s.stateFor(provider)
	hub := s.hubFor(provider)
	update := st.Refresh(ctx, time.Now())
	publishUpdate(hub, provider, update)
	writeJSON(w, http.StatusOK, update.Snapshot)
}

// handleSSE upgrades the connection to text/event-stream and pumps frames
// from the per-provider Hub until the client disconnects. Schedules a
// background refresh on connect so initial slow upstream calls don't delay
// the headers + heartbeat — clients see headers immediately, then the
// freshly-fetched snapshot arrives through the stream like any other frame.
func (s *Server) handleSSE(w http.ResponseWriter, r *http.Request, provider wire.Provider) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeJSONError(w, http.StatusInternalServerError, "no_flusher", "")
		return
	}

	hdr := w.Header()
	hdr.Set("Content-Type", "text/event-stream; charset=utf-8")
	hdr.Set("Cache-Control", "no-cache")
	hdr.Set("Connection", "keep-alive")
	hdr.Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	hub := s.hubFor(provider)
	st := s.stateFor(provider)

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	events, unsubscribe := hub.Subscribe(ctx)
	defer unsubscribe()

	// Background refresh — let header bytes go out first.
	go func() {
		bgCtx, bgCancel := context.WithTimeout(context.Background(), 25*time.Second)
		defer bgCancel()
		update := st.Refresh(bgCtx, time.Now())
		publishUpdate(hub, provider, update)
	}()

	for {
		select {
		case <-ctx.Done():
			return
		case event, open := <-events:
			if !open {
				return
			}
			if _, err := w.Write([]byte(event.Text)); err != nil {
				return
			}
			flusher.Flush()
		}
	}
}

func (s *Server) stateFor(provider wire.Provider) *state.State {
	if provider == wire.ProviderCodex {
		return s.codexState
	}
	return s.claudeState
}

func (s *Server) hubFor(provider wire.Provider) *sse.Hub {
	if provider == wire.ProviderCodex {
		return s.codexHub
	}
	return s.claudeHub
}

// publishUpdate emits the auth_expired frame first (when state crosses into
// authExpired/codexLoggedOut) so the snapshot always lands LAST in the hub's
// 1-deep per-client buffer. Slow consumers therefore retain the
// state-bearing snapshot, not the bare transition signal.
func publishUpdate(hub *sse.Hub, provider wire.Provider, u state.UsageUpdate) {
	if u.EmitAuthExpired {
		hub.PublishAuthExpired(provider, u.Snapshot.Seq, u.Snapshot.Status.State)
	}
	_ = hub.PublishSnapshot(u.Snapshot)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeJSONError(w http.ResponseWriter, status int, code, detail string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	payload := map[string]string{"error": code}
	if detail != "" {
		payload["detail"] = detail
	}
	_ = json.NewEncoder(w).Encode(payload)
}
