import { afterEach, describe, expect, it, vi } from 'vitest';
import { render, waitFor } from '@testing-library/svelte';

const page = vi.hoisted(() => ({
	params: { token: 'tok-1' },
	url: new URL('https://kammer.example.com/invite/tok-1')
}));
vi.mock('$app/state', () => ({ page }));
vi.mock('$app/navigation', () => ({ goto: vi.fn() }));

const fetchInvitePreview = vi.hoisted(() => vi.fn());
vi.mock('$lib/invites/api.js', () => ({
	fetchInvitePreview,
	acceptInvite: vi.fn(),
	joinedHref: vi.fn()
}));
vi.mock('$lib/instances/api.js', () => ({
	exchangeAndAddInstance: vi.fn(),
	probeInstance: vi.fn().mockRejectedValue(new Error('unreachable')),
	registerAccount: vi.fn(),
	registerErrorKeys: vi.fn(),
	requestLink: vi.fn()
}));
vi.mock('$lib/instances/instances.svelte.js', async () => {
	const { instancesMock } = await import('$lib/instances/test-support.js');
	return instancesMock({ list: [] });
});

import InvitePage from './+page.svelte';
import { deriveAccentTokens } from '$lib/ui/accent.js';

afterEach(() => {
	vi.clearAllMocks();
	document.body.innerHTML = '';
});

describe('invite landing', () => {
	// Once the token resolves the community IS known (#327), so the page
	// re-tints with its accent — additively: the default palette holds
	// while the preview is still loading.
	it("re-tints with the invited community's accent once the token resolves", async () => {
		fetchInvitePreview.mockResolvedValueOnce({
			token: 'tok-1',
			community: {
				id: 'c1',
				name: 'Our Club',
				slug: 'our-club',
				description: null,
				accent_color: '#3e6b48',
				require_real_names: false
			},
			group: null
		});
		const { container } = render(InvitePage);

		expect(container.querySelector('[data-community-accent]')).toBeNull();
		await waitFor(() => expect(container.querySelector('[data-community-accent]')).not.toBeNull());
		expect(container.querySelector('[data-community-accent]')!.getAttribute('style')).toContain(
			`--community-accent-light: ${deriveAccentTokens('#3e6b48')!.light.accent}`
		);
	});
});
