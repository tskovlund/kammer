import { FeedApiError, type FeedErrorKind } from '$lib/feed/api.js';
import type { Instance } from '$lib/instances/types.js';
import * as api from './api.js';
import type { CustomField, Member, Role, Roster } from './types.js';

type LoadState = 'idle' | 'loading' | 'ready' | 'error';

/**
 * One community's member directory (#182): the server redacts fields per
 * viewer role (ADR 0020) and applies the custom-field filters, so every
 * filter change and every admin action (role change, removal) refetches
 * rather than guessing. Failures land in `actionError` for a dismissible
 * banner, mirroring the feed and files stores.
 */
export function createRosterStore(instance: Instance, communitySlug: string) {
	let roster = $state<Roster | null>(null);
	let filter = $state<Record<string, string>>({});
	let loadState = $state<LoadState>('idle');
	let loadErrorKind = $state<FeedErrorKind | null>(null);
	let actionError = $state<{ message: string; kind: FeedErrorKind } | null>(null);
	let busy = $state(false);
	// Discards a fetch that resolves after a newer filter change, so a slow
	// unfiltered response never overwrites the filtered one on screen.
	let generation = 0;

	function report(error: unknown): void {
		if (error instanceof FeedApiError) actionError = { message: error.message, kind: error.kind };
		else actionError = { message: 'Something went wrong.', kind: 'server' };
	}

	async function load(): Promise<void> {
		const mine = ++generation;
		loadState = 'loading';
		loadErrorKind = null;
		try {
			const next = await api.fetchRoster(instance, communitySlug, filter);
			if (mine !== generation) return;
			roster = next;
			loadState = 'ready';
		} catch (error) {
			if (mine !== generation) return;
			loadErrorKind = error instanceof FeedApiError ? error.kind : 'server';
			loadState = 'error';
		}
	}

	function setFilter(fieldId: string, value: string): Promise<void> {
		if (value === '') {
			const rest = { ...filter };
			delete rest[fieldId];
			filter = rest;
		} else {
			filter = { ...filter, [fieldId]: value };
		}
		return load();
	}

	async function changeRole(member: Member, role: Role): Promise<void> {
		busy = true;
		try {
			await api.updateMemberRole(instance, communitySlug, member.user.id, role);
			await load();
		} catch (error) {
			report(error);
		} finally {
			busy = false;
		}
	}

	async function remove(member: Member): Promise<void> {
		busy = true;
		try {
			await api.removeMember(instance, communitySlug, member.user.id);
			await load();
		} catch (error) {
			report(error);
		} finally {
			busy = false;
		}
	}

	return {
		get members(): Member[] {
			return roster?.members ?? [];
		},
		get fields(): CustomField[] {
			return roster?.fields ?? [];
		},
		/** Only single-select fields make meaningful equality filters. */
		get filterableFields(): CustomField[] {
			return (roster?.fields ?? []).filter((field) => field.field_type === 'single_select');
		},
		get filter(): Record<string, string> {
			return filter;
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
		get busy() {
			return busy;
		},
		clearActionError() {
			actionError = null;
		},
		load,
		setFilter,
		changeRole,
		remove,
		stop() {
			generation += 1;
		}
	};
}

export type RosterStore = ReturnType<typeof createRosterStore>;
