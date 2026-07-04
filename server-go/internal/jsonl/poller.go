package jsonl

import (
	"context"
	"errors"
	"io"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/codemoo/token-terrier/server-go/internal/wire"
)

// Poller watches local JSONL session files and emits TokenEvents
// to the supplied callback. Mirrors Sources/TokenUsageCore/JSONL/JSONLPoller.swift
// in spirit (per-file offset tracking).
//
// Strategy: every PollInterval, list .jsonl files in the claude/codex roots.
// For files whose size grew since last poll, read the new tail and parse each line.
// Per-file offsets persist in memory; daemon restart re-scans from the
// current EOF (no historical replay — we don't want a startup spike of
// stale events distorting the burn rate).
type Poller struct {
	ClaudeRoot                string // path, e.g. ~/.claude/projects
	CodexRoot                 string // path, e.g. ~/.codex/sessions
	ClaudeSwapSessionsRoot    string // path, e.g. ~/.claude-swap-backup/sessions
	DisableClaudeSwapSessions bool
	PollInterval              time.Duration

	logger *slog.Logger
	emit   func(TokenEvent)

	mu      sync.Mutex
	offsets map[string]int64 // path → bytes already consumed
}

// NewPoller builds a Poller. Roots default to the standard Claude Code/codex
// locations under the current user's home dir.
func NewPoller(emit func(TokenEvent), logger *slog.Logger) *Poller {
	if logger == nil {
		logger = slog.Default()
	}
	home, _ := os.UserHomeDir()
	claudeRoot := os.Getenv("TOKEN_USAGE_CLAUDE_PROJECTS")
	if claudeRoot == "" {
		claudeRoot = filepath.Join(home, ".claude", "projects")
	}
	codexRoot := os.Getenv("TOKEN_USAGE_CODEX_SESSIONS")
	if codexRoot == "" {
		codexRoot = filepath.Join(home, ".codex", "sessions")
	}
	swapSessionsRoot := strings.TrimSpace(os.Getenv("TOKEN_USAGE_CLAUDE_SWAP_SESSIONS_ROOT"))
	if swapSessionsRoot == "" {
		swapSessionsRoot = filepath.Join(home, ".claude-swap-backup", "sessions")
	}
	return &Poller{
		ClaudeRoot:                claudeRoot,
		CodexRoot:                 codexRoot,
		ClaudeSwapSessionsRoot:    swapSessionsRoot,
		DisableClaudeSwapSessions: os.Getenv("TOKEN_USAGE_DISABLE_CLAUDE_SWAP") == "1" || os.Getenv("TOKEN_USAGE_DISABLE_CLAUDE_SWAP_SESSIONS") == "1",
		PollInterval:              5 * time.Second,
		logger:                    logger,
		emit:                      emit,
		offsets:                   map[string]int64{},
	}
}

// Run blocks until ctx cancels, polling every PollInterval.
func (p *Poller) Run(ctx context.Context) {
	// First pass — establish offsets at current EOF for every existing
	// file so we don't replay history. Subsequent ticks see only new lines.
	p.bootstrapOffsets(ctx)

	t := time.NewTicker(p.PollInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			for _, root := range p.pollRoots() {
				p.tickRoot(ctx, root)
			}
		}
	}
}

func (p *Poller) bootstrapOffsets(ctx context.Context) {
	for _, root := range p.pollRoots() {
		listing, err := p.listJSONL(ctx, root.path)
		if err != nil {
			p.logger.Warn("jsonl list failed during bootstrap", "root", root.path, "err", err)
			continue
		}
		p.mu.Lock()
		for path, size := range listing {
			p.offsets[path] = size
		}
		p.mu.Unlock()
	}
	p.logger.Info("jsonl poller bootstrap complete", "tracked_files", p.fileCount())
}

func (p *Poller) fileCount() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.offsets)
}

type pollRoot struct {
	provider            wire.Provider
	path                string
	claudeAccountNumber int
}

func (p *Poller) pollRoots() []pollRoot {
	roots := []pollRoot{
		{provider: wire.ProviderClaude, path: p.ClaudeRoot},
	}
	if !p.DisableClaudeSwapSessions {
		roots = append(roots, discoverClaudeSwapProjectRoots(p.ClaudeSwapSessionsRoot)...)
	}
	roots = append(roots, pollRoot{provider: wire.ProviderCodex, path: p.CodexRoot})
	return dedupePollRoots(roots)
}

func dedupePollRoots(roots []pollRoot) []pollRoot {
	seen := map[string]struct{}{}
	out := make([]pollRoot, 0, len(roots))
	for _, root := range roots {
		clean := filepath.Clean(strings.TrimSpace(root.path))
		if clean == "" || clean == "." {
			continue
		}
		key := string(root.provider) + "\x00" + clean
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		root.path = clean
		out = append(out, root)
	}
	return out
}

func discoverClaudeSwapProjectRoots(sessionsRoot string) []pollRoot {
	sessionsRoot = filepath.Clean(strings.TrimSpace(sessionsRoot))
	if sessionsRoot == "" || sessionsRoot == "." {
		return nil
	}
	entries, err := os.ReadDir(sessionsRoot)
	if err != nil {
		return nil
	}
	roots := make([]pollRoot, 0, len(entries))
	for _, entry := range entries {
		if entry == nil || !entry.IsDir() {
			continue
		}
		accountNumber := parseClaudeSwapSessionAccountNumber(entry.Name())
		if accountNumber <= 0 {
			continue
		}
		projects := filepath.Join(sessionsRoot, entry.Name(), "projects")
		if info, err := os.Stat(projects); err == nil && info.IsDir() {
			roots = append(roots, pollRoot{
				provider:            wire.ProviderClaude,
				path:                projects,
				claudeAccountNumber: accountNumber,
			})
		}
	}
	sort.SliceStable(roots, func(i, j int) bool {
		return roots[i].claudeAccountNumber < roots[j].claudeAccountNumber
	})
	return roots
}

func parseClaudeSwapSessionAccountNumber(name string) int {
	if name == "" {
		return 0
	}
	i := 0
	for i < len(name) && name[i] >= '0' && name[i] <= '9' {
		i++
	}
	if i == 0 || i >= len(name) || name[i] != '-' {
		return 0
	}
	n, err := strconv.Atoi(name[:i])
	if err != nil || n <= 0 {
		return 0
	}
	return n
}

func (p *Poller) tickRoot(ctx context.Context, root pollRoot) {
	listing, err := p.listJSONL(ctx, root.path)
	if err != nil {
		p.logger.Debug("jsonl list failed", "provider", root.provider, "err", err)
		return
	}
	// Prune offsets for files that disappeared upstream — codex CLI
	// rotates rollouts daily and Claude Code sessions get cleaned up by
	// the user's retention script. Without this the offset map grows
	// unbounded across months of uptime.
	p.pruneStaleOffsets(root.path, listing)

	for path, currentSize := range listing {
		p.mu.Lock()
		prev, known := p.offsets[path]
		p.mu.Unlock()
		if !known {
			// Newly observed file: start tracking from EOF so we don't
			// replay historical lines (which would skew the burn rate).
			p.mu.Lock()
			p.offsets[path] = currentSize
			p.mu.Unlock()
			continue
		}
		if currentSize < prev {
			// File shrank — likely a truncate/rotation. Reset to the
			// current EOF so we don't tail garbage offsets.
			p.mu.Lock()
			p.offsets[path] = currentSize
			p.mu.Unlock()
			continue
		}
		if currentSize == prev {
			continue
		}
		newBytes, err := p.tailFrom(ctx, path, prev)
		if err != nil {
			p.logger.Debug("jsonl tail failed", "path", path, "err", err)
			continue
		}
		consumed := p.parseAndEmit(root, path, newBytes)
		p.mu.Lock()
		p.offsets[path] = prev + int64(consumed)
		p.mu.Unlock()
	}
}

// pruneStaleOffsets removes offset entries for paths that are no longer in
// `listing`, but only for paths under `root` (so a Claude tick doesn't drop
// Codex offsets, and vice versa).
func (p *Poller) pruneStaleOffsets(root string, listing map[string]int64) {
	rootPrefix := root
	if !strings.HasSuffix(rootPrefix, "/") {
		rootPrefix += "/"
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	for path := range p.offsets {
		if !strings.HasPrefix(path, rootPrefix) {
			continue // not in this provider's root
		}
		if _, stillThere := listing[path]; !stillThere {
			delete(p.offsets, path)
		}
	}
}

// listJSONL returns map[absPath] = size.
func (p *Poller) listJSONL(ctx context.Context, root string) (map[string]int64, error) {
	result := map[string]int64{}
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			if errors.Is(walkErr, os.ErrNotExist) || errors.Is(walkErr, os.ErrPermission) {
				return nil
			}
			return walkErr
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		if entry == nil || entry.IsDir() || filepath.Ext(path) != ".jsonl" {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return nil
		}
		result[path] = info.Size()
		return nil
	})
	if errors.Is(err, os.ErrNotExist) {
		return result, nil
	}
	return result, err
}

// tailFrom returns the bytes from offset to EOF.
func (p *Poller) tailFrom(ctx context.Context, path string, offset int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	if _, err := file.Seek(offset, io.SeekStart); err != nil {
		return nil, err
	}
	done := make(chan struct{})
	var data []byte
	var readErr error
	go func() {
		data, readErr = io.ReadAll(file)
		close(done)
	}()
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-done:
		return data, readErr
	}
}

// parseAndEmit splits on newlines, parses each, emits TokenEvents. Returns
// the number of bytes "consumed" — strictly less than len(buf) when the
// last line is partial (no trailing newline yet). The trailing fragment is
// re-read on the next tick when the rest arrives.
func (p *Poller) parseAndEmit(root pollRoot, path string, buf []byte) int {
	consumed := 0
	for {
		nl := indexNL(buf[consumed:])
		if nl < 0 {
			break // partial last line
		}
		end := consumed + nl
		line := buf[consumed:end]
		consumed = end + 1 // skip the '\n'
		if ev := ParseLine(root.provider, line, path); ev != nil {
			ev.AccountNumber = root.claudeAccountNumber
			p.emit(*ev)
		}
	}
	return consumed
}

func indexNL(b []byte) int {
	for i, c := range b {
		if c == '\n' {
			return i
		}
	}
	return -1
}
