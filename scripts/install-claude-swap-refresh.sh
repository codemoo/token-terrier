#!/bin/sh
# Install a LaunchAgent that runs scripts/claude-swap-refresh.sh every 5 min,
# keeping the claude-swap accounts file fresh for token-terrier.
# The generated plist is machine-local (untracked); this generator is generic.
set -eu

LABEL="ai.openclaw.token-usage-claude-swap-refresh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/scripts/claude-swap-refresh.sh"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
INTERVAL="${REFRESH_INTERVAL:-300}"
case "$INTERVAL" in
	''|0|*[!0-9]*)
		echo "install-claude-swap-refresh: REFRESH_INTERVAL must be a positive integer, got '${INTERVAL}'" >&2
		exit 1
		;;
esac
LOGDIR="${HOME}/Library/Logs/token-terrier"

chmod +x "$SCRIPT"
mkdir -p "$(dirname "$PLIST")" "$LOGDIR"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/sh</string>
		<string>${SCRIPT}</string>
	</array>
	<key>StartInterval</key><integer>${INTERVAL}</integer>
	<key>RunAtLoad</key><true/>
	<key>StandardOutPath</key><string>${LOGDIR}/claude-swap-refresh.out.log</string>
	<key>StandardErrorPath</key><string>${LOGDIR}/claude-swap-refresh.err.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/${LABEL}"
echo "installed ${LABEL} (every ${INTERVAL}s)"
