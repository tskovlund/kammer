import { fetchCommunities, fetchGroups } from '$lib/events/api.js';
import { FeedApiError } from '$lib/feed/api.js';
import type { FailedInstance, InstanceFailureKind } from '$lib/instances/home.js';
import type { Instance } from '$lib/instances/types.js';
import { search as searchCommunity, ToolsApiError } from './api.js';
import { buildBuckets, type CommunitySearch, type SearchBucket } from './search.js';

type LoadState = 'idle' | 'loading' | 'ready' | 'error';

function failureKind(error: unknown): InstanceFailureKind {
	if (error instanceof FeedApiError || error instanceof ToolsApiError) {
		if (error.kind === 'auth') return 'auth';
		if (error.kind === 'network') return 'network';
	}
	return 'server';
}

async function searchInstance(
	instance: Instance,
	query: string
): Promise<{ searches: CommunitySearch[]; failure: FailedInstance | null }> {
	try {
		const communities = await fetchCommunities(instance);
		const searches = await Promise.all(
			communities.map(async (community): Promise<CommunitySearch> => {
				// The group list resolves a hit's group id back to a slug for
				// deep links; searching and listing run in parallel.
				const [results, groups] = await Promise.all([
					searchCommunity(instance, community.slug, query),
					fetchGroups(instance, community.slug)
				]);
				return { instance, community, results, groups };
			})
		);
		return { searches, failure: null };
	} catch (error) {
		return { searches: [], failure: { instance, kind: failureKind(error) } };
	}
}

/**
 * Global search across every added account (SPEC §10), kept community-first
 * (ADR 0024). A query fans out over each instance's communities in parallel;
 * one unreachable account surfaces in `failedInstances` (with its #159 kind)
 * without blanking the rest. A blank query holds the idle state — no fanout,
 * no empty round-trips. Results already come narrowed to what the viewer may
 * see (the server's central authorization module, SPEC §10).
 */
export function createSearchStore() {
	let buckets = $state<SearchBucket[]>([]);
	let failedInstances = $state<FailedInstance[]>([]);
	let loadState = $state<LoadState>('idle');
	let query = $state('');
	// Discards a search that resolves after a newer one (or after teardown),
	// so stale results never overwrite fresh ones — the classic race when a
	// user keeps typing.
	let loadGeneration = 0;

	async function run(instances: Instance[], nextQuery: string): Promise<void> {
		query = nextQuery;
		const trimmed = nextQuery.trim();
		if (trimmed === '') {
			loadGeneration += 1;
			buckets = [];
			failedInstances = [];
			loadState = 'idle';
			return;
		}

		const generation = ++loadGeneration;
		loadState = 'loading';

		const results = await Promise.all(
			instances.map((instance) => searchInstance(instance, trimmed))
		);
		if (generation !== loadGeneration) return;

		buckets = buildBuckets(results.flatMap((result) => result.searches));
		failedInstances = results
			.map((result) => result.failure)
			.filter((failure): failure is FailedInstance => failure !== null);
		// Every account failing (and none succeeding) is a hard error; a partial
		// failure degrades gracefully and still shows what matched.
		loadState =
			buckets.length === 0 && failedInstances.length === instances.length ? 'error' : 'ready';
	}

	return {
		get buckets() {
			return buckets;
		},
		get failedInstances() {
			return failedInstances;
		},
		get loadState() {
			return loadState;
		},
		get query() {
			return query;
		},
		get isEmpty() {
			return buckets.length === 0;
		},
		run,
		stop() {
			loadGeneration += 1;
		}
	};
}

export type SearchStore = ReturnType<typeof createSearchStore>;
