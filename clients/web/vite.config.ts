import tailwindcss from '@tailwindcss/vite';
import { defineConfig } from 'vitest/config';
import adapter from '@sveltejs/adapter-static';
import { sveltekit } from '@sveltejs/kit/vite';
import { svelteTesting } from '@testing-library/svelte/vite';

export default defineConfig({
	plugins: [
		tailwindcss(),
		sveltekit({
			compilerOptions: {
				// Force runes mode for the project, except for libraries. Can be removed in svelte 6.
				runes: ({ filename }) =>
					filename.split(/[/\\]/).includes('node_modules') ? undefined : true
			},
			adapter: adapter({ fallback: 'index.html' }),
			// Served by the Phoenix release under /app while LiveView still owns /
			// (issue #176; flip to '' at the LiveView removal cut, #187, together
			// with :pwa_base_path in config/config.exs).
			paths: { base: '/app' },
			// $lib/pwa/register-service-worker.ts owns registration (issue
			// #186) — production-only, with update/reload policy attached.
			// SvelteKit's own auto-registration must be off, not merely
			// redundant: it registers with a different `type` (classic; ours
			// is module), and re-registering the same URL with different
			// options makes the browser install a "new" worker on every page
			// load — two registrations ping-ponging like that put every
			// controlled page in an endless controllerchange→reload loop.
			serviceWorker: { register: false }
		})
	],
	test: {
		expect: { requireAssertions: true },
		projects: [
			{
				extends: './vite.config.ts',
				test: {
					name: 'server',
					environment: 'node',
					include: ['src/**/*.{test,spec}.{js,ts}'],
					exclude: ['src/**/*.svelte.{test,spec}.{js,ts}', 'src/**/*.dom.{test,spec}.{js,ts}']
				}
			},
			{
				// DOM-dependent tests (Svelte actions, component focus/a11y behaviour)
				// run under jsdom; `.dom.spec` and `.svelte.spec` files opt in.
				// `svelteTesting` resolves the browser build so components mount.
				extends: './vite.config.ts',
				plugins: [svelteTesting()],
				test: {
					name: 'client',
					environment: 'jsdom',
					include: ['src/**/*.svelte.{test,spec}.{js,ts}', 'src/**/*.dom.{test,spec}.{js,ts}']
				}
			}
		]
	}
});
