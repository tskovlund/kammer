import { createApiClient } from '$lib/api/client.js';
import { ApiError, errorKind, fail, guard, type ApiErrorKind } from '$lib/api/errors.js';
import type { components } from '$lib/api/schema.js';
import type { MessageKey } from '$lib/i18n/format.js';
import type { Community } from '$lib/feed/types.js';
import { fetchAuthedObjectUrl, type Group } from '$lib/feed/api.js';
import type { Instance } from '$lib/instances/types.js';
import type { Comment, Event, EventParams, EventSeriesDetail, RsvpStatus } from './types.js';

/** A secret iCal feed token plus its ready-to-subscribe `.ics` URL. */
export type CalendarToken = components['schemas']['CalendarToken'];

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

/**
 * A recurring series' organizer view (issue #260, SPEC §6): its rule, every
 * occurrence, and the attendance matrix (members × upcoming occurrences).
 * Organizer-only — the server answers 403 for a non-manager and 404 for an
 * absent series or a group with events off; the page renders those as a
 * calm not-available state.
 */
export async function fetchEventSeries(
	instance: Instance,
	communitySlug: string,
	seriesId: string
): Promise<EventSeriesDetail> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET(
			'/api/v1/communities/{community_slug}/events/series/{series_id}',
			{ params: { path: { community_slug: communitySlug, series_id: seriesId } } }
		);
		if (error || !data) throw fail(error, response, 'Could not load this series.');
		return data.data;
	});
}

/**
 * The status the server actually recorded — `waitlisted` when a yes landed
 * beyond the event's capacity (issue #318), so callers must read the
 * outcome rather than assume the request stuck.
 */
export type RsvpOutcome = RsvpStatus | 'waitlisted';

export async function rsvp(
	instance: Instance,
	communitySlug: string,
	eventId: string,
	status: RsvpStatus
): Promise<RsvpOutcome> {
	return guard(async () => {
		const { data, error, response } = await client(instance).PUT(
			'/api/v1/communities/{community_slug}/events/{event_id}/rsvp',
			{
				params: { path: { community_slug: communitySlug, event_id: eventId } },
				body: { status }
			}
		);
		if (error || !data) throw fail(error, response, 'Could not save your RSVP.');
		return data.data.status;
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
 * Report an event comment to the moderators (issue #262). The server answers
 * a bare `{status: "reported"}` — reporting the same comment again answers
 * the same — so there is nothing to merge back into the event.
 */
export async function reportComment(
	instance: Instance,
	communitySlug: string,
	eventId: string,
	commentId: string,
	reason: string
): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(instance).POST(
			'/api/v1/communities/{community_slug}/events/{event_id}/comments/{comment_id}/report',
			{
				params: {
					path: { community_slug: communitySlug, event_id: eventId, comment_id: commentId }
				},
				body: { reason }
			}
		);
		if (error) throw fail(error, response, 'Could not send your report.');
	});
}

/**
 * A single event's ICS file as an object URL for a download link (issue
 * #307). The endpoint sits behind Bearer auth — the tokenless browser ICS
 * route 404s every members-only event, which is exactly the bug this
 * replaces a plain `<a href>` for. Same shape as the account export
 * download; the caller must `URL.revokeObjectURL` it when done.
 */
export async function fetchEventIcsUrl(
	instance: Instance,
	communitySlug: string,
	eventId: string
): Promise<string> {
	return guard(() =>
		fetchAuthedObjectUrl(
			instance,
			`/api/v1/communities/${encodeURIComponent(communitySlug)}/events/${encodeURIComponent(eventId)}/ics`
		)
	);
}

/**
 * The caller's personal iCal subscription — their merged-events feed
 * across the groups they belong to on this instance (issue #260). The
 * token is minted on first fetch and is the whole credential (SPEC §6);
 * the server returns the ready-to-subscribe `.ics` URL.
 */
export async function fetchMyCalendarToken(instance: Instance): Promise<CalendarToken> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET('/api/v1/me/calendar-token');
		if (error || !data) throw fail(error, response, 'Could not load your calendar link.');
		return data.data;
	});
}

/**
 * A group's iCal subscription URL (issue #260) — available to anyone who
 * may view the group and its events. Same minted-on-first-fetch token.
 */
export async function fetchGroupCalendarToken(
	instance: Instance,
	communitySlug: string,
	groupSlug: string
): Promise<CalendarToken> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/calendar-token',
			{ params: { path: { community_slug: communitySlug, group_slug: groupSlug } } }
		);
		if (error || !data) throw fail(error, response, 'Could not load this calendar link.');
		return data.data;
	});
}

// --- Form validation → i18n keys (#253) -------------------------------------
//
// A 422 from create/edit carries `details` (field → messages) from the
// server's changeset via `traverse_errors`, so its keys are the changeset
// field atoms — verified against `Kammer.Events.Event.changeset/2` (the
// shared create/update changeset: `title`, `ends_at`, `location_name`,
// `location_url`) and, for a recurring create, `Kammer.Events.EventSeries`
// plus the context's `until` cross-check (`Kammer.Events.create_recurring_event`
// adds "must be on or after the start date" on `until`). These map the fields
// a form control can actually make invalid onto our own copy; a `starts_at`
// (client-gated required-only), the enum `frequency` Select, or any unmapped
// field resolves to `bannerKind` for the shared `ErrorBanner`. Server message
// strings never render (the same discipline as the manage mappers).

export interface EventParamsErrors {
	titleKey: MessageKey | null;
	endsAtKey: MessageKey | null;
	locationNameKey: MessageKey | null;
	locationUrlKey: MessageKey | null;
	capacityKey: MessageKey | null;
	untilKey: MessageKey | null;
	/** Fallback banner kind; null exactly when a field-level key was set. */
	bannerKind: ApiErrorKind | null;
}

/**
 * Maps a failed event create/edit onto per-field keys. `location_url` is the
 * live #247 target (a non-http(s) link 422s), `ends_at` the end-before-start
 * cross-field check, `capacity` the positive-integer bound (issue #318), and
 * `until` the recurring-create date whose window is too narrow to yield an
 * occurrence. A lone unmapped field resolves to the banner; a 422 naming both
 * a mapped and an unmapped field shows the mapped one and suppresses the
 * banner that round — an accepted, UI-unreachable edge.
 */
export function eventParamsErrorKeys(cause: unknown): EventParamsErrors {
	if (cause instanceof ApiError && cause.kind === 'validation') {
		const titleKey = cause.details.title ? ('events.field.error.title' as const) : null;
		const endsAtKey = cause.details.ends_at ? ('events.field.error.endsAt' as const) : null;
		const locationNameKey = cause.details.location_name
			? ('events.field.error.locationName' as const)
			: null;
		const locationUrlKey = cause.details.location_url
			? ('events.field.error.locationUrl' as const)
			: null;
		const capacityKey = cause.details.capacity ? ('events.field.error.capacity' as const) : null;
		const untilKey = cause.details.until ? ('events.field.error.until' as const) : null;
		const matched =
			titleKey ?? endsAtKey ?? locationNameKey ?? locationUrlKey ?? capacityKey ?? untilKey;
		return {
			titleKey,
			endsAtKey,
			locationNameKey,
			locationUrlKey,
			capacityKey,
			untilKey,
			bannerKind: matched ? null : 'validation'
		};
	}
	return {
		titleKey: null,
		endsAtKey: null,
		locationNameKey: null,
		locationUrlKey: null,
		capacityKey: null,
		untilKey: null,
		bannerKind: errorKind(cause)
	};
}
