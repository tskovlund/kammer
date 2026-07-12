import { failureKind } from '$lib/api/errors.js';
import { ApiError } from '$lib/feed/api.js';
import type { FailedInstance } from '$lib/instances/home.js';
import type { Instance } from '$lib/instances/types.js';
import { loadSnapshot, saveSnapshot } from '$lib/offline/snapshot-cache.js';
import { fetchCommunities, fetchCommunityEvents } from './api.js';
import { groupEventsByDay, type AgendaDay } from './agenda.js';
import type { MergedEvent } from './types.js';

type LoadState = 'idle' | 'loading' | 'ready' | 'error';

const SNAPSHOT_KEY = 'events';

/** A community present in the merged events, for the filter chips. */
export interface CommunityChip {
	/** `instanceId:communityId` — unique even when two servers share a slug. */
	id: string;
	name: string;
	instanceName: string;
}

const COMMUNITY_FETCH_TIMEOUT_MS = 10_000;

async function loadInstance(
	instance: Instance
): Promise<{ events: MergedEvent[]; failure: FailedInstance | null }> {
	try {
		const communities = await Promise.race([
			fetchCommunities(instance),
			new Promise<never>((_, reject) =>
				setTimeout(() => reject(new ApiError('network', 'timeout')), COMMUNITY_FETCH_TIMEOUT_MS)
			)
		]);

		const perCommunity = await Promise.all(
			communities.map(async (community) => {
				const events = await fetchCommunityEvents(instance, community.slug);
				return events.map((event): MergedEvent => ({ ...event, instance, community }));
			})
		);

		return { events: perCommunity.flat(), failure: null };
	} catch (error) {
		return { events: [], failure: { instance, kind: failureKind(error) } };
	}
}

/**
 * The Events tab: upcoming events merged across every added account, kept
 * community-first (ADR 0024). It fetches each instance's communities and
 * their upcoming events in parallel; one unreachable account surfaces in
 * `failedInstances` (with its #159 kind) without blanking the rest. The
 * merged list is presented as a soonest-first agenda, filterable to a
 * single community.
 *
 * Events have no realtime channel server-side, so this is a load-on-mount
 * view with an explicit retry — there is nothing live to subscribe to.
 */
export function createEventsStore() {
	let events = $state<MergedEvent[]>([]);
	let failedInstances = $state<FailedInstance[]>([]);
	let loadState = $state<LoadState>('idle');
	let activeFilter = $state<string | null>(null);
	// Non-null exactly when `events` is last-known-good cached data rather
	// than a fresh fetch (issue #186) — drives the stale/offline banner.
	let snapshotSavedAt = $state<string | null>(null);
	// Discards a fetch that resolves after a newer load (or after teardown),
	// so stale data never overwrites fresh data.
	let loadGeneration = 0;

	const chips = $derived.by((): CommunityChip[] => {
		const seen: Record<string, boolean> = {};
		const result: CommunityChip[] = [];
		// `events` is soonest-first, so first sighting of a community is its
		// soonest event — chips keep that order.
		for (const event of events) {
			const id = `${event.instance.id}:${event.community.id}`;
			if (!seen[id]) {
				seen[id] = true;
				result.push({
					id,
					name: event.community.name,
					instanceName: event.instance.instanceName
				});
			}
		}
		return result;
	});

	const filtered = $derived(
		activeFilter
			? events.filter((event) => `${event.instance.id}:${event.community.id}` === activeFilter)
			: events
	);

	const days = $derived<AgendaDay[]>(groupEventsByDay(filtered));

	async function load(instances: Instance[]): Promise<void> {
		const generation = ++loadGeneration;
		loadState = 'loading';

		const results = await Promise.all(instances.map(loadInstance));
		if (generation !== loadGeneration) return;

		const loadedEvents = results
			.flatMap((result) => result.events)
			.sort((a, b) => a.starts_at.localeCompare(b.starts_at));
		const loadedFailures = results
			.map((result) => result.failure)
			.filter((failure): failure is FailedInstance => failure !== null);
		const allFailed = instances.length > 0 && loadedFailures.length === instances.length;
		// Network failures only, matching feed-store's gate — auth/server
		// failures are real state to surface, not an occasion for a snapshot.
		const allOffline = allFailed && loadedFailures.every((failed) => failed.kind === 'network');

		if (allOffline) {
			const cached = loadSnapshot<MergedEvent[]>(SNAPSHOT_KEY);
			if (cached) {
				events = cached.data;
				failedInstances = loadedFailures;
				snapshotSavedAt = cached.savedAt;
				loadState = 'ready';
				return;
			}
		}

		events = loadedEvents;
		failedInstances = loadedFailures;
		snapshotSavedAt = null;
		// Every account failing (and none succeeding), with nothing cached to
		// fall back to either, is a hard error; a partial failure degrades
		// gracefully and still shows what loaded.
		loadState = events.length === 0 && allFailed ? 'error' : 'ready';
		if (!allFailed) saveSnapshot(SNAPSHOT_KEY, events);
	}

	return {
		get days() {
			return days;
		},
		get chips() {
			return chips;
		},
		get failedInstances() {
			return failedInstances;
		},
		/** Non-null when the current events are cached data, not a fresh fetch — see `StaleBanner`. */
		get snapshotSavedAt() {
			return snapshotSavedAt;
		},
		get loadState() {
			return loadState;
		},
		get activeFilter() {
			return activeFilter;
		},
		get isEmpty() {
			return events.length === 0;
		},
		setFilter(id: string | null) {
			activeFilter = id;
		},
		load,
		stop() {
			loadGeneration += 1;
		}
	};
}

export type EventsStore = ReturnType<typeof createEventsStore>;
