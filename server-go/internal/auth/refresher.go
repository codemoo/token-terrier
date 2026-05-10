package auth

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"

	"github.com/codemoo/token-terrier/server-go/internal/wire"
)

// CodexClientID is the OAuth client_id codex CLI uses on its refresh
// endpoint. Mirrors OAuthTokenRefresher.codexClientID in Swift.
const CodexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

// ClaudeClientID is the OAuth client_id claude-code CLI uses on its
// refresh endpoint. Extracted from claude-code 2.1.132 binary
// (BD.CLIENT_ID). Anthropic's token endpoint started rejecting
// refresh requests without this field with HTTP 400 "Invalid request
// format" — discovered 2026-05-07 after the daemon's silent OAuth
// failure became visible from the new logging.
const ClaudeClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

// claudeOAuthBeta is the anthropic-beta header value the CLI sends on
// every refresh round-trip. Required alongside client_id for the
// endpoint to accept the request.
const claudeOAuthBeta = "oauth-2025-04-20"

// RefreshError carries refresh-failure modes that map into ProviderState.
type RefreshError struct {
	Kind    RefreshKind
	Status  int
	Message string
}

type RefreshKind int

const (
	RefreshKindNoRefreshToken RefreshKind = iota
	RefreshKindCodexLoginRequired
	RefreshKindInvalidResponse
	RefreshKindRejected
	RefreshKindNetwork
)

func (e *RefreshError) Error() string {
	switch e.Kind {
	case RefreshKindNoRefreshToken:
		return "no refresh token available"
	case RefreshKindCodexLoginRequired:
		return "codex login required"
	case RefreshKindInvalidResponse:
		return "oauth refresh: invalid response: " + e.Message
	case RefreshKindRejected:
		return fmt.Sprintf("oauth refresh rejected: HTTP %d: %s", e.Status, e.Message)
	case RefreshKindNetwork:
		return "oauth refresh network: " + e.Message
	}
	return "oauth refresh error"
}

// IsCodexLoginRequired typed predicate.
func IsCodexLoginRequired(err error) bool {
	var re *RefreshError
	return errors.As(err, &re) && re.Kind == RefreshKindCodexLoginRequired
}

// Refresher implements the state.Refresher interface and performs OAuth
// token refresh round-trips against the provider's token endpoint, then
// persists the new credential back through the CredentialStore.
//
// Per-provider serialization: only one refresh in flight per provider at a
// time. We use a chan-based mutex so the lock acquisition itself respects
// the caller's context; without that, a daemon shutdown with N goroutines
// queued behind a single in-flight refresh would block until the network
// round-trip completes (~1s in the happy case, much longer if the
// upstream is hung).
type Refresher struct {
	HTTP  *http.Client
	Store *CredentialStore
	locks map[wire.Provider]chan struct{}
	muLk  sync.Mutex
}

// NewRefresher builds a Refresher that uses the standard 30s HTTP timeout.
func NewRefresher(store *CredentialStore) *Refresher {
	return &Refresher{
		HTTP:  &http.Client{Timeout: 30 * time.Second},
		Store: store,
		locks: map[wire.Provider]chan struct{}{},
	}
}

// Refresh performs the provider-specific refresh round-trip and writes the
// new credential back to the source. Concurrent calls for the same provider
// serialize on a context-aware semaphore so cancellation propagates.
func (r *Refresher) Refresh(ctx context.Context, c OAuthCredential) (OAuthCredential, error) {
	if c.RefreshToken == "" {
		if c.Provider == wire.ProviderCodex {
			return c, &RefreshError{Kind: RefreshKindCodexLoginRequired}
		}
		return c, &RefreshError{Kind: RefreshKindNoRefreshToken}
	}
	lock := r.lockFor(c.Provider)
	select {
	case lock <- struct{}{}:
		defer func() { <-lock }()
	case <-ctx.Done():
		return c, &RefreshError{Kind: RefreshKindNetwork, Message: ctx.Err().Error()}
	}

	// Re-read disk under the lock — another writer may have refreshed
	// between our retry decision and our acquiring the lock; if so,
	// honour theirs instead of issuing a redundant round-trip.
	latest, err := r.Store.Reload(ctx, c.Provider)
	if err == nil && latest.AccessToken != "" && latest.AccessToken != c.AccessToken {
		return latest, nil
	}

	var refreshed OAuthCredential
	switch c.Provider {
	case wire.ProviderClaude:
		refreshed, err = r.refreshClaude(ctx, c)
	case wire.ProviderCodex:
		refreshed, err = r.refreshCodex(ctx, c)
	default:
		return c, &RefreshError{Kind: RefreshKindInvalidResponse, Message: "unsupported provider"}
	}
	if err != nil {
		return c, err
	}

	// Persist the new credential back to disk so other processes
	// (Claude Code, codex CLI, future daemon restarts) see it.
	if err := r.persist(ctx, refreshed); err != nil {
		// Persist failure isn't fatal — the in-memory cache below still
		// gets updated so the daemon proceeds with the fresh token. A
		// later cold start would fall back to the disk version, which
		// is still valid until its own expiry.
	}
	r.Store.Replace(c.Provider, refreshed)
	return refreshed, nil
}

func (r *Refresher) lockFor(provider wire.Provider) chan struct{} {
	r.muLk.Lock()
	defer r.muLk.Unlock()
	if l, ok := r.locks[provider]; ok {
		return l
	}
	l := make(chan struct{}, 1)
	r.locks[provider] = l
	return l
}

func (r *Refresher) refreshClaude(ctx context.Context, c OAuthCredential) (OAuthCredential, error) {
	bodyBytes, err := json.Marshal(map[string]string{
		"grant_type":    "refresh_token",
		"refresh_token": c.RefreshToken,
		"client_id":     ClaudeClientID,
	})
	if err != nil {
		return c, &RefreshError{Kind: RefreshKindInvalidResponse, Message: err.Error()}
	}

	req, err := http.NewRequestWithContext(ctx, "POST", "https://platform.claude.com/v1/oauth/token", bytes.NewReader(bodyBytes))
	if err != nil {
		return c, &RefreshError{Kind: RefreshKindInvalidResponse, Message: err.Error()}
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("anthropic-beta", claudeOAuthBeta)

	resp, err := r.HTTP.Do(req)
	if err != nil {
		return c, &RefreshError{Kind: RefreshKindNetwork, Message: err.Error()}
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return c, &RefreshError{Kind: RefreshKindRejected, Status: resp.StatusCode, Message: string(body)}
	}
	var decoded struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		ExpiresIn    int    `json:"expires_in"`
	}
	if err := json.Unmarshal(body, &decoded); err != nil {
		return c, &RefreshError{Kind: RefreshKindInvalidResponse, Message: err.Error()}
	}
	expires := time.Now().Add(time.Duration(decoded.ExpiresIn) * time.Second)
	out := c
	out.AccessToken = decoded.AccessToken
	if decoded.RefreshToken != "" {
		out.RefreshToken = decoded.RefreshToken
	}
	out.ExpiresAt = &expires
	return out, nil
}

func (r *Refresher) refreshCodex(ctx context.Context, c OAuthCredential) (OAuthCredential, error) {
	bodyBytes, err := json.Marshal(map[string]string{
		"grant_type":    "refresh_token",
		"refresh_token": c.RefreshToken,
		"client_id":     CodexClientID,
		"scope":         "openid profile email",
	})
	if err != nil {
		return c, &RefreshError{Kind: RefreshKindInvalidResponse, Message: err.Error()}
	}
	req, err := http.NewRequestWithContext(ctx, "POST", "https://auth.openai.com/oauth/token", bytes.NewReader(bodyBytes))
	if err != nil {
		return c, &RefreshError{Kind: RefreshKindInvalidResponse, Message: err.Error()}
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := r.HTTP.Do(req)
	if err != nil {
		return c, &RefreshError{Kind: RefreshKindNetwork, Message: err.Error()}
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode == 401 || resp.StatusCode == 403 {
		return c, &RefreshError{Kind: RefreshKindCodexLoginRequired}
	}
	if resp.StatusCode != 200 {
		return c, &RefreshError{Kind: RefreshKindRejected, Status: resp.StatusCode, Message: string(body)}
	}
	var decoded struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		IDToken      string `json:"id_token"`
	}
	if err := json.Unmarshal(body, &decoded); err != nil {
		return c, &RefreshError{Kind: RefreshKindInvalidResponse, Message: err.Error()}
	}
	out := c
	if decoded.AccessToken != "" {
		out.AccessToken = decoded.AccessToken
	}
	if decoded.RefreshToken != "" {
		out.RefreshToken = decoded.RefreshToken
	}
	if decoded.IDToken != "" {
		out.IDToken = decoded.IDToken
	}
	now := time.Now()
	out.LastRefresh = &now
	return out, nil
}

// persist writes the refreshed credential back to its source. The shape
// matches what Claude Code / codex CLI write — we have to preserve the
// full nested layout because the upstream CLIs merge by key, not by replace.
func (r *Refresher) persist(ctx context.Context, c OAuthCredential) error {
	src, ok := r.Store.source.(rawSource)
	if !ok {
		return nil // source doesn't expose raw read/write — skip
	}
	// Read existing JSON, mutate the relevant subtree, write back.
	data, err := src.Read(ctx, c.Provider)
	if err != nil {
		return err
	}
	mutated, err := mergeRefreshed(c, data)
	if err != nil {
		return err
	}
	return src.Write(ctx, c.Provider, mutated)
}

type rawSource interface {
	Read(ctx context.Context, provider wire.Provider) ([]byte, error)
	Write(ctx context.Context, provider wire.Provider, body []byte) error
}

func mergeRefreshed(c OAuthCredential, original []byte) ([]byte, error) {
	var root map[string]any
	if len(original) > 0 {
		if err := json.Unmarshal(original, &root); err != nil {
			return nil, err
		}
	}
	if root == nil {
		root = map[string]any{}
	}
	switch c.Provider {
	case wire.ProviderClaude:
		oauth, _ := root["claudeAiOauth"].(map[string]any)
		if oauth == nil {
			oauth = map[string]any{}
		}
		oauth["accessToken"] = c.AccessToken
		if c.RefreshToken != "" {
			oauth["refreshToken"] = c.RefreshToken
		}
		if c.ExpiresAt != nil {
			oauth["expiresAt"] = float64(c.ExpiresAt.UnixNano()) / float64(time.Millisecond)
		}
		if len(c.Scopes) > 0 {
			oauth["scopes"] = c.Scopes
		}
		if c.RateLimitTier != "" {
			oauth["rateLimitTier"] = c.RateLimitTier
		}
		root["claudeAiOauth"] = oauth
	case wire.ProviderCodex:
		tokens, _ := root["tokens"].(map[string]any)
		if tokens == nil {
			tokens = map[string]any{}
		}
		tokens["access_token"] = c.AccessToken
		if c.RefreshToken != "" {
			tokens["refresh_token"] = c.RefreshToken
		}
		if c.IDToken != "" {
			tokens["id_token"] = c.IDToken
		}
		if c.AccountID != "" {
			tokens["account_id"] = c.AccountID
		}
		if c.AccountEmail != "" {
			tokens["account_email"] = c.AccountEmail
		}
		root["tokens"] = tokens
		now := c.LastRefresh
		if now == nil {
			t := time.Now()
			now = &t
		}
		root["last_refresh"] = wire.FormatTime(*now)
	}
	return json.MarshalIndent(root, "", "  ")
}

// expose CredentialStore.source as a typed interface so refresher.persist
// can write back through whatever ReadSource the daemon configured.
func init() {
	// Compile-time assertion: local source satisfies rawSource.
	var _ rawSource = (*LocalSource)(nil)
}
