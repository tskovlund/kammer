import { defineConfig, devices } from '@playwright/test';

// End-to-end suite for the instance-served PWA (issue #235) — the
// replacement for the LiveView-driving smoke test (scripts/screenshots.sh)
// and a prerequisite for the LiveView removal (#187). Chromium-only: the
// pre-installed browser in CI/dev containers, and cross-browser coverage
// isn't the point of this suite (Vitest already covers component/unit
// logic across environments).
//
// Single origin, same as production: `globalSetup` (global-setup.ts)
// builds the client, stages it at `priv/static/app` — exactly where the
// Dockerfile's client stage puts it — and boots `mix phx.server`, which
// then serves both the API and the client itself under `/app` (see
// `KammerWeb.PwaController`). No separate `webServer` entry: an earlier
// version ran the client through `vite preview` on its own port, but the
// deep-link sign-in flow trusts `window.location.origin` to be the
// instance it should talk to (see e2e/01-onboarding.spec.ts) — a second
// origin broke that assumption instead of merely adding indirection.
export default defineConfig({
	testDir: './e2e',
	globalSetup: './e2e/global-setup.ts',
	fullyParallel: false,
	workers: 1,
	retries: process.env.CI ? 1 : 0,
	reporter: process.env.CI ? [['github'], ['list']] : 'list',
	use: {
		baseURL: 'http://localhost:4000',
		trace: 'retain-on-failure',
		// Pinned so datetime-local fixtures (the event flow) don't depend on
		// the host machine's timezone.
		timezoneId: 'UTC',
		// CHROMIUM_BIN points Playwright at a pre-installed browser instead
		// of downloading its own — the same env var and rationale as
		// scripts/screenshots.mjs (the LiveView smoke test's Playwright
		// driver). CI sets it to the Actions runner's bundled Google Chrome;
		// unset locally, this is `undefined` and Playwright resolves its own
		// managed browser normally (PLAYWRIGHT_BROWSERS_PATH, if set, still
		// applies in that case).
		launchOptions: { executablePath: process.env.CHROMIUM_BIN || undefined }
	},
	projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }]
});
