import type { components } from '$lib/api/schema.js';
import type { Instance } from '$lib/instances/types.js';
import type { Community } from '$lib/feed/types.js';

/** The event wire shapes (KammerWeb.Api.Serializer). */
export type Event = components['schemas']['Event'];
export type EventParams = components['schemas']['EventParams'];
export type EventSlot = Event['slots'][number];
export type Author = components['schemas']['Author'];
export type Comment = components['schemas']['Comment'];

/** How an event is ordered relative to now. */
export type RsvpStatus = 'yes' | 'no' | 'maybe';

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
