package wire

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// BearerTokens holds the daemon's per-provider HTTP route tokens.
type BearerTokens struct {
	Claude string `json:"claude"`
	Codex  string `json:"codex"`
}

// Token returns the token for a provider.
func (b BearerTokens) Token(provider Provider) string {
	switch provider {
	case ProviderClaude:
		return b.Claude
	case ProviderCodex:
		return b.Codex
	}
	return ""
}

// IsAuthorized checks an Authorization header value against an expected
// token. Uses constant-time compare so the daemon doesn't leak token bytes
// via response-time timing — Swift used `==` which would, but the route is
// protected by network reachability so the practical exposure was small.
// Now it's just safe.
func IsAuthorized(authorizationHeader, expectedToken string) bool {
	const prefix = "Bearer "
	if !strings.HasPrefix(authorizationHeader, prefix) {
		return false
	}
	given := authorizationHeader[len(prefix):]
	return subtle.ConstantTimeCompare([]byte(given), []byte(expectedToken)) == 1
}

// LoadOrCreateBearerTokens behaves like Swift BearerTokenStore.loadOrCreate.
// Reads from $TOKEN_USAGE_CLAUDE_TOKEN / _CODEX_TOKEN if set; otherwise reads
// or generates ~/.config/token-usage/tokens.json with 0600 perms.
//
// Returns (tokens, created, path, err) so the caller can print the new
// values once on first run.
func LoadOrCreateBearerTokens() (BearerTokens, bool, string, error) {
	envClaude := strings.TrimSpace(os.Getenv("TOKEN_USAGE_CLAUDE_TOKEN"))
	envCodex := strings.TrimSpace(os.Getenv("TOKEN_USAGE_CODEX_TOKEN"))

	path, err := defaultBearerTokenPath()
	if err != nil {
		return BearerTokens{}, false, "", err
	}

	var fileTokens BearerTokens
	created := false
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		fileTokens, err = generateBearerTokensFile(path)
		if err != nil {
			return BearerTokens{}, false, path, err
		}
		created = true
	} else if err != nil {
		return BearerTokens{}, false, path, err
	} else {
		fileTokens, err = readBearerTokensFile(path)
		if err != nil {
			return BearerTokens{}, false, path, err
		}
	}

	tokens := BearerTokens{
		Claude: pick(envClaude, fileTokens.Claude),
		Codex:  pick(envCodex, fileTokens.Codex),
	}
	return tokens, created, path, nil
}

func pick(override, fallback string) string {
	if override != "" {
		return override
	}
	return fallback
}

func defaultBearerTokenPath() (string, error) {
	home := os.Getenv("HOME")
	if home == "" {
		var err error
		home, err = os.UserHomeDir()
		if err != nil {
			return "", err
		}
	}
	return filepath.Join(home, ".config", "token-usage", "tokens.json"), nil
}

func readBearerTokensFile(path string) (BearerTokens, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return BearerTokens{}, err
	}
	var t BearerTokens
	if err := json.Unmarshal(data, &t); err != nil {
		return BearerTokens{}, fmt.Errorf("parse %s: %w", path, err)
	}
	return t, nil
}

func generateBearerTokensFile(path string) (BearerTokens, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return BearerTokens{}, err
	}
	tokens := BearerTokens{
		Claude: mustRandomToken(),
		Codex:  mustRandomToken(),
	}
	data, err := json.MarshalIndent(tokens, "", "  ")
	if err != nil {
		return BearerTokens{}, err
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return BearerTokens{}, err
	}
	return tokens, nil
}

func mustRandomToken() string {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		// Fail loudly: the daemon's auth depends on this. Caller will
		// surface the panic via main; rand.Read failure is a kernel
		// CSPRNG fault and continuing with a weak token is worse than
		// crashing.
		panic("crypto/rand failed: " + err.Error())
	}
	return hex.EncodeToString(b[:])
}
