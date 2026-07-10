import {
	fetchMergedHome,
	type FailedInstance,
	type MergedEvent,
	type MergedPost
} from '$lib/instances/home.js';
import type { Instance } from '$lib/instances/types.js';
import { loadSnapshot, saveSnapshot } from '$lib/offline/snapshot-cache.js';
import { getSocket } from '$lib/realtime/registry.svelte.js';
import { groupByCommunity } from './group-by-community.js';

type LoadState = 'idle' | 'loading' | 'ready' | 'error';

const SNAPSHOT_KEY = 'home';

interface HomeSnapshot {
	recentActivity: MergedPost[];
	upcomingEvents: MergedEvent[];
}

/**
 * The merged Home across every added instance/account (ADR 0001, community-
 * first per ADR 0024). It fetches each instance's `/home` in parallel
 * (`fetchMergedHome`), buckets the result by community, and keeps the buckets
 * live: for each group already present it joins that instance's feed channel
 * and folds new/updated/deleted posts back into recent activity, tagged with
 * the same instance/community/group provenance the REST payload carried.
 *
 * One unreachable instance surfaces in `failedInstances` (with its #159 kind)
 * without blanking the rest — the merged view degrades, it doesn't fail.
 */
export function createHomeStore() {
	let recentActivity = $state<MergedPost[]>([]);
	let upcomingEvents = $state<MergedEvent[]>([]);
	let failedInstances = $state<FailedInstance[]>([]);
	let loadState = $state<LoadState>('idle');
	let activeFilter = $state<string | null>(null);
	// Non-null exactly when the buckets above are last-known-good data from
	// the snapshot cache rather than a fresh fetch (issue #186) — drives
	// the stale/offline banner. Cleared the moment a fetch succeeds.
	let snapshotSavedAt = $state<string | null>(null);
	const liveStops: (() => void)[] = [];
	// Sequences overlapping loads: a fetch that resolves after a newer load (or
	// after the store was stopped/unmounted) is discarded, so stale data never
	// overwrites fresh data and no channels are wired after teardown.
	let loadGeneration = 0;

	const buckets = $derived(groupByCommunity(recentActivity, upcomingEvents));
	const visibleBuckets = $derived(
		activeFilter ? buckets.filter((bucket) => bucket.key.id === activeFilter) : buckets
	);

	function upsertPost(incoming: MergedPost): void {
		const index = recentActivity.findIndex((post) => post.id === incoming.id);
		if (index === -1) recentActivity = [incoming, ...recentActivity];
		else recentActivity = recentActivity.map((post) => (post.id === incoming.id ? incoming : post));
	}

	function stopLive(): void {
		// Invalidate any in-flight load so a late `fetchMergedHome` resolving
		// after unmount can't wire channels that would then leak.
		loadGeneration += 1;
		while (liveStops.length) liveStops.pop()?.();
	}

	function wireLive(instances: Instance[]): void {
		stopLive();
		const byId: Record<string, Instance> = {};
		for (const instance of instances) byId[instance.id] = instance;

		// One feed subscription per (instance, group) already surfaced on Home.
		const seen: Record<string, true> = {};
		for (const post of recentActivity) {
			const key = `${post.instance.id}:${post.group.id}`;
			if (seen[key]) continue;
			seen[key] = true;
			const instance = byId[post.instance.id];
			if (!instance) continue;

			// Provenance to re-attach to live payloads (the channel sends a bare
			// Post; Home needs its community/group/instance labels).
			const provenance = { instance: post.instance, community: post.community, group: post.group };
			liveStops.push(
				getSocket(instance).subscribeFeed(post.group.id, {
					onPostCreated: (bare) => upsertPost({ ...bare, ...provenance }),
					onPostUpdated: (bare) => upsertPost({ ...bare, ...provenance }),
					onPostDeleted: (postId) => {
						recentActivity = recentActivity.filter((candidate) => candidate.id !== postId);
					}
				})
			);
		}
	}

	async function load(instances: Instance[]): Promise<void> {
		const generation = ++loadGeneration;
		loadState = 'loading';
		const merged = await fetchMergedHome(instances);
		// A newer load started, or the store was stopped, while this was in
		// flight — discard this result rather than clobber fresher state.
		if (generation !== loadGeneration) return;

		// Every account UNREACHABLE — network failures only, matching
		// feed-store's gate — is exactly when last-known-good data is worth
		// falling back to (issue #186). Auth/server failures are real state
		// the user must see, not an occasion to paper over with a snapshot;
		// a partial failure already degrades gracefully without one.
		const allFailed = instances.length > 0 && merged.failedInstances.length === instances.length;
		const allOffline =
			allFailed && merged.failedInstances.every((failed) => failed.kind === 'network');
		if (allOffline) {
			const cached = loadSnapshot<HomeSnapshot>(SNAPSHOT_KEY);
			if (cached) {
				recentActivity = cached.data.recentActivity;
				upcomingEvents = cached.data.upcomingEvents;
				failedInstances = merged.failedInstances;
				snapshotSavedAt = cached.savedAt;
				loadState = 'ready';
				return;
			}
		}

		recentActivity = merged.recentActivity;
		upcomingEvents = merged.upcomingEvents;
		failedInstances = merged.failedInstances;
		snapshotSavedAt = null;
		loadState = 'ready';
		// Never snapshot an all-failed (hence empty) result — a later
		// offline load would then render an empty page under a stale
		// banner as if that had ever been real data.
		if (!allFailed) saveSnapshot(SNAPSHOT_KEY, { recentActivity, upcomingEvents });
		wireLive(instances);
	}

	return {
		get buckets() {
			return visibleBuckets;
		},
		get allBuckets() {
			return buckets;
		},
		get failedInstances() {
			return failedInstances;
		},
		get loadState() {
			return loadState;
		},
		get activeFilter() {
			return activeFilter;
		},
		get isEmpty() {
			return recentActivity.length === 0 && upcomingEvents.length === 0;
		},
		/** Non-null when the current buckets are cached data, not a fresh fetch — see `StaleBanner`. */
		get snapshotSavedAt() {
			return snapshotSavedAt;
		},
		setFilter(communityKeyId: string | null) {
			activeFilter = communityKeyId;
		},
		load,
		stop: stopLive
	};
}

export type HomeStore = ReturnType<typeof createHomeStore>;
