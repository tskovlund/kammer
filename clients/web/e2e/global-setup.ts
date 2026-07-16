import { type ChildProcess, execFileSync, spawn } from 'node:child_process';
import { cpSync, mkdirSync, openSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PHOENIX_BASE } from './support/scenario.js';

// clients/web/e2e -> clients/web -> clients -> repo root.
const REPO_ROOT = path.resolve(fileURLToPath(new URL('.', import.meta.url)), '../../..');
const CLIENT_ROOT = path.join(REPO_ROOT, 'clients/web');
const PWA_STATIC_ROOT = path.join(REPO_ROOT, 'priv/static/app');
export const AUTH_DIR = path.resolve(fileURLToPath(new URL('.', import.meta.url)), '.auth');
const SERVER_LOG = path.join(AUTH_DIR, 'phx-server.log');
export const SETUP_TOKEN_FILE = path.join(AUTH_DIR, 'setup-token.json');
export const STORAGE_STATE_FILE = path.join(AUTH_DIR, 'operator-state.json');

function runMix(args: string[]): void {
	execFileSync('mix', args, { cwd: REPO_ROOT, stdio: 'inherit' });
}

/**
 * Builds the SvelteKit static output and stages it exactly where the
 * endpoint expects the client bundle in a real deployment
 * (`priv/static/app` on disk — see `Dockerfile`'s client stage and
 * `:pwa_static_root` in config/config.exs). This is what makes the suite
 * same-origin: `PwaController` then serves the client at the site root
 * off the same Phoenix
 * process as `/api/*`, so `window.location.origin` inside the client
 * (used by the deep-link sign-in route to know which instance to talk
 * to — see e2e/01-onboarding.spec.ts) is correct without any dev-only
 * proxy or CORS workaround. A separate `vite preview` server on its own
 * port was tried first and rejected for exactly this reason: it leaves
 * the client at a different origin than the API it needs to call.
 */
function buildAndStageClient(): void {
	execFileSync('pnpm', ['run', 'build'], { cwd: CLIENT_ROOT, stdio: 'inherit' });
	rmSync(PWA_STATIC_ROOT, { recursive: true, force: true });
	cpSync(path.join(CLIENT_ROOT, 'build'), PWA_STATIC_ROOT, { recursive: true });
}

async function waitForHealthz(deadline: number): Promise<void> {
	while (Date.now() < deadline) {
		try {
			const response = await fetch(`${PHOENIX_BASE}/healthz`);
			if (response.ok) return;
		} catch {
			// Not accepting connections yet.
		}
		await new Promise((resolve) => setTimeout(resolve, 500));
	}
	throw new Error(`Phoenix never answered /healthz — see ${SERVER_LOG}`);
}

// The banner sits inside a block with surrounding blank lines; match the
// token's shape (URL-safe base64) rather than a line offset, same as
// scripts/screenshots.sh.
function extractSetupToken(log: string): string | null {
	const bannerIndex = log.indexOf('enter this setup token');
	if (bannerIndex === -1) return null;
	const match = log.slice(bannerIndex, bannerIndex + 400).match(/[A-Za-z0-9_-]{20,}/);
	return match?.[0] ?? null;
}

/**
 * Boots the real stack the specs drive: builds and stages the PWA, resets
 * & migrates the database, then starts `mix phx.server` (serving both the
 * API and the client, same origin, same process) and waits for the
 * first-run setup token to land in its logs. Mirrors
 * `scripts/screenshots.sh`'s boot sequence (same throwaway-`kammer_dev`
 * convention — the CI job's Postgres service is a fresh container per
 * run, so "dedicated" and "kammer_dev" coincide there; locally this is
 * exactly as destructive as running that script).
 */
export default async function globalSetup(): Promise<() => Promise<void>> {
	// Clear leftovers from a previous run first: a stale operator
	// storageState would otherwise hand later specs a device token the
	// freshly-reset database has never seen (a confusing local 401).
	rmSync(AUTH_DIR, { recursive: true, force: true });
	mkdirSync(AUTH_DIR, { recursive: true });

	buildAndStageClient();

	try {
		runMix(['ecto.drop', '--quiet']);
	} catch {
		// No database yet on a fresh checkout — fine, `ecto.create` below
		// makes one.
	}
	runMix(['ecto.create', '--quiet']);
	runMix(['ecto.migrate', '--quiet']);

	const logFd = openSync(SERVER_LOG, 'w');
	const server: ChildProcess = spawn('mix', ['phx.server'], {
		cwd: REPO_ROOT,
		stdio: ['ignore', logFd, logFd]
	});

	const deadline = Date.now() + 60_000;
	let token: string | null = null;
	while (Date.now() < deadline) {
		const log = readFileSync(SERVER_LOG, 'utf8');
		if (log.includes('Running KammerWeb.Endpoint')) {
			token = extractSetupToken(log);
			if (token) break;
		}
		if (server.exitCode !== null) {
			throw new Error(`mix phx.server exited early (${server.exitCode}) — see ${SERVER_LOG}`);
		}
		await new Promise((resolve) => setTimeout(resolve, 500));
	}
	if (!token) {
		server.kill('SIGTERM');
		throw new Error(`no setup token in server log within 60s — see ${SERVER_LOG}`);
	}

	// A fresh window rather than the boot deadline's remainder — a slow
	// boot must not starve the probe of its budget.
	await waitForHealthz(Date.now() + 30_000);
	writeFileSync(SETUP_TOKEN_FILE, JSON.stringify({ token }));

	return async () => {
		server.kill('SIGTERM');
	};
}
