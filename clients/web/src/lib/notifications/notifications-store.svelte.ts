import { instanceFailure } from '$lib/api/errors.js';
import type { FailedInstance } from '$lib/instances/home.js';
import type { Instance } from '$lib/instances/types.js';
import {
	fetchNotificationsPage,
	markAllRead as apiMarkAllRead,
	markRead as apiMarkRead,
	type Notification
} from './api.js';

/** A notification tagged with the account it came from. */
export type MergedNotification = Notification & { instance: Instance };

type LoadState = 'idle' | 'loading' | 'ready' | 'error';

function sameNotification(a: MergedNotification, instanceId: string, id: string): boolean {
	return a.instance.id === instanceId && a.id === id;
}

function newestFirst(a: MergedNotification, b: MergedNotification): number {
	return b.inserted_at.localeCompare(a.inserted_at);
}

/**
 * The notification center (SPEC §9, `NotificationLive.Index` parity):
 * notifications merged newest-first across every added account, with
 * unread state, optimistic mark-read on tap, mark-all-read fanned out to
 * every account, and per-instance cursor paging behind one "load more".
 * One unreachable account surfaces in `failedInstances` (with its #159
 * kind) without blanking the rest.
 *
 * Mutation failures resynchronize by reloading rather than surgically
 * reverting: a revert computed from a pre-mutation snapshot can overwrite
 * newer truth (a mark-all that landed mid-flight, a fresh page) — after
 * an error the server is the only authority worth showing.
 *
 * Deliberately not snapshot-cached (unlike home/events, issue #186): read
 * state mutates server-side, so a cached page would resurface unread
 * badges the user already cleared — the empty state is the honest
 * offline fallback here.
 */
export function createNotificationsStore() {
	let items = $state<MergedNotification[]>([]);
	let failedInstances = $state<FailedInstance[]>([]);
	let loadState = $state<LoadState>('idle');
	let loadingMore = $state(false);
	let markingAll = $state(false);
	// Per-instance continuation cursors — non-empty exactly when that
	// account has older notifications beyond what's loaded.
	let cursors = $state<Record<string, string>>({});
	// Discards a fetch that resolves after a newer load, a teardown, or a
	// mutation (whose local flips a stale response would silently undo).
	let loadGeneration = 0;
	// The accounts of the last load — what mutation-failure resyncs reload.
	let loadedInstances: Instance[] = [];

	const unreadCount = $derived(items.filter((notification) => !notification.read).length);
	const hasMore = $derived(Object.keys(cursors).length > 0);

	function setRead(instanceId: string, id: string, read: boolean): void {
		items = items.map((notification) =>
			sameNotification(notification, instanceId, id) ? { ...notification, read } : notification
		);
	}

	async function fetchInstancePage(instance: Instance, cursor?: string | null) {
		try {
			const page = await fetchNotificationsPage(instance, cursor);
			const merged = page.notifications.map((notification): MergedNotification => ({
				...notification,
				instance
			}));
			return { instance, notifications: merged, nextCursor: page.nextCursor, failure: null };
		} catch (error) {
			return {
				instance,
				notifications: [] as MergedNotification[],
				nextCursor: null,
				failure: instanceFailure(instance, error)
			};
		}
	}

	function applyCursors(
		results: { instance: Instance; nextCursor: string | null; failure: FailedInstance | null }[],
		base: Record<string, string>
	): void {
		const next = { ...base };
		for (const result of results) {
			// A failed page keeps whatever cursor it had — a timeout during
			// "show older" must not erase the way to that account's history.
			if (result.failure) continue;
			if (result.nextCursor) next[result.instance.id] = result.nextCursor;
			else delete next[result.instance.id];
		}
		cursors = next;
	}

	async function load(instances: Instance[]): Promise<void> {
		const generation = ++loadGeneration;
		loadedInstances = instances;
		loadState = 'loading';

		const results = await Promise.all(instances.map((instance) => fetchInstancePage(instance)));
		if (generation !== loadGeneration) return;

		items = results.flatMap((result) => result.notifications).sort(newestFirst);
		applyCursors(results, {});
		failedInstances = results
			.map((result) => result.failure)
			.filter((failure): failure is FailedInstance => failure !== null);
		// Every account failing (and nothing loaded) is a hard error; a
		// partial failure degrades gracefully and still shows what loaded.
		const allFailed = instances.length > 0 && failedInstances.length === instances.length;
		loadState = items.length === 0 && allFailed ? 'error' : 'ready';
	}

	/**
	 * Fetch the next page for every account that still has one. Reads the
	 * generation without bumping it: full loads and mutations supersede a
	 * pending "show older" (its append would land on replaced state), but
	 * paging must never cancel them — killing a resync would leave the
	 * very flips it was correcting on screen as truth. Paging also can't
	 * start while a load is in flight (its append would ride cursors the
	 * incoming load is about to replace).
	 *
	 * Accounts page at different rates, so one click advances each account
	 * one page and the merged timeline can transiently miss one account's
	 * items in a range another already shows — the re-sort restores true
	 * order as pages arrive; an accepted tradeoff over per-account paging
	 * UI. Per-page failures are retried by the same button (cursor kept,
	 * see applyCursors); the banner treatment stays reserved for full
	 * loads.
	 */
	async function loadMore(): Promise<void> {
		if (loadingMore || loadState === 'loading') return;
		const pending = loadedInstances.filter((instance) => cursors[instance.id]);
		if (pending.length === 0) return;

		const generation = loadGeneration;
		loadingMore = true;
		try {
			const results = await Promise.all(
				pending.map((instance) => fetchInstancePage(instance, cursors[instance.id]))
			);
			if (generation !== loadGeneration) return;

			items = [...items, ...results.flatMap((result) => result.notifications)].sort(newestFirst);
			applyCursors(results, cursors);
		} finally {
			loadingMore = false;
		}
	}

	/** Resync with the server after a failed mutation — see the store doc. */
	function resync(): void {
		void load(loadedInstances);
	}

	/**
	 * A mutation invalidates any in-flight load (its pre-mutation payload
	 * would silently undo the local flips) and adopts its loading state.
	 * Returns whether a load was actually superseded — the caller owes
	 * that load a resync once the mutation settles, even on success, or
	 * whatever it was fetching (a just-added account, a retry) never
	 * arrives.
	 */
	function supersedeInFlightLoad(): boolean {
		loadGeneration += 1;
		if (loadState !== 'loading') return false;
		loadState = 'ready';
		return true;
	}

	/** Optimistic: flip locally; on rejection reload rather than guess. */
	async function markRead(notification: MergedNotification): Promise<void> {
		if (notification.read) return;
		const superseded = supersedeInFlightLoad();
		setRead(notification.instance.id, notification.id, true);
		try {
			await apiMarkRead(notification.instance, notification.id);
			if (superseded) resync();
		} catch {
			resync();
		}
	}

	/**
	 * Fan out to EVERY loaded account, not just those with visible unread
	 * items — an account whose unread notifications are all beyond the
	 * loaded pages must still be cleared (the endpoint is idempotent).
	 */
	async function markAllRead(): Promise<void> {
		if (loadedInstances.length === 0 || markingAll) return;
		const superseded = supersedeInFlightLoad();
		markingAll = true;
		items = items.map((notification) =>
			notification.read ? notification : { ...notification, read: true }
		);
		try {
			const results = await Promise.all(
				loadedInstances.map(async (instance) => {
					try {
						await apiMarkAllRead(instance);
						return true;
					} catch {
						return false;
					}
				})
			);
			if (superseded || results.some((succeeded) => !succeeded)) resync();
		} finally {
			markingAll = false;
		}
	}

	return {
		get items() {
			return items;
		},
		get unreadCount() {
			return unreadCount;
		},
		get failedInstances() {
			return failedInstances;
		},
		get loadState() {
			return loadState;
		},
		get isEmpty() {
			return items.length === 0;
		},
		get hasMore() {
			return hasMore;
		},
		get loadingMore() {
			return loadingMore;
		},
		get markingAll() {
			return markingAll;
		},
		load,
		loadMore,
		markRead,
		markAllRead,
		stop() {
			loadGeneration += 1;
		}
	};
}

export type NotificationsStore = ReturnType<typeof createNotificationsStore>;
