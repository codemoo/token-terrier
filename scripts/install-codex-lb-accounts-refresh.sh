#!/bin/sh
# Install a LaunchAgent that runs scripts/codex-lb-accounts-refresh.py every 5 min,
# keeping the codex-lb per-account file fresh for token-terrier.
#
# The codex-lb dashboard password is read at runtime from a 0600 env file
# (default ~/.config/token-usage/codex-lb-refresh.env) that this script sources
# via the LaunchAgent — it is NEVER written into the plist body (world-readable)
# and NEVER committed. The daemon itself never logs in; only this job does.
# The generated plist is machine-local (untracked); this generator is generic.
set -eu

LABEL="ai.openclaw.token-usage-codex-lb-refresh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/scripts/codex-lb-accounts-refresh.py"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
ENV_FILE="${CODEX_LB_REFRESH_ENV:-${HOME}/.config/token-usage/codex-lb-refresh.env}"
INTERVAL="${REFRESH_INTERVAL:-300}"
case "$INTERVAL" in
	''|0|*[!0-9]*)
		echo "install-codex-lb-accounts-refresh: REFRESH_INTERVAL must be a positive integer, got '${INTERVAL}'" >&2
		exit 1
		;;
esac
LOGDIR="${HOME}/Library/Logs/token-terrier"

mkdir -p "$(dirname "$PLIST")" "$LOGDIR" "$(dirname "$ENV_FILE")"

# Ensure a 0600 env file exists (do NOT overwrite an existing one). The user
# puts the codex-lb dashboard password here — it stays out of git and the plist.
if [ ! -f "$ENV_FILE" ]; then
	umask 077
	cat > "$ENV_FILE" <<'ENVEOF'
# codex-lb accounts refresher env (0600). NOT committed. NOT in the plist body.
# Put the codex-lb dashboard password on the next line (no quotes):
CODEX_LB_DASHBOARD_PASSWORD=
# Optional overrides:
# CODEX_LB_URL=http://127.0.0.1:2455
ENVEOF
	chmod 600 "$ENV_FILE"
	echo "created ${ENV_FILE} (0600) — set CODEX_LB_DASHBOARD_PASSWORD in it, then re-run or kickstart."
fi
chmod 600 "$ENV_FILE" 2>/dev/null || true

# Warn (do not fail) if the password is still blank — the refresher stays dormant.
if ! grep -qE '^CODEX_LB_DASHBOARD_PASSWORD=.+' "$ENV_FILE" 2>/dev/null; then
	echo "warning: CODEX_LB_DASHBOARD_PASSWORD not set in ${ENV_FILE} — refresher will stay dormant." >&2
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/sh</string>
		<string>-lc</string>
		<string>set -a; . "${ENV_FILE}"; set +a; exec python3 "${SCRIPT}"</string>
	</array>
	<key>StartInterval</key><integer>${INTERVAL}</integer>
	<key>RunAtLoad</key><true/>
	<key>StandardOutPath</key><string>${LOGDIR}/codex-lb-refresh.out.log</string>
	<key>StandardErrorPath</key><string>${LOGDIR}/codex-lb-refresh.err.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/${LABEL}"
echo "installed ${LABEL} (every ${INTERVAL}s, env ${ENV_FILE})"
