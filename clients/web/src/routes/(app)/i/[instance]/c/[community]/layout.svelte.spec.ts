import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/svelte';
import { createRawSnippet, flushSync } from 'svelte';

// Reactive like the real `page` — SvelteKit replaces `params` wholesale on
// every navigation, which is exactly what the layout's guard is up against,
// so the tests need to be able to do the same.
vi.mock('$app/state', () => {
	const holder = $state({
		params: { instance: 'i1', community: 'our-club' } as Record<string, string>
	});
	return {
		page: holder,
		__setParams(next: Record<string, string>) {
			holder.params = next;
		}
	};
});
vi.mock('$lib/instances/instances.svelte.js', () => ({
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
		]
	}
}));

import * as appState from '$app/state';
import Layout from './+layout.svelte';
import { deriveAccentTokens } from '$lib/ui/accent.js';
import { refreshCommunityAccent } from '$lib/ui/accent-refresh.svelte.js';

const setParams = (appState as unknown as { __setParams: (next: Record<string, string>) => void })
	.__setParams;

const children = createRawSnippet(() => ({ render: () => '<p>community page</p>' }));

beforeEach(() => {
	setParams({ instance: 'i1', community: 'our-club' });
	vi.stubGlobal('fetch', vi.fn());
});
afterEach(() => vi.unstubAllGlobals());

describe('authed community layout', () => {
	it("re-tints the tree with the community's derived accent (issue #321, SPEC §21)", async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			new Response(
				JSON.stringify({
					data: [{ id: 'c1', name: 'Our Club', slug: 'our-club', accent_color: '#3e6b48' }]
				}),
				{ status: 200, headers: { 'content-type': 'application/json' } }
			)
		);
		const { container } = render(Layout, { props: { children } });

		// Children render immediately — the tint is additive, never a gate…
		expect(screen.getByText('community page')).toBeTruthy();
		expect(container.querySelector('[data-community-accent]')).toBeNull();

		// …and the derived palette lands once the community resolves.
		await waitFor(() => expect(container.querySelector('[data-community-accent]')).not.toBeNull());
		const style = container.querySelector('[data-community-accent]')!.getAttribute('style')!;
		expect(style).toContain(
			`--community-accent-light: ${deriveAccentTokens('#3e6b48')!.light.accent}`
		);
	});

	it('resets and refetches only on a genuine community change', async () => {
		// Fresh Response per call — the communities list serves both fetches.
		vi.mocked(fetch).mockImplementation(() =>
			Promise.resolve(
				new Response(
					JSON.stringify({
						data: [
							{ id: 'c1', name: 'Our Club', slug: 'our-club', accent_color: '#3e6b48' },
							{ id: 'c2', name: 'Other Club', slug: 'other-club', accent_color: '#8b1e3f' }
						]
					}),
					{ status: 200, headers: { 'content-type': 'application/json' } }
				)
			)
		);
		const { container } = render(Layout, { props: { children } });
		await waitFor(() => expect(container.querySelector('[data-community-accent]')).not.toBeNull());

		// Same community, new params object (what SvelteKit hands the layout
		// on every intra-community navigation): the tint must neither flash
		// back to the default nor refetch.
		setParams({ instance: 'i1', community: 'our-club' });
		flushSync();
		expect(container.querySelector('[data-community-accent]')).not.toBeNull();
		expect(fetch).toHaveBeenCalledTimes(1);

		// A genuine community change resets immediately, then re-tints.
		setParams({ instance: 'i1', community: 'other-club' });
		flushSync();
		expect(container.querySelector('[data-community-accent]')).toBeNull();
		await waitFor(() =>
			expect(container.querySelector('[data-community-accent]')?.getAttribute('style')).toContain(
				`--community-accent-light: ${deriveAccentTokens('#8b1e3f')!.light.accent}`
			)
		);
		expect(fetch).toHaveBeenCalledTimes(2);
	});

	it('re-resolves when the settings page reports a changed accent', async () => {
		const list = (accent: string) =>
			new Response(
				JSON.stringify({
					data: [{ id: 'c1', name: 'Our Club', slug: 'our-club', accent_color: accent }]
				}),
				{ status: 200, headers: { 'content-type': 'application/json' } }
			);
		vi.mocked(fetch).mockResolvedValueOnce(list('#3e6b48')).mockResolvedValueOnce(list('#8b1e3f'));
		const { container } = render(Layout, { props: { children } });
		await waitFor(() => expect(container.querySelector('[data-community-accent]')).not.toBeNull());

		// The settings page bumps the refresh version after saving a new
		// accent — the layout must re-resolve without a navigation.
		refreshCommunityAccent();
		flushSync();
		await waitFor(() =>
			expect(container.querySelector('[data-community-accent]')?.getAttribute('style')).toContain(
				`--community-accent-light: ${deriveAccentTokens('#8b1e3f')!.light.accent}`
			)
		);
		expect(fetch).toHaveBeenCalledTimes(2);
	});
});
