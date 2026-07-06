#!/usr/bin/env bash
# Regenerates docs/screenshots/ against a throwaway dev database.
# DESTRUCTIVE for kammer_dev: it drops and recreates it. Run inside the
# dev shell (nix develop / devbox / direnv). Requires a Chromium for
# Playwright: set CHROMIUM_BIN, or `npx playwright install chromium`.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Resetting dev database (kammer_dev)…"
mix ecto.drop --quiet 2>/dev/null || true
mix ecto.create --quiet
mix ecto.migrate --quiet

log=$(mktemp)
echo "Booting dev server…"
mix phx.server >"$log" 2>&1 &
server_pid=$!
trap 'kill $server_pid 2>/dev/null || true' EXIT

for _ in $(seq 1 60); do
  grep -q "Running KammerWeb.Endpoint" "$log" && break
  sleep 1
done
token=$(grep -A 3 "enter this setup token" "$log" | tail -1 | tr -d ' ')
[ -n "$token" ] || { echo "no setup token in server log" >&2; exit 1; }

node scripts/screenshots.mjs --token "$token" --out docs/screenshots
echo "Done — review the diff under docs/screenshots/ and commit it."
