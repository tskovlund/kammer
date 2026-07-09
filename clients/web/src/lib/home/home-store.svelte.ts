import {
	fetchMergedHome,
	type FailedInstance,
	type MergedEvent,
	type MergedPost
} from '$lib/instances/home.js';
import type { Instance } from '$lib/instances/types.js';
import { getSocket } from '$lib/realtime/registry.svelte.js';
import { groupByCommunity } from './group-by-community.js';

type LoadState = 'idle' | 'loading' | 'ready' | 'error';

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
		recentActivity = merged.recentActivity;
		upcomingEvents = merged.upcomingEvents;
		failedInstances = merged.failedInstances;
		loadState = 'ready';
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
		setFilter(communityKeyId: string | null) {
			activeFilter = communityKeyId;
		},
		load,
		stop: stopLive
	};
}

export type HomeStore = ReturnType<typeof createHomeStore>;
