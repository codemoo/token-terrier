# AGENTS.md

This file is for AI coding agents working in this repository. Keep it focused on
safe setup, verification, and release behavior.

## Project Shape

Token Terrier has two public runtime pieces:

- `Sources/token-run-menubar/`: the macOS SwiftUI menu bar app.
- `server-go/`: the standalone Go HTTP/SSE server.

Shared Swift app logic lives in `Sources/TokenUsageCore/`. The server reads local
Claude/Codex credentials, local JSONL session logs, and optional local Hermes
SQLite data.

## Public Repo Boundary

The public repository must stay generic. Do not commit machine-specific
deployment files, hostnames, private domains, tunnels, reverse proxy configs, SSH
bridge code, launch agents, local tokens, local release artifacts, or Sparkle
private keys.

In particular, do not add or restore these paths:

- `Sources/token-usage-daemon/`
- `Vendor/hummingbird/`
- `Vendor/swift-nio/`
- `launchd/`
- `docs/operations.md`
- `scripts/run-nohup.sh`
- `server-go/deploy/`
- `server-go/internal/source/`
- `server-go/heap-snapshots/`
- `build/`
- `releases/`
- `dist/`

The only tracked file under `infra/` should be
`infra/sparkle-public-key.txt`. Sparkle private keys must remain local only.

## Build And Test

From the repository root:

```sh
swift build
swift test
```

For the Go server:

```sh
cd server-go
go test ./...
go build ./cmd/daemon
```

If sandboxed tooling blocks Swift or Go cache access, rerun the same command with
normal user cache access instead of changing project paths.

## Run Locally

Run the standalone server on the machine that has the credentials and logs:

```sh
cd server-go
go run ./cmd/daemon
```

Defaults:

- HTTP bind: `127.0.0.1:18910`
- Bearer tokens: `~/.config/token-usage/tokens.json`
- Claude credentials: `~/.claude/.credentials.json`
- Codex credentials: `~/.codex/auth.json`
- Claude JSONL: `~/.claude/projects/**/*.jsonl`
- Codex JSONL: `~/.codex/sessions/**/*.jsonl`
- Hermes SQLite: `~/.hermes/state.db`

Run the menu bar app during development:

```sh
swift run token-run-menubar
```

## Release

Use GitHub Releases for Sparkle updates:

```sh
VERSION=x.y.z GITHUB_REPOSITORY=codemoo/token-terrier GITHUB_RELEASE=1 ./scripts/release.sh
```

The release script expects the Sparkle private key at
`infra/sparkle-private-key.backup`, but that file must never be committed.

Do not create a new app release for documentation-only changes.

## Coding Notes

- Prefer existing Swift and Go patterns over new abstractions.
- Keep README user-facing; keep this file agent-facing.
- Keep the server standalone and local-filesystem based.
- Keep default remote server URLs empty or placeholder-only.
- Use `rg` for searches and inspect staged content before pushing.
- Before publishing, verify that staged content does not contain private
  hostnames, private paths, SSH bridge code, tunnels, reverse proxy configs, or
  local tokens.
