import { createApiClient } from '$lib/api/client.js';
import { FeedApiError, type FeedErrorKind } from '$lib/feed/api.js';
import type { Community } from '$lib/feed/types.js';
import type { Group } from '$lib/feed/api.js';
import type { Instance } from '$lib/instances/types.js';
import type { Comment, Event, EventParams, RsvpStatus } from './types.js';

function kindForStatus(status: number): FeedErrorKind {
	switch (status) {
		case 401:
			return 'auth';
		case 403:
			return 'forbidden';
		case 404:
			return 'not_found';
		case 413:
			return 'too_large';
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

function fail(error: unknown, response: Response | undefined, fallback: string): FeedApiError {
	const status = response?.status ?? null;
	const kind = status ? kindForStatus(status) : 'server';
	const message = (error as ErrorEnvelope | undefined)?.error?.message ?? fallback;
	return new FeedApiError(kind, message, status);
}

async function guard<T>(request: () => Promise<T>): Promise<T> {
	try {
		return await request();
	} catch (cause) {
		if (cause instanceof FeedApiError) throw cause;
		throw new FeedApiError('network', 'Could not reach this community.', null);
	}
}

function client(instance: Instance) {
	return createApiClient(instance.baseUrl, instance.deviceToken);
}

export async function fetchCommunities(instance: Instance): Promise<Community[]> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET('/api/v1/communities');
		if (error || !data) throw fail(error, response, 'Could not load communities.');
		return data.data;
	});
}

export async function fetchGroups(instance: Instance, communitySlug: string): Promise<Group[]> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET(
			'/api/v1/communities/{community_slug}/groups',
			{ params: { path: { community_slug: communitySlug } } }
		);
		if (error || !data) throw fail(error, response, 'Could not load groups.');
		return data.data;
	});
}

export async function fetchCommunityEvents(
	instance: Instance,
	communitySlug: string
): Promise<Event[]> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET(
			'/api/v1/communities/{community_slug}/events',
			{ params: { path: { community_slug: communitySlug } } }
		);
		if (error || !data) throw fail(error, response, 'Could not load events.');
		return data.data;
	});
}

export async function fetchEvent(
	instance: Instance,
	communitySlug: string,
	eventId: string
): Promise<Event> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET(
			'/api/v1/communities/{community_slug}/events/{event_id}',
			{ params: { path: { community_slug: communitySlug, event_id: eventId } } }
		);
		if (error || !data) throw fail(error, response, 'Could not load this event.');
		return data.data;
	});
}

export async function rsvp(
	instance: Instance,
	communitySlug: string,
	eventId: string,
	status: RsvpStatus
): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(instance).PUT(
			'/api/v1/communities/{community_slug}/events/{event_id}/rsvp',
			{
				params: { path: { community_slug: communitySlug, event_id: eventId } },
				body: { status }
			}
		);
		if (error) throw fail(error, response, 'Could not save your RSVP.');
	});
}

export async function createEvent(
	instance: Instance,
	communitySlug: string,
	groupSlug: string,
	params: EventParams
): Promise<Event> {
	return guard(async () => {
		const { data, error, response } = await client(instance).POST(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/events',
			{
				params: { path: { community_slug: communitySlug, group_slug: groupSlug } },
				body: params
			}
		);
		if (error || !data) throw fail(error, response, 'Could not create this event.');
		return data.data;
	});
}

export async function editEvent(
	instance: Instance,
	communitySlug: string,
	eventId: string,
	params: EventParams
): Promise<Event> {
	return guard(async () => {
		const { data, error, response } = await client(instance).PUT(
			'/api/v1/communities/{community_slug}/events/{event_id}',
			{
				params: { path: { community_slug: communitySlug, event_id: eventId } },
				body: params
			}
		);
		if (error || !data) throw fail(error, response, 'Could not save your changes.');
		return data.data;
	});
}

export async function deleteEvent(
	instance: Instance,
	communitySlug: string,
	eventId: string
): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(instance).DELETE(
			'/api/v1/communities/{community_slug}/events/{event_id}',
			{ params: { path: { community_slug: communitySlug, event_id: eventId } } }
		);
		if (error) throw fail(error, response, 'Could not delete this event.');
	});
}

export async function setCancelled(
	instance: Instance,
	communitySlug: string,
	eventId: string,
	cancelled: boolean
): Promise<Event> {
	return guard(async () => {
		const path = { community_slug: communitySlug, event_id: eventId };
		const url = '/api/v1/communities/{community_slug}/events/{event_id}/cancellation';
		const { data, error, response } = cancelled
			? await client(instance).PUT(url, { params: { path } })
			: await client(instance).DELETE(url, { params: { path } });
		if (error || !data) throw fail(error, response, 'Could not update this occurrence.');
		return data.data;
	});
}

export async function createSlot(
	instance: Instance,
	communitySlug: string,
	eventId: string,
	input: { title: string; capacity: number }
): Promise<Event> {
	return guard(async () => {
		const { data, error, response } = await client(instance).POST(
			'/api/v1/communities/{community_slug}/events/{event_id}/slots',
			{ params: { path: { community_slug: communitySlug, event_id: eventId } }, body: input }
		);
		if (error || !data) throw fail(error, response, 'Could not add the slot.');
		return data.data;
	});
}

export async function deleteSlot(
	instance: Instance,
	communitySlug: string,
	eventId: string,
	slotId: string
): Promise<Event> {
	return guard(async () => {
		const { data, error, response } = await client(instance).DELETE(
			'/api/v1/communities/{community_slug}/events/{event_id}/slots/{slot_id}',
			{
				params: {
					path: { community_slug: communitySlug, event_id: eventId, slot_id: slotId }
				}
			}
		);
		if (error || !data) throw fail(error, response, 'Could not delete the slot.');
		return data.data;
	});
}

export async function setSlotClaim(
	instance: Instance,
	communitySlug: string,
	eventId: string,
	slotId: string,
	claimed: boolean
): Promise<Event> {
	return guard(async () => {
		const path = { community_slug: communitySlug, event_id: eventId, slot_id: slotId };
		const url = '/api/v1/communities/{community_slug}/events/{event_id}/slots/{slot_id}/claim';
		const { data, error, response } = claimed
			? await client(instance).PUT(url, { params: { path } })
			: await client(instance).DELETE(url, { params: { path } });
		if (error || !data) throw fail(error, response, 'Could not update your signup.');
		return data.data;
	});
}

export async function createComment(
	instance: Instance,
	communitySlug: string,
	eventId: string,
	input: { body_markdown: string; parent_comment_id?: string | null }
): Promise<Comment> {
	return guard(async () => {
		const { data, error, response } = await client(instance).POST(
			'/api/v1/communities/{community_slug}/events/{event_id}/comments',
			{ params: { path: { community_slug: communitySlug, event_id: eventId } }, body: input }
		);
		if (error || !data) throw fail(error, response, 'Could not post your comment.');
		return data.data;
	});
}

export async function editComment(
	instance: Instance,
	communitySlug: string,
	eventId: string,
	commentId: string,
	bodyMarkdown: string
): Promise<Comment> {
	return guard(async () => {
		const { data, error, response } = await client(instance).PUT(
			'/api/v1/communities/{community_slug}/events/{event_id}/comments/{comment_id}',
			{
				params: {
					path: { community_slug: communitySlug, event_id: eventId, comment_id: commentId }
				},
				body: { body_markdown: bodyMarkdown }
			}
		);
		if (error || !data) throw fail(error, response, 'Could not save your edit.');
		return data.data;
	});
}

export async function deleteComment(
	instance: Instance,
	communitySlug: string,
	eventId: string,
	commentId: string
): Promise<Comment> {
	return guard(async () => {
		const { data, error, response } = await client(instance).DELETE(
			'/api/v1/communities/{community_slug}/events/{event_id}/comments/{comment_id}',
			{
				params: {
					path: { community_slug: communitySlug, event_id: eventId, comment_id: commentId }
				}
			}
		);
		if (error || !data) throw fail(error, response, 'Could not delete this comment.');
		return data.data;
	});
}

export async function reactComment(
	instance: Instance,
	communitySlug: string,
	eventId: string,
	commentId: string,
	emoji: string
): Promise<Comment> {
	return guard(async () => {
		const { data, error, response } = await client(instance).POST(
			'/api/v1/communities/{community_slug}/events/{event_id}/comments/{comment_id}/reactions',
			{
				params: {
					path: { community_slug: communitySlug, event_id: eventId, comment_id: commentId }
				},
				body: { emoji }
			}
		);
		if (error || !data) throw fail(error, response, 'Could not react.');
		return data.data;
	});
}

/**
 * The server serves an ICS file for a single event at a plain browser route
 * (no Bearer auth — a calendar app fetches it directly). We just link to it.
 */
export function icsUrl(instance: Instance, communitySlug: string, eventId: string): string {
	const base = instance.baseUrl.replace(/\/$/, '');
	return `${base}/c/${encodeURIComponent(communitySlug)}/events/${encodeURIComponent(eventId)}/ics`;
}
