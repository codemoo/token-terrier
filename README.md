# Token Terrier

Token Terrier is a macOS menu bar app plus one standalone Go server for tracking
Claude Code and ChatGPT Codex token usage.

The public project has two runtime pieces:

- `server-go/`: the single HTTP/SSE server. It reads local OAuth credentials,
  local Claude/Codex JSONL session logs, and optional local Hermes SQLite data.
- `Sources/token-run-menubar/`: the macOS MenuBarExtra client. It subscribes to
  the server over SSE, or can run a local-direct fallback on the same Mac.

Machine-specific deployment files, private hostnames, tunnels, and reverse proxy
settings are intentionally not part of the repo.

## Build

```sh
swift build
swift test

cd server-go
go test ./...
go build ./cmd/daemon
```

## Run Server

Run the server on the same machine that has the Claude/Codex credentials and
session logs:

```sh
cd server-go
go run ./cmd/daemon
```

Defaults:

- HTTP bind: `127.0.0.1:18910`
- Bearer tokens: `~/.config/token-usage/tokens.json`, generated on first run
- Claude credentials: `~/.claude/.credentials.json`
- Codex credentials: `~/.codex/auth.json`
- Claude JSONL: `~/.claude/projects/**/*.jsonl`
- Codex JSONL: `~/.codex/sessions/**/*.jsonl`
- Hermes SQLite: `~/.hermes/state.db`

Useful environment variables:

```sh
TOKEN_USAGE_BIND=127.0.0.1
TOKEN_USAGE_PORT=18910
TOKEN_USAGE_CLAUDE_CRED=/path/to/.claude/.credentials.json
TOKEN_USAGE_CODEX_CRED=/path/to/.codex/auth.json
TOKEN_USAGE_CLAUDE_PROJECTS=/path/to/.claude/projects
TOKEN_USAGE_CODEX_SESSIONS=/path/to/.codex/sessions
TOKEN_USAGE_HERMES_DB=/path/to/.hermes/state.db
TOKEN_USAGE_DISABLE_JSONL=1
TOKEN_USAGE_DISABLE_HERMES=1
```

Endpoints:

```text
GET /healthz
GET /version
GET /claude/snapshot
GET /claude/sse
GET /codex/snapshot
GET /codex/sse
```

`/claude/*` and `/codex/*` require provider-specific bearer tokens from
`~/.config/token-usage/tokens.json`.

## Run Menu Bar App

```sh
swift run token-run-menubar
```

For a packaged Sparkle-updatable app:

```sh
VERSION=0.10.15 GITHUB_REPOSITORY=OWNER/token-terrier GITHUB_RELEASE=1 ./scripts/release.sh
```

The app's remote endpoint field should contain only the server base URL, for
example `https://your-token-server.example.com`. The app then connects to
`/claude/sse` and `/codex/sse`.

## Notes

- The app icon and menu bar animation use bundled Bedlington Terrier assets.
- Sparkle signing uses `infra/sparkle-public-key.txt`; the private key is ignored.
- Current app packaging is host-architecture and ad-hoc signed. Broader public
  distribution still needs Developer ID signing and notarization.

## License

MIT. Codex OAuth refresh parameters and endpoint are attributed to the CodexBar
prior art.
