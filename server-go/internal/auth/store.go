package auth

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sync"

	"github.com/codemoo/token-terrier/server-go/internal/wire"
)

// CredentialStore loads OAuth credentials. It hides where they live so the
// rest of the daemon doesn't care about the concrete file layout.
type CredentialStore struct {
	mu     sync.Mutex
	source ReadSource

	// Cached parses keyed by provider — the underlying file rarely
	// changes; reloading on every snapshot is wasteful. Cache invalidates
	// on demand (Reload) and after successful refresh.
	cache map[wire.Provider]OAuthCredential
}

// ReadSource abstracts how the daemon reaches the credential bytes. Used as
// a swappable interface so tests can use temporary local files.
type ReadSource interface {
	Read(ctx context.Context, provider wire.Provider) ([]byte, error)
	// Write persists refreshed credentials back to the source so Claude
	// Code/Codex CLI can continue to use the rotated tokens.
	Write(ctx context.Context, provider wire.Provider, body []byte) error
}

// NewCredentialStore wires the store to the given source.
func NewCredentialStore(src ReadSource) *CredentialStore {
	return &CredentialStore{source: src, cache: map[wire.Provider]OAuthCredential{}}
}

// Load returns the parsed credential for a provider. Caches in-memory; call
// Reload to force a re-read.
func (s *CredentialStore) Load(ctx context.Context, provider wire.Provider) (OAuthCredential, error) {
	s.mu.Lock()
	if cached, ok := s.cache[provider]; ok {
		s.mu.Unlock()
		return cached, nil
	}
	s.mu.Unlock()
	return s.Reload(ctx, provider)
}

// Reload forces an upstream read + parse, updating the cache.
func (s *CredentialStore) Reload(ctx context.Context, provider wire.Provider) (OAuthCredential, error) {
	data, err := s.source.Read(ctx, provider)
	if err != nil {
		return OAuthCredential{}, err
	}
	parsed, err := parseProvider(provider, data)
	if err != nil {
		return OAuthCredential{}, err
	}
	s.mu.Lock()
	s.cache[provider] = parsed
	s.mu.Unlock()
	return parsed, nil
}

// Replace updates the in-memory cache after a refresh round-trip. The caller
// is expected to also persist the new credential via the source's Write.
func (s *CredentialStore) Replace(provider wire.Provider, c OAuthCredential) {
	s.mu.Lock()
	s.cache[provider] = c
	s.mu.Unlock()
}

// CurrentAccountKey returns the cached credential's accountKey or "" if
// nothing is loaded yet. Lock-light for the cache hit path so the hot
// snapshot path doesn't serialize on credential I/O.
func (s *CredentialStore) CurrentAccountKey(ctx context.Context, provider wire.Provider) string {
	s.mu.Lock()
	if c, ok := s.cache[provider]; ok {
		s.mu.Unlock()
		return c.AccountKey()
	}
	s.mu.Unlock()
	c, err := s.Load(ctx, provider)
	if err != nil {
		return ""
	}
	return c.AccountKey()
}

func parseProvider(provider wire.Provider, data []byte) (OAuthCredential, error) {
	switch provider {
	case wire.ProviderClaude:
		return ParseClaude(data)
	case wire.ProviderCodex:
		return ParseCodex(data)
	default:
		return OAuthCredential{}, fmt.Errorf("unsupported provider: %s", provider)
	}
}

// LocalSource reads/writes credentials from the local filesystem. Useful
// for tests and for the standalone server.
type LocalSource struct {
	ClaudePath string
	CodexPath  string
}

// Read implements ReadSource using local file IO.
func (l *LocalSource) Read(_ context.Context, provider wire.Provider) ([]byte, error) {
	path := l.pathFor(provider)
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, CredentialFileError{Kind: "not_found", Message: path}
		}
		return nil, err
	}
	return data, nil
}

// Write implements ReadSource using local file IO with atomic rename.
func (l *LocalSource) Write(_ context.Context, provider wire.Provider, body []byte) error {
	path := l.pathFor(provider)
	tmp := path + ".tmp.token-terrier-server"
	if err := os.WriteFile(tmp, body, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func (l *LocalSource) pathFor(provider wire.Provider) string {
	switch provider {
	case wire.ProviderClaude:
		return l.ClaudePath
	case wire.ProviderCodex:
		return l.CodexPath
	}
	return ""
}
