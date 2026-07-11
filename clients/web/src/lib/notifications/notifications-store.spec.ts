import { beforeEach, describe, expect, it, vi } from 'vitest';
import { FeedApiError } from '$lib/feed/api.js';
import type { Instance } from '$lib/instances/types.js';
import type { Notification } from './api.js';

vi.mock('./api.js', async (importActual) => {
	const actual = await importActual<typeof import('./api.js')>();
	return { ...actual, fetchNotificationsPage: vi.fn(), markRead: vi.fn(), markAllRead: vi.fn() };
});

import * as api from './api.js';
import { createNotificationsStore } from './notifications-store.svelte.js';

function instance(id: string, name: string): Instance {
	return {
		id,
		baseUrl: `https://${id}.example`,
		instanceName: name,
		deviceToken: 't',
		user: { id: `${id}-user`, email: 'a@a', displayName: 'A' },
		addedAt: '2026-01-01T00:00:00Z'
	};
}

function notification(id: string, insertedAt: string, read = false): Notification {
	return {
		id,
		kind: 'mention',
		actor: { id: 'actor', display_name: 'Alice', type: 'user' },
		post_id: 'p1',
		comment_id: null,
		event_id: null,
		group: { id: 'g1', name: 'Group', slug: 'group' },
		inserted_at: insertedAt,
		read,
		read_at: read ? insertedAt : null
	};
}

const mockPage = vi.mocked(api.fetchNotificationsPage);
const mockMarkRead = vi.mocked(api.markRead);
const mockMarkAllRead = vi.mocked(api.markAllRead);

describe('createNotificationsStore', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('merges notifications across instances newest-first and counts unread', async () => {
		const a = instance('ia', 'Alpha');
		const b = instance('ib', 'Beta');
		mockPage.mockImplementation(async (inst) => ({
			notifications:
				inst.id === 'ia'
					? [notification('old', '2026-06-01T10:00:00Z', true)]
					: [
							notification('newest', '2026-06-03T10:00:00Z'),
							notification('middle', '2026-06-02T10:00:00Z')
						],
			nextCursor: null
		}));

		const store = createNotificationsStore();
		await store.load([a, b]);

		expect(store.items.map((n) => n.id)).toEqual(['newest', 'middle', 'old']);
		expect(store.items.map((n) => n.instance.id)).toEqual(['ib', 'ib', 'ia']);
		expect(store.unreadCount).toBe(2);
		expect(store.loadState).toBe('ready');
	});

	it('surfaces a failing instance without blanking the rest, errors only when all fail', async () => {
		const ok = instance('ok', 'OK');
		const bad = instance('bad', 'Bad');
		mockPage.mockImplementation(async (inst) => {
			if (inst.id === 'bad') throw new FeedApiError('auth', 'signed out', 401);
			return { notifications: [notification('n1', '2026-06-01T10:00:00Z')], nextCursor: null };
		});

		const store = createNotificationsStore();
		await store.load([ok, bad]);

		expect(store.failedInstances).toEqual([{ instance: bad, kind: 'auth' }]);
		expect(store.items.map((n) => n.id)).toEqual(['n1']);
		expect(store.loadState).toBe('ready');

		await store.load([bad]);
		expect(store.loadState).toBe('error');
	});

	it('marks read optimistically — the flip lands before the request resolves', async () => {
		const a = instance('ia', 'Alpha');
		mockPage.mockResolvedValue({
			notifications: [notification('n1', '2026-06-01T10:00:00Z')],
			nextCursor: null
		});
		const store = createNotificationsStore();
		await store.load([a]);

		let releaseMark: (() => void) | undefined;
		mockMarkRead.mockImplementation(
			() => new Promise<void>((resolvePromise) => (releaseMark = resolvePromise))
		);
		const pending = store.markRead(store.items[0]);
		// The optimistic window: read flips while the PUT is still in flight.
		expect(store.items[0].read).toBe(true);
		expect(store.unreadCount).toBe(0);
		releaseMark?.();
		await pending;
		expect(mockMarkRead).toHaveBeenCalledWith(a, 'n1');

		// Already-read: no second API call.
		await store.markRead(store.items[0]);
		expect(mockMarkRead).toHaveBeenCalledTimes(1);
	});

	it('resyncs from the server when a mark-read is rejected', async () => {
		const a = instance('ia', 'Alpha');
		mockPage.mockResolvedValue({
			notifications: [notification('n1', '2026-06-01T10:00:00Z')],
			nextCursor: null
		});
		const store = createNotificationsStore();
		await store.load([a]);

		mockMarkRead.mockRejectedValue(new FeedApiError('server', 'boom', 500));
		await store.markRead(store.items[0]);
		await vi.waitFor(() => expect(mockPage).toHaveBeenCalledTimes(2));
		// The reload's payload (read=false, per the mock) is the truth shown.
		await vi.waitFor(() => expect(store.items[0].read).toBe(false));
	});

	it('mark-all-read fans out to every account — unread items beyond the loaded page must clear too', async () => {
		const good = instance('good', 'Good');
		const readOnly = instance('read', 'Read');
		mockPage.mockImplementation(async (inst) => ({
			notifications: [notification(`${inst.id}-n`, '2026-06-01T10:00:00Z', inst.id === 'read')],
			nextCursor: null
		}));
		mockMarkAllRead.mockResolvedValue(undefined);

		const store = createNotificationsStore();
		await store.load([good, readOnly]);
		await store.markAllRead();

		// Both accounts are called — even the one with nothing visibly unread
		// (its older, unloaded notifications must clear as well).
		expect(mockMarkAllRead.mock.calls.map(([inst]) => inst.id).sort()).toEqual(['good', 'read']);
		expect(store.items.every((n) => n.read)).toBe(true);
		expect(mockPage).toHaveBeenCalledTimes(2); // no resync on success
	});

	it('loads older pages per instance until the cursor is exhausted', async () => {
		const a = instance('ia', 'Alpha');
		mockPage
			.mockResolvedValueOnce({
				notifications: [notification('new', '2026-06-02T10:00:00Z')],
				nextCursor: 'c1'
			})
			.mockResolvedValueOnce({
				notifications: [notification('older', '2026-06-01T10:00:00Z')],
				nextCursor: null
			});

		const store = createNotificationsStore();
		await store.load([a]);
		expect(store.hasMore).toBe(true);

		await store.loadMore();
		expect(store.items.map((n) => n.id)).toEqual(['new', 'older']);
		expect(store.hasMore).toBe(false);
		expect(mockPage).toHaveBeenLastCalledWith(a, 'c1');

		await store.loadMore(); // nothing left: no further calls
		expect(mockPage).toHaveBeenCalledTimes(2);
	});

	it('keeps a cursor when its "show older" page fails, so retry can reach that history', async () => {
		const a = instance('ia', 'Alpha');
		mockPage
			.mockResolvedValueOnce({
				notifications: [notification('new', '2026-06-03T10:00:00Z')],
				nextCursor: 'c1'
			})
			.mockRejectedValueOnce(new FeedApiError('network', 'timeout', null))
			.mockResolvedValueOnce({
				notifications: [notification('older', '2026-06-01T10:00:00Z')],
				nextCursor: null
			});

		const store = createNotificationsStore();
		await store.load([a]);

		await store.loadMore(); // fails — the cursor must survive
		expect(store.hasMore).toBe(true);

		await store.loadMore(); // retries the SAME page
		expect(mockPage).toHaveBeenLastCalledWith(a, 'c1');
		expect(store.items.map((n) => n.id)).toEqual(['new', 'older']);
		expect(store.hasMore).toBe(false);
	});

	it('never pages while a load is in flight — and never cancels one', async () => {
		const a = instance('ia', 'Alpha');
		let releaseLoad: (() => void) | undefined;
		mockPage
			.mockResolvedValueOnce({
				notifications: [notification('first', '2026-06-02T10:00:00Z')],
				nextCursor: 'c1'
			})
			.mockImplementationOnce(async () => {
				await new Promise<void>((resolvePromise) => (releaseLoad = resolvePromise));
				return {
					notifications: [notification('reloaded', '2026-06-03T10:00:00Z')],
					nextCursor: null
				};
			});

		const store = createNotificationsStore();
		await store.load([a]);

		const reload = store.load([a]); // e.g. a retry click
		await store.loadMore(); // must refuse: a load is in flight
		expect(mockPage).toHaveBeenCalledTimes(2); // no cursor fetch happened

		releaseLoad?.();
		await reload; // ...and the load still lands
		expect(store.items.map((n) => n.id)).toEqual(['reloaded']);
		expect(store.loadState).toBe('ready');
	});

	it('resyncs after a successful mutation that superseded an in-flight load', async () => {
		const a = instance('ia', 'Alpha');
		let releaseLoad: (() => void) | undefined;
		mockPage
			.mockResolvedValueOnce({
				notifications: [notification('n1', '2026-06-01T10:00:00Z')],
				nextCursor: null
			})
			.mockImplementationOnce(async () => {
				await new Promise<void>((resolvePromise) => (releaseLoad = resolvePromise));
				return { notifications: [], nextCursor: null };
			})
			.mockResolvedValue({
				notifications: [notification('n1', '2026-06-01T10:00:00Z', true)],
				nextCursor: null
			});
		mockMarkRead.mockResolvedValue(undefined);

		const store = createNotificationsStore();
		await store.load([a]);

		const inFlight = store.load([a]); // a reload the mutation will supersede
		await store.markRead(store.items[0]);
		releaseLoad?.();
		await inFlight;

		// The superseded load's payload was discarded — but its purpose is
		// honored: the mutation triggered a fresh resync (third page call).
		await vi.waitFor(() => expect(mockPage).toHaveBeenCalledTimes(3));
		expect(store.loadState).toBe('ready');
	});

	it('discards a stale load resolving after a newer one', async () => {
		const a = instance('ia', 'Alpha');
		let releaseSlow: (() => void) | undefined;
		mockPage
			.mockImplementationOnce(async () => {
				await new Promise<void>((resolvePromise) => (releaseSlow = resolvePromise));
				return { notifications: [notification('stale', '2026-06-01T10:00:00Z')], nextCursor: null };
			})
			.mockResolvedValueOnce({
				notifications: [notification('fresh', '2026-06-02T10:00:00Z')],
				nextCursor: null
			});

		const store = createNotificationsStore();
		const slow = store.load([a]);
		await store.load([a]);
		releaseSlow?.();
		await slow;

		expect(store.items.map((n) => n.id)).toEqual(['fresh']);
	});
});
