import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/svelte';
import { createRawSnippet } from 'svelte';

// The root layout's own dependencies are stubbed so it mounts in
// isolation — the boundary, not the layout's service-worker/notification
// wiring, is under test.
vi.mock('$app/navigation', () => ({ goto: vi.fn(), afterNavigate: vi.fn() }));
vi.mock('$app/paths', () => ({ base: '', resolve: (path: string) => path }));
vi.mock('$app/state', () => ({ page: { url: new URL('https://pwa.example/') } }));
vi.mock('$lib/pwa/register-service-worker.js', () => ({ registerServiceWorker: vi.fn() }));
vi.mock('$lib/push/notification-routing.js', () => ({ resolveNotificationPath: vi.fn() }));
vi.mock('$lib/instances/instances.svelte.js', () => ({ instances: { list: [] } }));

import Layout from './+layout.svelte';

// A child whose first render throws — a client render error on a tokenless
// shell (SSR off), the case +error.svelte can't catch (#316).
const boom = createRawSnippet(() => ({
	render: (): string => {
		throw new Error('boom');
	}
}));

beforeEach(() => vi.spyOn(console, 'error').mockImplementation(() => {}));
afterEach(() => {
	vi.restoreAllMocks();
	document.body.innerHTML = '';
});

describe('root render boundary', () => {
	it('degrades a crashed shell to the recoverable card instead of a white screen', () => {
		render(Layout, { props: { children: boom } });

		expect(screen.getByText('Something went wrong here')).toBeTruthy();
		expect(screen.getByRole('button', { name: 'Try again' })).toBeTruthy();
		// The boundary's own logger, not just any console.error.
		expect(console.error).toHaveBeenCalledWith('[kammer] app crashed', expect.anything());
	});
});
