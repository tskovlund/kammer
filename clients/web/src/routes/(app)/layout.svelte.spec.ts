import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/svelte';
import { createRawSnippet } from 'svelte';

vi.mock('$app/state', () => ({ page: { url: new URL('https://pwa.example/') } }));
vi.mock('$app/navigation', () => ({ goto: vi.fn() }));
vi.mock('$lib/instances/instances.svelte', () => ({
	instances: {
		list: [
			{
				id: 'i1',
				baseUrl: 'https://kammer.example.com',
				instanceName: 'Example',
				deviceToken: 'token-1',
				user: { id: 'u1', email: 'a@example.com', displayName: 'Alice' },
				addedAt: '2026-01-01T00:00:00Z'
			}
		],
		refresh: vi.fn()
	}
}));

import Layout from './+layout.svelte';

// A child whose very first render throws — the "one bad post" case the
// shell boundary exists for (part of #270).
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

describe('app shell error boundary', () => {
	it('degrades a crashed screen to an inline card, keeping the nav usable', () => {
		render(Layout, { props: { children: boom } });

		// The branded fallback with its retry affordance, not a white screen…
		expect(screen.getByText('Something went wrong here')).toBeTruthy();
		expect(screen.getByRole('button', { name: 'Try again' })).toBeTruthy();
		expect(console.error).toHaveBeenCalled();

		// …and the navigation stays outside the boundary, so the user can
		// always leave the broken screen.
		expect(screen.getAllByRole('navigation').length).toBeGreaterThan(0);
	});
});
