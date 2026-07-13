import { ApiError, type ApiErrorKind } from '$lib/feed/api.js';
import type { Instance } from '$lib/instances/types.js';
import * as api from './api.js';
import { applyRsvp, upsertComment } from './event-logic.js';
import type { Event, RsvpStatus } from './types.js';

type LoadState = 'idle' | 'loading' | 'ready' | 'error';

/**
 * A single event's live-in-memory state (no realtime channel exists for
 * events, so "live" here means every write returns the fresh server truth
 * and we fold it back in). RSVP is optimistic with rollback; slot and
 * comment writes take the authoritative event/comment the API returns.
 * Every write funnels failures into `actionError` for a dismissible toast.
 */
export function createEventStore(instance: Instance, communitySlug: string, eventId: string) {
	let event = $state<Event | null>(null);
	let loadState = $state<LoadState>('idle');
	let loadErrorKind = $state<ApiErrorKind | null>(null);
	let actionError = $state<ApiErrorKind | null>(null);

	function report(error: unknown): void {
		actionError = error instanceof ApiError ? error.kind : 'server';
	}

	async function load(): Promise<void> {
		loadState = 'loading';
		loadErrorKind = null;
		try {
			event = await api.fetchEvent(instance, communitySlug, eventId);
			loadState = 'ready';
		} catch (error) {
			loadErrorKind = error instanceof ApiError ? error.kind : 'server';
			loadState = 'error';
		}
	}

	async function rsvp(status: RsvpStatus): Promise<void> {
		if (!event) return;
		const previous = event;
		event = applyRsvp(event, status);
		try {
			await api.rsvp(instance, communitySlug, eventId, status);
		} catch (error) {
			event = previous;
			report(error);
		}
	}

	// Slot writes race on capacity, so we take the server's authoritative
	// event rather than guess — no optimistic overbook.
	async function claimSlot(slotId: string, claimed: boolean): Promise<void> {
		try {
			event = await api.setSlotClaim(instance, communitySlug, eventId, slotId, claimed);
		} catch (error) {
			report(error);
		}
	}

	async function addSlot(input: { title: string; capacity: number }): Promise<boolean> {
		try {
			event = await api.createSlot(instance, communitySlug, eventId, input);
			return true;
		} catch (error) {
			report(error);
			return false;
		}
	}

	async function removeSlot(slotId: string): Promise<void> {
		try {
			event = await api.deleteSlot(instance, communitySlug, eventId, slotId);
		} catch (error) {
			report(error);
		}
	}

	async function comment(input: {
		body_markdown: string;
		parent_comment_id?: string | null;
	}): Promise<boolean> {
		if (!event) return false;
		try {
			const created = await api.createComment(instance, communitySlug, eventId, input);
			event = upsertComment(event, created);
			return true;
		} catch (error) {
			report(error);
			return false;
		}
	}

	async function editComment(commentId: string, body: string): Promise<boolean> {
		if (!event) return false;
		try {
			const edited = await api.editComment(instance, communitySlug, eventId, commentId, body);
			event = upsertComment(event, edited);
			return true;
		} catch (error) {
			report(error);
			return false;
		}
	}

	async function deleteComment(commentId: string): Promise<void> {
		if (!event) return;
		try {
			const tombstone = await api.deleteComment(instance, communitySlug, eventId, commentId);
			event = upsertComment(event, tombstone);
		} catch (error) {
			report(error);
		}
	}

	async function reactComment(commentId: string, emoji: string): Promise<void> {
		if (!event) return;
		try {
			const reacted = await api.reactComment(instance, communitySlug, eventId, commentId, emoji);
			event = upsertComment(event, reacted);
		} catch (error) {
			report(error);
		}
	}

	// Reporting (issue #262) changes nothing in the event — the report goes
	// to the moderation queue — so success is just `true` for the caller's
	// own confirmation UI; failures land in the shared `actionError` banner.
	async function reportComment(commentId: string, reason: string): Promise<boolean> {
		try {
			await api.reportComment(instance, communitySlug, eventId, commentId, reason);
			return true;
		} catch (error) {
			report(error);
			return false;
		}
	}

	return {
		get event() {
			return event;
		},
		get loadState() {
			return loadState;
		},
		get loadErrorKind() {
			return loadErrorKind;
		},
		get actionError() {
			return actionError;
		},
		clearActionError() {
			actionError = null;
		},
		load,
		rsvp,
		claimSlot,
		addSlot,
		removeSlot,
		comment,
		editComment,
		deleteComment,
		reactComment,
		reportComment
	};
}

export type EventStore = ReturnType<typeof createEventStore>;
