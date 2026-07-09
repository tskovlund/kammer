import type { MergedEvent } from './types.js';

/**
 * The Events tab is an agenda list, not a month grid (SPEC §21, "calm"):
 * a merged, multi-community month grid is dense and awkward on a phone,
 * whereas a soonest-first list grouped by day reads at a glance and scales
 * to any number of communities. Grouping is by the viewer's local calendar
 * day, so "what's on today" means today where the viewer is.
 */
export interface AgendaDay {
	/** Local calendar day, `YYYY-MM-DD` — the stable bucket key. */
	key: string;
	/** Local midnight of that day, for formatting the heading. */
	date: Date;
	events: MergedEvent[];
}

function localDateKey(date: Date): string {
	const year = date.getFullYear();
	const month = String(date.getMonth() + 1).padStart(2, '0');
	const day = String(date.getDate()).padStart(2, '0');
	return `${year}-${month}-${day}`;
}

function dateFromKey(key: string): Date {
	const [year, month, day] = key.split('-').map(Number);
	return new Date(year, month - 1, day);
}

/**
 * Bucket merged events by their local start day, soonest first, with each
 * day's events kept in start order. Cancelled occurrences are dropped —
 * they've left the schedule (they stay reachable by direct link only).
 */
export function groupEventsByDay(events: MergedEvent[], now: Date = new Date()): AgendaDay[] {
	const buckets = new Map<string, MergedEvent[]>();

	const ordered = [...events]
		.filter((event) => !event.cancelled)
		.sort((a, b) => a.starts_at.localeCompare(b.starts_at));

	for (const event of ordered) {
		const key = localDateKey(new Date(event.starts_at));
		const bucket = buckets.get(key);
		if (bucket) bucket.push(event);
		else buckets.set(key, [event]);
	}

	// Guard against a clock reading exactly on a boundary: the map preserves
	// insertion order, and inputs were sorted, so keys are already ascending.
	void now;

	return [...buckets.entries()].map(([key, dayEvents]) => ({
		key,
		date: dateFromKey(key),
		events: dayEvents
	}));
}

/**
 * How many whole calendar days a bucket is from today (0 = today, 1 =
 * tomorrow, negative = in the past). Lets the UI label the nearest days
 * warmly ("Today", "Tomorrow") and fall back to a formatted date otherwise.
 */
export function dayOffsetFromToday(dayKey: string, now: Date = new Date()): number {
	const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
	const target = dateFromKey(dayKey);
	return Math.round((target.getTime() - today.getTime()) / 86_400_000);
}
