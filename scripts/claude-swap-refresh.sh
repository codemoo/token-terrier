#!/bin/sh
# Refresh the claude-swap accounts snapshot that token-terrier reads.
# Runs `cswap --list --json` and atomically writes it to the accounts file.
# The daemon NEVER runs cswap itself — this script is the only thing that does.
# Never prints emails / account data (privacy).
set -eu

CSWAP="${CSWAP_BIN:-$HOME/.local/bin/cswap}"
OUT="${TOKEN_USAGE_CLAUDE_SWAP_ACCOUNTS:-$HOME/.config/token-usage/claude-swap-accounts.json}"
LOCK="${OUT}.lock"

# Single-flight: if a previous run is still going (e.g. cswap blocked on a
# Keychain prompt), skip this tick rather than pile up. The stale file just
# ages; the daemon marks it accordingly. Never blocks anything else.
if ! mkdir "$LOCK" 2>/dev/null; then
	exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

if [ ! -x "$CSWAP" ]; then
	exit 0
fi

mkdir -p "$(dirname "$OUT")"
TMP="$(mktemp "${OUT}.XXXXXX")"

# Optional watchdog: kill cswap if it hangs (no `timeout` on stock macOS).
"$CSWAP" --list --json >"$TMP" 2>/dev/null &
CPID=$!
( sleep 25; kill "$CPID" 2>/dev/null || true ) &
WPID=$!
if wait "$CPID" 2>/dev/null && [ -s "$TMP" ]; then
	chmod 600 "$TMP"
	mv -f "$TMP" "$OUT"
else
	rm -f "$TMP"   # keep last-good file on failure/empty/timeout
fi
kill "$WPID" 2>/dev/null || true
