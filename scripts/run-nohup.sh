#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${ROOT}/.build/release/token-usage-daemon"

if [[ ! -x "${BIN}" ]]; then
  swift build -c release --package-path "${ROOT}"
fi

mkdir -p "${ROOT}/.run"
nohup "${BIN}" > "${ROOT}/.run/token-usage-daemon.out.log" 2> "${ROOT}/.run/token-usage-daemon.err.log" &
echo "$!" > "${ROOT}/.run/token-usage-daemon.pid"
printf 'token-usage-daemon pid=%s\n' "$(cat "${ROOT}/.run/token-usage-daemon.pid")"
