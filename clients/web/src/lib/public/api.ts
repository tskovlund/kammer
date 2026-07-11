import { createApiClient } from '$lib/api/client.js';
import type { components } from '$lib/api/schema.js';
import type { Community, Post } from '$lib/feed/types.js';
import type { Event } from '$lib/events/types.js';

export type Group = components['schemas']['Group'];
export type RsvpStatus = 'yes' | 'no' | 'maybe';

export interface PublicCommunity {
	community: Community;
	groups: Group[];
}

export interface PublicFeedPage {
	posts: Post[];
	nextCursor: string | null;
}

export interface GuestIdentity {
	email: string;
	displayName: string;
}

/**
 * How a tokenless public-browse call failed (issue #185 slice B, the
 * client twin of `KammerWeb.Api.PublicController`/`GuestController`).
 * These reads and guest request POSTs never carry a device token — a
 * public community/group/event/post that exists but isn't publicly
 * readable answers the same neutral 404 a nonexistent one gets (no
 * oracle, issue #156/#161), so there is no `auth`/`forbidden` kind
 * here either, mirroring `$lib/guest/api.ts`.
 */
export type PublicErrorKind = 'not_found' | 'validation' | 'rate_limited' | 'network' | 'server';

export class PublicApiError extends Error {
	readonly kind: PublicErrorKind;
	readonly status: number | null;

	constructor(kind: PublicErrorKind, message: string, status: number | null = null) {
		super(message);
		this.name = 'PublicApiError';
		this.kind = kind;
		this.status = status;
	}
}

function kindForStatus(status: number): PublicErrorKind {
	switch (status) {
		case 404:
			return 'not_found';
		case 400:
		case 422:
			return 'validation';
		case 429:
			return 'rate_limited';
		default:
			return 'server';
	}
}

interface ErrorEnvelope {
	error?: { code?: string; message?: string };
}

// The server message ends up on `PublicApiError.message` for debugging
// only. Public-surface UI must never render `.message` — branch on
// `.kind` and show static i18n copy instead, or a server string could
// distinguish states (e.g. an email already known) the neutral API
// deliberately hides.
function messageFrom(error: unknown, fallback: string): string {
	const envelope = error as ErrorEnvelope | undefined;
	return envelope?.error?.message ?? fallback;
}

function fail(error: unknown, response: Response | undefined, fallback: string): PublicApiError {
	const status = response?.status ?? null;
	const kind = status ? kindForStatus(status) : 'server';
	return new PublicApiError(kind, messageFrom(error, fallback), status);
}

async function guard<T>(request: () => Promise<T>): Promise<T> {
	try {
		return await request();
	} catch (cause) {
		if (cause instanceof PublicApiError) throw cause;
		throw new PublicApiError('network', 'Could not reach this community.', null);
	}
}

function client(baseUrl: string) {
	return createApiClient(baseUrl);
}

/**
 * The instance's community directory (issue #260): communities that
 * opted into the anonymous landing page via `listed_on_instance`
 * (SPEC §3, default off) — what the signed-out `InstanceLive.Home`
 * listed. Unlisted communities never appear here, though each stays
 * reachable by slug via `fetchPublicCommunity`.
 */
export async function fetchPublicCommunities(baseUrl: string): Promise<Community[]> {
	return guard(async () => {
		const { data, error, response } = await client(baseUrl).GET('/api/v1/public/communities');
		if (error || !data) throw fail(error, response, 'Could not load the community directory.');
		return data.data;
	});
}

export async function fetchPublicCommunity(
	baseUrl: string,
	communitySlug: string
): Promise<PublicCommunity> {
	return guard(async () => {
		const { data, error, response } = await client(baseUrl).GET(
			'/api/v1/public/communities/{community_slug}',
			{ params: { path: { community_slug: communitySlug } } }
		);
		if (error || !data) throw fail(error, response, 'This community could not be found.');
		return data.data;
	});
}

export async function fetchPublicGroup(
	baseUrl: string,
	communitySlug: string,
	groupSlug: string
): Promise<Group> {
	return guard(async () => {
		const { data, error, response } = await client(baseUrl).GET(
			'/api/v1/public/communities/{community_slug}/groups/{group_slug}',
			{ params: { path: { community_slug: communitySlug, group_slug: groupSlug } } }
		);
		if (error || !data) throw fail(error, response, 'This group could not be found.');
		return data.data;
	});
}

export async function fetchPublicGroupPosts(
	baseUrl: string,
	communitySlug: string,
	groupSlug: string,
	cursor?: string | null
): Promise<PublicFeedPage> {
	return guard(async () => {
		const { data, error, response } = await client(baseUrl).GET(
			'/api/v1/public/communities/{community_slug}/groups/{group_slug}/posts',
			{
				params: {
					path: { community_slug: communitySlug, group_slug: groupSlug },
					query: cursor ? { after: cursor } : undefined
				}
			}
		);
		if (error || !data) throw fail(error, response, 'Could not load this feed.');
		return { posts: data.data, nextCursor: data.next_cursor ?? null };
	});
}

export async function fetchPublicPost(
	baseUrl: string,
	communitySlug: string,
	groupSlug: string,
	postId: string
): Promise<Post> {
	return guard(async () => {
		const { data, error, response } = await client(baseUrl).GET(
			'/api/v1/public/communities/{community_slug}/groups/{group_slug}/posts/{post_id}',
			{
				params: {
					path: { community_slug: communitySlug, group_slug: groupSlug, post_id: postId }
				}
			}
		);
		if (error || !data) throw fail(error, response, 'This post could not be found.');
		return data.data;
	});
}

export async function fetchPublicEvent(
	baseUrl: string,
	communitySlug: string,
	eventId: string
): Promise<Event> {
	return guard(async () => {
		const { data, error, response } = await client(baseUrl).GET(
			'/api/v1/public/communities/{community_slug}/events/{event_id}',
			{ params: { path: { community_slug: communitySlug, event_id: eventId } } }
		);
		if (error || !data) throw fail(error, response, 'This event could not be found.');
		return data.data;
	});
}

// Guest request POSTs (SPEC §3/§6): each emails a confirm link and answers
// 202 with no body worth reading — the caller only needs to know it didn't
// throw, so every request function below resolves to void. Neutral by
// design (rate-limited, no oracle on whether the email is already known),
// same as `$lib/guest/api.ts`'s confirm functions.

export async function requestGuestRsvp(
	baseUrl: string,
	communitySlug: string,
	eventId: string,
	identity: GuestIdentity,
	status: RsvpStatus
): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(baseUrl).POST(
			'/api/v1/communities/{community_slug}/events/{event_id}/guest-rsvp',
			{
				params: { path: { community_slug: communitySlug, event_id: eventId } },
				body: { email: identity.email, display_name: identity.displayName, status }
			}
		);
		if (error) throw fail(error, response, 'Could not send your RSVP.');
	});
}

export async function requestGuestClaim(
	baseUrl: string,
	communitySlug: string,
	eventId: string,
	slotId: string,
	identity: GuestIdentity
): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(baseUrl).POST(
			'/api/v1/communities/{community_slug}/events/{event_id}/slots/{slot_id}/guest-claim',
			{
				params: { path: { community_slug: communitySlug, event_id: eventId, slot_id: slotId } },
				body: { email: identity.email, display_name: identity.displayName }
			}
		);
		if (error) throw fail(error, response, 'Could not send your signup.');
	});
}

export async function requestGuestComment(
	baseUrl: string,
	communitySlug: string,
	groupSlug: string,
	postId: string,
	identity: GuestIdentity,
	bodyMarkdown: string
): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(baseUrl).POST(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/posts/{post_id}/guest-comment',
			{
				params: {
					path: { community_slug: communitySlug, group_slug: groupSlug, post_id: postId }
				},
				body: {
					email: identity.email,
					display_name: identity.displayName,
					body_markdown: bodyMarkdown
				}
			}
		);
		if (error) throw fail(error, response, 'Could not send your comment.');
	});
}
