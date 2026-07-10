#!/usr/bin/env bash
# Runs the PWA's Playwright e2e suite (issue #235) against a throwaway dev
# database. DESTRUCTIVE for kammer_dev: clients/web/e2e/global-setup.ts
# drops and recreates it, same convention as scripts/screenshots.sh. Run
# inside the dev shell (nix develop / devbox / direnv) — `mix` must be on
# PATH since global-setup.ts shells out to it. Requires a Chromium for
# Playwright: set PLAYWRIGHT_BROWSERS_PATH at an existing install (CI and
# the container image both pre-install one — see docs/development.md), or
# `npx playwright install chromium` in clients/web.
set -euo pipefail
cd "$(dirname "$0")/.."

cd clients/web
pnpm install --frozen-lockfile
pnpm exec playwright test
