import { FeedApiError, type FeedErrorKind } from '$lib/feed/api.js';
import type { Instance } from '$lib/instances/types.js';
import * as api from './api.js';
import type { EventSeriesDetail } from './types.js';

type LoadState = 'idle' | 'loading' | 'ready' | 'error';

/**
 * A recurring series' organizer view (issue #260, SPEC §6): the series
 * rule, its occurrences, and the attendance matrix. Read-mostly — the one
 * write is cancelling/reinstating an occurrence, after which we refetch, so
 * both the occurrence list and the matrix (whose columns drop cancelled and
 * past occurrences) stay consistent. The load is organizer-gated server
 * side; `loadErrorKind` carries the `forbidden`/`not_found` the page renders
 * as a calm not-available state.
 */
export function createSeriesStore(instance: Instance, communitySlug: string, seriesId: string) {
	let detail = $state<EventSeriesDetail | null>(null);
	let loadState = $state<LoadState>('idle');
	let loadErrorKind = $state<FeedErrorKind | null>(null);
	let actionError = $state<{ message: string; kind: FeedErrorKind } | null>(null);
	let busy = $state(false);

	async function load(): Promise<void> {
		loadState = 'loading';
		loadErrorKind = null;
		try {
			detail = await api.fetchEventSeries(instance, communitySlug, seriesId);
			loadState = 'ready';
		} catch (error) {
			loadErrorKind = error instanceof FeedApiError ? error.kind : 'server';
			loadState = 'error';
		}
	}

	async function toggleCancelled(occurrenceId: string, cancelled: boolean): Promise<void> {
		if (busy) return;
		busy = true;
		actionError = null;
		try {
			await api.setCancelled(instance, communitySlug, occurrenceId, cancelled);
			// Refetch rather than patch — cancelling drops the occurrence from the
			// matrix columns — but assign in place instead of going through load(),
			// so the current view stays rendered rather than blanking to skeletons.
			// If the write lands but this refetch fails, the banner shows and the
			// view stays on the pre-toggle state; the cancel is idempotent, so a
			// re-click (or reload) reconciles — better than blanking the page.
			detail = await api.fetchEventSeries(instance, communitySlug, seriesId);
		} catch (error) {
			actionError =
				error instanceof FeedApiError
					? { message: error.message, kind: error.kind }
					: { message: 'Something went wrong.', kind: 'server' };
		} finally {
			busy = false;
		}
	}

	return {
		get detail() {
			return detail;
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
		toggleCancelled
	};
}

export type SeriesStore = ReturnType<typeof createSeriesStore>;
