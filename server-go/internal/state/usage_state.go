// Package state owns provider snapshots: cache TTLs, sticky last-good
// recovery for transient errors, rate-limit backoff, account-keyed
// invalidation, and the auth-expired transition signal.
//
// Mirrors Sources/TokenUsageCore/State/UsageState.swift behaviour.
package state

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"time"

	"github.com/codemoo/token-terrier/server-go/internal/auth"
	"github.com/codemoo/token-terrier/server-go/internal/burn"
	"github.com/codemoo/token-terrier/server-go/internal/jsonl"
	"github.com/codemoo/token-terrier/server-go/internal/usage"
	"github.com/codemoo/token-terrier/server-go/internal/wire"
)

// UsageUpdate is the result of a refresh attempt: the snapshot to publish
// plus a flag telling the daemon whether to also emit an `auth_expired`
// SSE event ahead of it (so the menubar's transition log records it).
type UsageUpdate struct {
	Snapshot        wire.UsageSnapshot
	EmitAuthExpired bool
}

// State holds the cached snapshot for one provider plus the bookkeeping that
// keeps the daemon from hammering upstream APIs and from blanking the UI on
// transient errors.
type State struct {
	mu sync.Mutex

	provider    wire.Provider
	credentials *auth.CredentialStore
	usageClient *usage.Client
	localUsage  LocalSnapshotter
	accounts    AccountsProvider
	refresher   Refresher
	burn        *burn.Tracker
	producer    wire.ProducerInfo
	logger      *slog.Logger

	cacheTTL         time.Duration
	stickyTTL        time.Duration
	rateLimitBackoff time.Duration
	credentialSkew   time.Duration

	seq              int
	latestSnapshot   *wire.UsageSnapshot
	lastState        *wire.ProviderState
	lastFetchAt      time.Time
	lastOkSnapshot   *wire.UsageSnapshot
	lastOkAt         time.Time
	cacheAccountKey  string
	lastOkAccountKey string

	fetchSuspendedUntil time.Time

	// consecutiveAuthExpired counts back-to-back auth-expired refreshes.
	// Resets on any non-auth state. Read by the daemon's auth-failure guard
	// to trigger self-exit (so a supervisor can restart a stuck daemon).
	consecutiveAuthExpired int
}

// Refresher abstracts the OAuth refresher so Day 4's full implementation
// can be wired in without changing the state package surface. Day 3 uses
// a no-op that just returns the existing credential.
type Refresher interface {
	Refresh(ctx context.Context, c auth.OAuthCredential) (auth.OAuthCredential, error)
}

// LocalSnapshotter optionally supplies a provider snapshot from a local
// sidecar/store before the daemon falls back to the upstream usage API.
type LocalSnapshotter interface {
	Snapshot(ctx context.Context, seq int, now time.Time) (wire.UsageSnapshot, bool)
}

// AccountsProvider optionally supplies per-account usage rows to attach to a
// Claude snapshot (claude-swap integration). Implemented by
// internal/claudeswap.Reader.
type AccountsProvider interface {
	Accounts() ([]wire.AccountUsage, *string)
}

// New builds a State for one provider with daemon defaults.
func New(provider wire.Provider, credentials *auth.CredentialStore, usageClient *usage.Client, refresher Refresher, burnTracker *burn.Tracker, producer wire.ProducerInfo, logger *slog.Logger) *State {
	if logger == nil {
		logger = slog.Default()
	}
	if burnTracker == nil {
		burnTracker = burn.New(time.Local, time.Now())
	}
	return &State{
		provider:         provider,
		credentials:      credentials,
		usageClient:      usageClient,
		refresher:        refresher,
		burn:             burnTracker,
		producer:         producer,
		logger:           logger,
		cacheTTL:         60 * time.Second,
		stickyTTL:        600 * time.Second,
		rateLimitBackoff: 300 * time.Second,
		credentialSkew:   5 * time.Minute,
	}
}

// SetLocalSnapshotter configures a local snapshot source for this provider.
func (s *State) SetLocalSnapshotter(snapshotter LocalSnapshotter) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.localUsage = snapshotter
}

// SetAccountsProvider configures the per-account usage source (Claude only).
func (s *State) SetAccountsProvider(p AccountsProvider) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.accounts = p
}

// decorateAccounts attaches accounts[] to a snapshot when an accounts
// provider is configured for this State's provider (Claude via claude-swap,
// Codex via codex-lb). Provider-agnostic: it trusts that s.accounts was
// wired to match this State's provider (see main.go's SetAccountsProvider
// call sites) — decorateAccounts itself does not gate on wire.Provider.
// No-op when no provider is set. MUST be called with s.mu UNLOCKED.
func (s *State) decorateAccounts(snap wire.UsageSnapshot) wire.UsageSnapshot {
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

// ingestEventInner records a JSONL token event and returns the resulting
// snapshot (with bumped seq + fresh burn rate). The daemon's main routes
// this through the SSE hub so menubar clients see live burn rate updates.
func (s *State) ingestEventInner(ev jsonl.TokenEvent, now time.Time) wire.UsageSnapshot {
	burnSnap := s.burn.Ingest(ev, now)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.seq++
	base := s.latestSnapshot
	if base == nil {
		state := wire.StateNetworkError
		if s.lastState != nil {
			state = *s.lastState
		}
		degraded := wire.Degraded(s.provider, s.seq, s.producer, now, state)
		base = &degraded
	}
	merged := mergeBurn(*base, burnSnap, s.seq, now)
	s.latestSnapshot = &merged
	return merged
}

// mergeBurn applies a burn snapshot's rate + state + today fields onto a
// usage snapshot, bumping seq + generated_at_utc.
func mergeBurn(s wire.UsageSnapshot, b burn.Snapshot, seq int, now time.Time) wire.UsageSnapshot {
	s.Seq = seq
	s.GeneratedAtUTC = wire.FormatTime(now)
	s.BurnRatePerMinute = b.RatePerMinute
	s.BurnState = string(b.State)
	s.TodayTotalTokens = b.TodayTotalTokens
	s.TodaySessions = b.TodaySessionsCount
	if b.HasObserved && s.Status.DataSource == wire.DataSourceAPIOnly {
		s.Status.DataSource = wire.DataSourceAPIAndJSONL
	}
	return s
}

// latestInner returns the most recent snapshot merged with the live burn
// rate. If none has been fetched yet, returns a degraded snapshot in
// networkError state.
func (s *State) latestInner(now time.Time) wire.UsageSnapshot {
	burnSnap := s.burn.Snapshot(now)
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.latestSnapshot != nil {
		merged := mergeBurnInPlace(*s.latestSnapshot, burnSnap)
		return merged
	}
	snap := wire.Degraded(s.provider, s.seq, s.producer, now, wire.StateNetworkError)
	s.latestSnapshot = &snap
	state := snap.Status.State
	s.lastState = &state
	return mergeBurnInPlace(snap, burnSnap)
}

// mergeBurnInPlace returns a copy with burn fields applied (no seq bump).
func mergeBurnInPlace(s wire.UsageSnapshot, b burn.Snapshot) wire.UsageSnapshot {
	s.BurnRatePerMinute = b.RatePerMinute
	s.BurnState = string(b.State)
	s.TodayTotalTokens = b.TodayTotalTokens
	s.TodaySessions = b.TodaySessionsCount
	if b.HasObserved && s.Status.DataSource == wire.DataSourceAPIOnly {
		s.Status.DataSource = wire.DataSourceAPIAndJSONL
	}
	return s
}

// refreshInner decides whether to issue a real upstream fetch and returns
// the resulting UsageUpdate. Mirrors UsageState.refreshSnapshot exactly:
//
//   - local snapshotter hit (for example codex-lb) → use it before credential I/O
//   - cache hit (same account, < cacheTTL since last fetch) → bump seq,
//     re-merge burn rate, return cached
//   - rate-limit suspended (recent 429) → same as cache hit
//   - else fetch from upstream; on 401, refresh credential + retry once
//   - on transient error (network/server), serve sticky last-good for up
//     to stickyTTL
//   - on auth/credential errors, return degraded immediately
func (s *State) refreshInner(ctx context.Context, now time.Time) UsageUpdate {
	burnSnap := s.burn.Snapshot(now)

	if update, ok := s.tryLocalSnapshot(ctx, now, burnSnap); ok {
		return update
	}

	currentAccount := s.credentials.CurrentAccountKey(ctx, s.provider)

	s.mu.Lock()
	isSameAccount := currentAccount != "" && s.cacheAccountKey == currentAccount
	cacheValid := isSameAccount && !s.lastFetchAt.IsZero() && now.Sub(s.lastFetchAt) < s.cacheTTL
	suspended := isSameAccount && !s.fetchSuspendedUntil.IsZero() && now.Before(s.fetchSuspendedUntil)

	if (cacheValid || suspended) && s.latestSnapshot != nil {
		s.seq++
		merged := mergeBurn(*s.latestSnapshot, burnSnap, s.seq, now)
		s.latestSnapshot = &merged
		s.mu.Unlock()
		return UsageUpdate{Snapshot: merged}
	}

	s.seq++
	seq := s.seq
	s.lastFetchAt = now
	previousState := copyState(s.lastState)
	s.mu.Unlock()

	credential, err := s.credentials.Load(ctx, s.provider)
	if err != nil {
		state := mapCredentialError(s.provider, err)
		return s.applyError(seq, now, currentAccount, previousState, state, err, burnSnap)
	}

	raw, fetchErr := s.usageClient.Snapshot(ctx, s.provider, credential, seq, now)
	if fetchErr != nil && usage.IsUnauthorized(fetchErr) {
		s.logger.Info("upstream 401 — entering oauth recovery",
			"provider", s.provider,
			"seq", seq,
			"consecutive_auth_expired", s.ConsecutiveAuthExpired())
		// Two-stage recovery before declaring auth-expired:
		// (1) reload from disk in case Claude Code/Codex CLI just
		//     rotated the token, then retry with the newer
		//     access token if it differs.
		// (2) force-refresh under our own refresher and retry once.
		latest, reloadErr := s.credentials.Reload(ctx, s.provider)
		switch {
		case reloadErr != nil:
			s.logger.Warn("oauth recovery: disk reload failed",
				"provider", s.provider,
				"err", reloadErr)
		case latest.AccessToken == credential.AccessToken:
			s.logger.Info("oauth recovery: disk token unchanged — will invoke refresher",
				"provider", s.provider)
		default:
			s.logger.Info("oauth recovery: disk had newer token — retrying without refresh",
				"provider", s.provider)
		}
		switch {
		case reloadErr == nil && latest.AccessToken != credential.AccessToken:
			raw, fetchErr = s.usageClient.Snapshot(ctx, s.provider, latest, seq, now)
			if fetchErr != nil {
				s.logger.Warn("oauth recovery: retry-with-disk-token failed",
					"provider", s.provider,
					"err", fetchErr)
			} else {
				s.logger.Info("oauth recovery: retry-with-disk-token succeeded",
					"provider", s.provider)
			}
		case s.refresher != nil:
			s.logger.Info("oauth recovery: calling refresher.Refresh",
				"provider", s.provider,
				"refresh_token_present", credential.RefreshToken != "")
			refreshed, refreshErr := s.refresher.Refresh(ctx, credential)
			if refreshErr != nil {
				s.logger.Warn("oauth recovery: refresher.Refresh failed",
					"provider", s.provider,
					"err", refreshErr)
			} else {
				s.logger.Info("oauth recovery: refresher.Refresh succeeded — retrying",
					"provider", s.provider,
					"new_access_token_differs", refreshed.AccessToken != credential.AccessToken)
				raw, fetchErr = s.usageClient.Snapshot(ctx, s.provider, refreshed, seq, now)
				if fetchErr != nil {
					s.logger.Warn("oauth recovery: retry-after-refresh failed",
						"provider", s.provider,
						"err", fetchErr)
				} else {
					s.logger.Info("oauth recovery: retry-after-refresh succeeded",
						"provider", s.provider)
				}
			}
		default:
			s.logger.Warn("oauth recovery: no refresher configured",
				"provider", s.provider)
		}
	}

	if fetchErr != nil {
		state := mapUsageError(s.provider, fetchErr)
		return s.applyError(seq, now, currentAccount, previousState, state, fetchErr, burnSnap)
	}

	// Successful fetch — update both the live snapshot and the sticky
	// last-good cache. Account-key both so a transient error right
	// after an account switch can't resurface the old account's quota.
	merged := mergeBurnInPlace(raw, burnSnap)
	s.mu.Lock()
	s.latestSnapshot = &merged
	rawCopy := raw
	s.lastOkSnapshot = &rawCopy
	s.lastOkAt = now
	s.cacheAccountKey = currentAccount
	s.lastOkAccountKey = currentAccount
	state := raw.Status.State
	s.lastState = &state
	// Reset only on a fully-successful OK fetch — transient/non-auth
	// errors leave the counter alone so 401→refresh→429 alternation
	// (which `mapUsageError` would otherwise downgrade to networkError)
	// still accumulates toward the auth-failure self-exit threshold.
	// Without this the guard never fires when upstream rate-limits us
	// right after a doomed token refresh.
	if state == wire.StateOK {
		s.consecutiveAuthExpired = 0
	}
	emit := shouldEmitAuthExpired(previousState, raw.Status.State)
	s.mu.Unlock()
	return UsageUpdate{Snapshot: merged, EmitAuthExpired: emit}
}

func (s *State) tryLocalSnapshot(ctx context.Context, now time.Time, burnSnap burn.Snapshot) (UsageUpdate, bool) {
	s.mu.Lock()
	localUsage := s.localUsage
	if localUsage == nil {
		s.mu.Unlock()
		return UsageUpdate{}, false
	}
	s.seq++
	seq := s.seq
	previousState := copyState(s.lastState)
	s.mu.Unlock()

	raw, ok := localUsage.Snapshot(ctx, seq, now)
	if !ok {
		s.mu.Lock()
		if s.seq == seq {
			s.seq--
		}
		s.mu.Unlock()
		return UsageUpdate{}, false
	}

	merged := mergeBurnInPlace(raw, burnSnap)
	s.mu.Lock()
	s.latestSnapshot = &merged
	rawCopy := raw
	s.lastOkSnapshot = &rawCopy
	s.lastOkAt = now
	s.cacheAccountKey = "local"
	s.lastOkAccountKey = "local"
	state := raw.Status.State
	s.lastState = &state
	if state == wire.StateOK {
		s.consecutiveAuthExpired = 0
	}
	emit := shouldEmitAuthExpired(previousState, raw.Status.State)
	s.mu.Unlock()
	return UsageUpdate{Snapshot: merged, EmitAuthExpired: emit}, true
}

// ConsecutiveAuthExpired returns the count of back-to-back auth-expired
// refreshes. Used by the daemon's auth-failure guard to trigger self-exit.
func (s *State) ConsecutiveAuthExpired() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.consecutiveAuthExpired
}

// applyError handles the post-fetch failure path: 429 backoff, sticky
// last-good fallback for transient errors, and degraded snapshot otherwise.
func (s *State) applyError(seq int, now time.Time, currentAccount string, previousState *wire.ProviderState, state wire.ProviderState, originalErr error, burnSnap burn.Snapshot) UsageUpdate {
	s.logger.Warn("usage refresh failed",
		"provider", s.provider,
		"state", state,
		"err", originalErr)

	// 429 → freeze our own fetches so cron-period refreshes don't keep
	// re-hitting the same Cloudflare bucket.
	if usage.ServerStatus(originalErr) == 429 {
		until := now.Add(s.rateLimitBackoff)
		s.mu.Lock()
		s.fetchSuspendedUntil = until
		s.mu.Unlock()
		s.logger.Warn("upstream 429 — suspending fetches",
			"provider", s.provider,
			"until", wire.FormatTime(until))
	}

	// Sticky last-good: only for transient (network/server) errors,
	// only when we have a recent OK snapshot from the SAME account.
	isTransient := state == wire.StateNetworkError
	s.mu.Lock()
	if isTransient && currentAccount != "" && s.lastOkAccountKey == currentAccount &&
		s.lastOkSnapshot != nil && !s.lastOkAt.IsZero() && now.Sub(s.lastOkAt) < s.stickyTTL {
		merged := mergeBurn(*s.lastOkSnapshot, burnSnap, seq, now)
		s.latestSnapshot = &merged
		previousLastState := copyState(s.lastState)
		ok := wire.StateOK
		s.lastState = &ok
		emit := shouldEmitAuthExpired(previousLastState, wire.StateOK)
		s.mu.Unlock()
		return UsageUpdate{Snapshot: merged, EmitAuthExpired: emit}
	}
	s.mu.Unlock()

	raw := wire.Degraded(s.provider, seq, s.producer, now, state)
	merged := mergeBurnInPlace(raw, burnSnap)
	s.mu.Lock()
	s.latestSnapshot = &merged
	s.cacheAccountKey = currentAccount
	previousLastState := copyState(s.lastState)
	s.lastState = &state
	// Counter rules (mirror the success-path reset above):
	//   - auth-expired: bump (the obvious case)
	//   - networkError after we tried to recover from a 401: also bump,
	//     so 401→refresh→429 alternation reaches the threshold instead of
	//     getting laundered by mapUsageError downgrading 429 to networkError
	//   - any other state (codexLoggedOut, quotaEndpointChanged): bump too
	//     since recovery requires a restart anyway
	// Only a confirmed StateOK ever clears the counter — handled in Refresh.
	s.consecutiveAuthExpired++
	emit := shouldEmitAuthExpired(previousLastState, state)
	_ = previousState // kept for symmetry with Swift; not used here
	s.mu.Unlock()
	return UsageUpdate{Snapshot: merged, EmitAuthExpired: emit}
}

// withSeq is the Go equivalent of Snapshot.with(seq:generatedAtUTC:): rewrite
// the monotonic seq + timestamp on a cached snapshot when re-emitting it.
func withSeq(s wire.UsageSnapshot, seq int, now time.Time) wire.UsageSnapshot {
	s.Seq = seq
	s.GeneratedAtUTC = wire.FormatTime(now)
	return s
}

func copyState(p *wire.ProviderState) *wire.ProviderState {
	if p == nil {
		return nil
	}
	v := *p
	return &v
}

func shouldEmitAuthExpired(prev *wire.ProviderState, next wire.ProviderState) bool {
	authStates := map[wire.ProviderState]bool{
		wire.StateAuthExpired:    true,
		wire.StateCodexLoggedOut: true,
	}
	if !authStates[next] {
		return false
	}
	if prev == nil {
		return true
	}
	return *prev != next
}

// NoopRefresher is a placeholder until Day 4 wires the real OAuth refresh.
// Returns the input credential so the retry path is a no-op.
type NoopRefresher struct{}

// Refresh returns the credential unchanged.
func (NoopRefresher) Refresh(_ context.Context, c auth.OAuthCredential) (auth.OAuthCredential, error) {
	return c, errors.New("oauth refresh not implemented yet (Day 4)")
}

func mapCredentialError(provider wire.Provider, err error) wire.ProviderState {
	if auth.IsNotFound(err) {
		if provider == wire.ProviderCodex {
			return wire.StateCodexLoggedOut
		}
		return wire.StateAuthExpired
	}
	var ce auth.CredentialFileError
	if errors.As(err, &ce) {
		switch ce.Kind {
		case "missing_token":
			if provider == wire.ProviderCodex {
				return wire.StateCodexLoggedOut
			}
			return wire.StateAuthExpired
		case "invalid_json":
			return wire.StateQuotaEndpointChanged
		}
	}
	return wire.StateNetworkError
}

func mapUsageError(provider wire.Provider, err error) wire.ProviderState {
	if usage.IsUnauthorized(err) {
		if provider == wire.ProviderCodex {
			return wire.StateCodexLoggedOut
		}
		return wire.StateAuthExpired
	}
	if usage.IsServer(err) {
		return wire.StateNetworkError
	}
	var ae *usage.APIError
	if errors.As(err, &ae) && ae.Kind == usage.KindInvalidResponse {
		return wire.StateQuotaEndpointChanged
	}
	return wire.StateNetworkError
}
