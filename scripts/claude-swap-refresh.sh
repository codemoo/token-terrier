#!/bin/sh
# Refresh the claude-swap accounts snapshot that token-terrier reads.
# Runs `cswap --list --json` and atomically writes it to the accounts file.
# The daemon NEVER runs cswap itself — this script is the only thing that does.
# Never prints emails / account data (privacy).
set -eu

CSWAP="${CSWAP_BIN:-$HOME/.local/bin/cswap}"
OUT="${TOKEN_USAGE_CLAUDE_SWAP_ACCOUNTS:-$HOME/.config/token-usage/claude-swap-accounts.json}"
LOCK="${OUT}.lock"
TMP=""

# The lock lives next to $OUT, so the target directory must exist before we
# even attempt to acquire it — otherwise `mkdir "$LOCK"` fails with ENOENT,
# which (with stderr discarded) is indistinguishable from "lock held", and
# the script would silently no-op forever on every run.
mkdir -p "$(dirname "$OUT")"

# Reclaim a stale lock left behind by a hard-killed previous run (SIGKILL,
# crash, reboot) so we don't no-op forever. 5 minutes is comfortably longer
# than the cswap watchdog below.
if [ -d "$LOCK" ] && [ -z "$(find "$LOCK" -maxdepth 0 -mmin -5 2>/dev/null)" ]; then
	rmdir "$LOCK" 2>/dev/null || true
fi

# Single-flight: if a previous run is still going (e.g. cswap blocked on a
# Keychain prompt), skip this tick rather than pile up. The stale file just
# ages; the daemon marks it accordingly. Never blocks anything else.
if ! mkdir "$LOCK" 2>/dev/null; then
	exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true; rm -f "$TMP" 2>/dev/null || true' EXIT

if [ ! -x "$CSWAP" ]; then
	exit 0
fi

TMP="$(mktemp "${OUT}.XXXXXX")"

# Optional watchdog: kill cswap if it hangs (no `timeout` on stock macOS).
"$CSWAP" --list --json >"$TMP" 2>/dev/null &
CPID=$!
( sleep 25; kill "$CPID" 2>/dev/null || true ) &
WPID=$!
if wait "$CPID" 2>/dev/null && [ -s "$TMP" ]; then
	VALID=1
	if command -v python3 >/dev/null 2>&1; then
		if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TMP" >/dev/null 2>&1; then
			VALID=0
		fi
	fi
	if [ "$VALID" -eq 1 ]; then
		chmod 600 "$TMP"
		mv -f "$TMP" "$OUT"
	else
		rm -f "$TMP"   # keep last-good file: cswap output wasn't valid JSON
	fi
else
	rm -f "$TMP"   # keep last-good file on failure/empty/timeout
fi
kill "$WPID" 2>/dev/null || true
