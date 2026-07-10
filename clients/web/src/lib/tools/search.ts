import type { Group } from '$lib/feed/api.js';
import type { Community } from '$lib/feed/types.js';
import type { Instance } from '$lib/instances/types.js';
import type { SearchResults } from './api.js';

/**
 * One community's slice of a global search (SPEC §10). Results are presented
 * community-first — users think in communities, not servers — so a bucket
 * carries its community and instance provenance and a `group_id → slug` map,
 * which is what lets a post hit deep-link back to the group it lives in
 * (posts and events carry only a group id on the wire).
 */
export interface SearchBucket {
	/** `instanceId:communityId` — unique even when two servers share a slug. */
	id: string;
	instance: Instance;
	community: Community;
	results: SearchResults;
	groupSlugById: Record<string, string>;
	hitCount: number;
}

/** Total hits across every section — drives ordering and empty detection. */
export function hitCount(results: SearchResults): number {
	return (
		results.posts.length + results.comments.length + results.events.length + results.files.length
	);
}

/** A slug lookup so a post/event hit (group id only) can link to its group. */
export function groupSlugMap(groups: Group[]): Record<string, string> {
	const map: Record<string, string> = {};
	for (const group of groups) map[group.id] = group.slug;
	return map;
}

/** One community's raw search outcome, before empty buckets are dropped. */
export interface CommunitySearch {
	instance: Instance;
	community: Community;
	results: SearchResults;
	groups: Group[];
}

/**
 * Build the display buckets: drop communities with no hits, and order the
 * rest by hit count (busiest community leads), breaking ties by name so the
 * order is stable across searches.
 */
export function buildBuckets(searches: CommunitySearch[]): SearchBucket[] {
	return searches
		.map((search): SearchBucket => {
			return {
				id: `${search.instance.id}:${search.community.id}`,
				instance: search.instance,
				community: search.community,
				results: search.results,
				groupSlugById: groupSlugMap(search.groups),
				hitCount: hitCount(search.results)
			};
		})
		.filter((bucket) => bucket.hitCount > 0)
		.sort((a, b) => b.hitCount - a.hitCount || a.community.name.localeCompare(b.community.name));
}
