import { FeedApiError } from '$lib/feed/api.js';
import type { FailedInstance, InstanceFailureKind } from '$lib/instances/home.js';
import type { Instance } from '$lib/instances/types.js';
import { fetchCommunities, fetchCommunityEvents } from './api.js';
import { groupEventsByDay, type AgendaDay } from './agenda.js';
import type { MergedEvent } from './types.js';

type LoadState = 'idle' | 'loading' | 'ready' | 'error';

/** A community present in the merged events, for the filter chips. */
export interface CommunityChip {
	/** `instanceId:communityId` — unique even when two servers share a slug. */
	id: string;
	name: string;
	instanceName: string;
}

const COMMUNITY_FETCH_TIMEOUT_MS = 10_000;

function failureKind(error: unknown): InstanceFailureKind {
	if (error instanceof FeedApiError) {
		if (error.kind === 'auth') return 'auth';
		if (error.kind === 'network') return 'network';
	}
	return 'server';
}

async function loadInstance(
	instance: Instance
): Promise<{ events: MergedEvent[]; failure: FailedInstance | null }> {
	try {
		const communities = await Promise.race([
			fetchCommunities(instance),
			new Promise<never>((_, reject) =>
				setTimeout(() => reject(new FeedApiError('network', 'timeout')), COMMUNITY_FETCH_TIMEOUT_MS)
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

		events = results
			.flatMap((result) => result.events)
			.sort((a, b) => a.starts_at.localeCompare(b.starts_at));
		failedInstances = results
			.map((result) => result.failure)
			.filter((failure): failure is FailedInstance => failure !== null);
		// Every account failing (and none succeeding) is a hard error; a
		// partial failure degrades gracefully and still shows what loaded.
		loadState =
			events.length === 0 && failedInstances.length === instances.length ? 'error' : 'ready';
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
