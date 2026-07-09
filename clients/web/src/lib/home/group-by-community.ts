import type { MergedEvent, MergedPost } from '$lib/instances/home.js';

/**
 * Community-first grouping for the merged Home (ADR 0024): users think in
 * communities, not servers, so recent activity and upcoming events are
 * bucketed by their community — identified by instance + community id, since
 * two different instances can each have a community with the same slug. The
 * provenance shown on each bucket is the community name, never the instance.
 */
export interface CommunityKey {
	/** Stable key: an item's instance and community together are unique. */
	id: string;
	instanceId: string;
	communityId: string;
	communityName: string;
	communitySlug: string;
	/** The instance's display name — used only as a disambiguating subtitle. */
	instanceName: string;
}

export interface CommunityBucket {
	key: CommunityKey;
	posts: MergedPost[];
	events: MergedEvent[];
}

function keyOf(item: MergedPost | MergedEvent): string {
	return `${item.instance.id}:${item.community.id}`;
}

function communityKey(item: MergedPost | MergedEvent): CommunityKey {
	return {
		id: keyOf(item),
		instanceId: item.instance.id,
		communityId: item.community.id,
		communityName: item.community.name,
		communitySlug: item.community.slug,
		instanceName: item.instance.instanceName
	};
}

/**
 * Bucket merged posts and events by community, preserving the input ordering
 * within each bucket (the caller has already sorted newest-first / soonest-
 * first). Buckets are ordered by their most recent activity so the liveliest
 * community leads.
 */
export function groupByCommunity(posts: MergedPost[], events: MergedEvent[]): CommunityBucket[] {
	const buckets = new Map<string, CommunityBucket>();

	const bucketFor = (item: MergedPost | MergedEvent): CommunityBucket => {
		const key = keyOf(item);
		let bucket = buckets.get(key);
		if (!bucket) {
			bucket = { key: communityKey(item), posts: [], events: [] };
			buckets.set(key, bucket);
		}
		return bucket;
	};

	for (const post of posts) bucketFor(post).posts.push(post);
	for (const event of events) bucketFor(event).events.push(event);

	// Recent chatter leads: communities with posts sort first, newest post
	// first. A future event timestamp must NOT count as "recent activity" — a
	// community whose only signal is an event three months out should never
	// outrank one with a post from a minute ago. Post-less communities fall to
	// the back, ordered by their soonest upcoming event.
	const compare = (a: CommunityBucket, b: CommunityBucket): number => {
		const aHasPosts = a.posts.length > 0;
		const bHasPosts = b.posts.length > 0;
		if (aHasPosts && bHasPosts) {
			const aPost = a.posts[0].published_at;
			const bPost = b.posts[0].published_at;
			return aPost < bPost ? 1 : aPost > bPost ? -1 : 0; // newest post first
		}
		if (aHasPosts !== bHasPosts) return aHasPosts ? -1 : 1; // any posts lead
		const aEvent = a.events[0]?.starts_at ?? '';
		const bEvent = b.events[0]?.starts_at ?? '';
		return aEvent > bEvent ? 1 : aEvent < bEvent ? -1 : 0; // soonest event first
	};

	return [...buckets.values()].sort(compare);
}

/** Distinct communities present across the merged feed, for the filter chips. */
export function communitiesInFeed(buckets: CommunityBucket[]): CommunityKey[] {
	return buckets.map((bucket) => bucket.key);
}
