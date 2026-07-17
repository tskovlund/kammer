import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';

vi.mock('$app/state', () => ({
	page: { params: { instance: 'i1', community: 'our-club' } }
}));
vi.mock('$lib/instances/instances.svelte.js', async () => {
	const { instancesMock, testInstance } = await import('$lib/instances/test-support.js');
	return instancesMock({ list: [testInstance('i1', 'Example')] });
});

import Page from './+page.svelte';

function jsonResponse(status: number, body: unknown) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

function auditEvent(id: string, summary: string) {
	return {
		id,
		action: 'community.settings_updated',
		summary,
		metadata: {},
		inserted_at: '2026-07-17T10:00:00Z',
		actor: null
	};
}

const community = {
	id: 'c1',
	name: 'Our Club',
	slug: 'our-club',
	viewer_can: ['manage_community']
};

beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
afterEach(() => {
	vi.unstubAllGlobals();
	document.body.innerHTML = '';
});

describe('community audit log page', () => {
	// The cursor-pagination fix for #340: the log used to fetch once and
	// silently drop anything past the first (then-hard-capped) page.
	it('shows older entries on demand and hides the button once the log is exhausted', async () => {
		vi.mocked(fetch)
			.mockResolvedValueOnce(jsonResponse(200, { data: [community] }))
			.mockResolvedValueOnce(
				jsonResponse(200, {
					data: [auditEvent('e2', 'second'), auditEvent('e1', 'first')],
					next_cursor: 'cursor-1'
				})
			)
			.mockResolvedValueOnce(
				jsonResponse(200, { data: [auditEvent('e0', 'zeroth')], next_cursor: null })
			);

		render(Page);

		await waitFor(() => expect(screen.getByText('second')).toBeTruthy());
		expect(screen.getByText('first')).toBeTruthy();
		expect(screen.queryByText('zeroth')).toBeNull();

		const loadMore = document.querySelector('#audit-log-load-more') as HTMLButtonElement;
		expect(loadMore).toBeTruthy();

		await fireEvent.click(loadMore);

		await waitFor(() => expect(screen.getByText('zeroth')).toBeTruthy());
		// Every earlier entry stays on screen — "show older" appends.
		expect(screen.getByText('second')).toBeTruthy();
		expect(screen.getByText('first')).toBeTruthy();
		// The log is exhausted (next_cursor: null): no more button.
		expect(document.querySelector('#audit-log-load-more')).toBeNull();

		expect(fetch).toHaveBeenCalledTimes(3);
		const loadMoreRequest = vi.mocked(fetch).mock.calls[2][0] as Request;
		expect(loadMoreRequest.url).toContain('after=cursor-1');
	});

	it('keeps the loaded page and stays retryable when "show older" itself fails', async () => {
		vi.mocked(fetch)
			.mockResolvedValueOnce(jsonResponse(200, { data: [community] }))
			.mockResolvedValueOnce(
				jsonResponse(200, {
					data: [auditEvent('e2', 'second')],
					next_cursor: 'cursor-1'
				})
			)
			.mockResolvedValueOnce(jsonResponse(500, { error: { code: 'server_error' } }));

		render(Page);

		await waitFor(() => expect(screen.getByText('second')).toBeTruthy());
		const loadMore = document.querySelector('#audit-log-load-more') as HTMLButtonElement;
		await fireEvent.click(loadMore);

		await waitFor(() => expect(screen.getByRole('alert')).toBeTruthy());
		// The already-loaded entry and the retry affordance both survive
		// the failed page — a load-more error must not blank the log.
		expect(screen.getByText('second')).toBeTruthy();
		expect(document.querySelector('#audit-log-load-more')).toBeTruthy();
	});
});
