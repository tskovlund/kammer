import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/svelte';
import { createRawSnippet, flushSync } from 'svelte';

// Reactive like the real `page` — SvelteKit replaces `params` wholesale on
// every navigation, which is exactly what the layout's guard is up against,
// so the tests need to be able to do the same.
vi.mock('$app/state', () => {
	const holder = $state({ params: { community: 'our-club' } as Record<string, string> });
	return {
		page: holder,
		__setParams(next: Record<string, string>) {
			holder.params = next;
		}
	};
});

import * as appState from '$app/state';
import Layout from './+layout.svelte';
import { deriveAccentTokens } from '$lib/ui/accent.js';

const setParams = (appState as unknown as { __setParams: (next: Record<string, string>) => void })
	.__setParams;

const children = createRawSnippet(() => ({ render: () => '<p>public page</p>' }));

beforeEach(() => {
	setParams({ community: 'our-club' });
	vi.stubGlobal('fetch', vi.fn());
});
afterEach(() => vi.unstubAllGlobals());

describe('public community layout', () => {
	it("re-tints the tree with the community's derived accent (issue #321, SPEC §21)", async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			new Response(
				JSON.stringify({
					data: {
						community: { id: 'c1', name: 'Our Club', slug: 'our-club', accent_color: '#3e6b48' },
						groups: []
					}
				}),
				{ status: 200, headers: { 'content-type': 'application/json' } }
			)
		);
		const { container } = render(Layout, { props: { children } });

		await waitFor(() => expect(container.querySelector('[data-community-accent]')).not.toBeNull());
		const style = container.querySelector('[data-community-accent]')!.getAttribute('style')!;
		expect(style).toContain(
			`--community-accent-light: ${deriveAccentTokens('#3e6b48')!.light.accent}`
		);
		expect(screen.getByText('public page')).toBeTruthy();
	});

	it('keeps the default accent when the community is not publicly readable', async () => {
		// The tint is best-effort: the neutral 404 (issue #156/#161) must
		// leave the page rendering with untouched default tokens.
		vi.mocked(fetch).mockResolvedValueOnce(
			new Response(JSON.stringify({ error: { code: 'not_found', message: 'Not found.' } }), {
				status: 404,
				headers: { 'content-type': 'application/json' }
			})
		);
		const { container } = render(Layout, { props: { children } });

		await waitFor(() => expect(fetch).toHaveBeenCalledOnce());
		expect(container.querySelector('[data-community-accent]')).toBeNull();
		expect(screen.getByText('public page')).toBeTruthy();
	});

	it('resets and refetches only on a genuine community change', async () => {
		const community = (slug: string, accent: string) =>
			new Response(
				JSON.stringify({
					data: {
						community: { id: `c-${slug}`, name: slug, slug, accent_color: accent },
						groups: []
					}
				}),
				{ status: 200, headers: { 'content-type': 'application/json' } }
			);
		vi.mocked(fetch).mockImplementation((input) => {
			const url = input instanceof Request ? input.url : String(input);
			return Promise.resolve(
				url.includes('other-club')
					? community('other-club', '#8b1e3f')
					: community('our-club', '#3e6b48')
			);
		});
		const { container } = render(Layout, { props: { children } });
		await waitFor(() => expect(container.querySelector('[data-community-accent]')).not.toBeNull());

		// Same community, new params object (what SvelteKit hands the layout
		// on every intra-community navigation): the tint must neither flash
		// back to the default nor refetch.
		setParams({ community: 'our-club' });
		flushSync();
		expect(container.querySelector('[data-community-accent]')).not.toBeNull();
		expect(fetch).toHaveBeenCalledTimes(1);

		// A genuine community change resets immediately, then re-tints.
		setParams({ community: 'other-club' });
		flushSync();
		expect(container.querySelector('[data-community-accent]')).toBeNull();
		await waitFor(() =>
			expect(container.querySelector('[data-community-accent]')?.getAttribute('style')).toContain(
				`--community-accent-light: ${deriveAccentTokens('#8b1e3f')!.light.accent}`
			)
		);
		expect(fetch).toHaveBeenCalledTimes(2);
	});

	it('retries a failed accent resolve on the next navigation', async () => {
		vi.mocked(fetch)
			.mockRejectedValueOnce(new TypeError('network down'))
			.mockResolvedValueOnce(
				new Response(
					JSON.stringify({
						data: {
							community: { id: 'c1', name: 'Our Club', slug: 'our-club', accent_color: '#3e6b48' },
							groups: []
						}
					}),
					{ status: 200, headers: { 'content-type': 'application/json' } }
				)
			);
		const { container } = render(Layout, { props: { children } });
		// Drain the rejection cascade so the guard's re-arm has happened.
		await new Promise((resolve) => setTimeout(resolve, 0));
		expect(fetch).toHaveBeenCalledOnce();
		expect(container.querySelector('[data-community-accent]')).toBeNull();

		// A transient blip must not pin the default accent for the whole
		// visit: the next navigation — even same-community — retries once.
		setParams({ community: 'our-club' });
		flushSync();
		await waitFor(() => expect(container.querySelector('[data-community-accent]')).not.toBeNull());
		expect(fetch).toHaveBeenCalledTimes(2);
	});
});
