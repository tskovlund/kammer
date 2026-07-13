import type { components } from '$lib/api/schema.js';
import type { Instance } from '$lib/instances/types.js';
import type { Community } from '$lib/feed/types.js';

/** The event wire shapes (KammerWeb.Api.Serializer). */
export type Event = components['schemas']['Event'];
export type EventParams = components['schemas']['EventParams'];
export type EventSlot = Event['slots'][number];
export type Author = components['schemas']['Author'];
export type Comment = components['schemas']['Comment'];

/** The recurring-series organizer view: rule, occurrences, attendance matrix. */
export type EventSeriesDetail = components['schemas']['EventSeriesDetail'];
export type SeriesOccurrence = EventSeriesDetail['occurrences'][number];
export type AttendanceRow = EventSeriesDetail['attendance']['rows'][number];

/** How an event is ordered relative to now. */
export type RsvpStatus = 'yes' | 'no' | 'maybe';

/**
 * Per-field 422 copy for the event form (#253), already translated by the
 * page from `eventParamsErrorKeys`. Each is the message an `Input`'s `error`
 * prop renders, or `null` when that field is clean. Only the fields whose
 * changeset validations a form control can actually trip live here (title,
 * end time, the two location fields, and the create-only repeat-until date);
 * everything else falls to the shared banner.
 */
export interface EventFieldErrors {
	title: string | null;
	endsAt: string | null;
	locationName: string | null;
	locationUrl: string | null;
	until: string | null;
}

/**
 * An upcoming event tagged with the account and community it came from —
 * the Events tab merges these across every added instance, and provenance
 * is the community, never the server (ADR 0024). The group name rides on
 * the serialized event itself, so no extra fetch is needed to show it.
 */
export interface MergedEvent extends Event {
	instance: Instance;
	community: Community;
}
