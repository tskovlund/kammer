import { describe, expect, it } from 'vitest';
import { dayOffsetFromToday, groupEventsByDay } from './agenda.js';
import type { MergedEvent } from './types.js';

function event(overrides: Partial<MergedEvent> & { id: string; starts_at: string }): MergedEvent {
	return {
		group_id: 'g1',
		group: { id: 'g1', name: 'Group', slug: 'group' },
		series_id: null,
		title: 'Event',
		description_markdown: null,
		ends_at: null,
		all_day: false,
		timezone: 'Etc/UTC',
		location_name: null,
		location_url: null,
		cancelled: false,
		comments_locked: false,
		capacity: null,
		rsvp_counts: { yes: 0, maybe: 0, no: 0, waitlisted: 0 },
		my_rsvp: null,
		waitlist_position: null,
		waitlist: [],
		slots: [],
		comments: [],
		instance: {
			id: 'i1',
			baseUrl: 'https://a.example',
			instanceName: 'A',
			deviceToken: 't',
			user: { id: 'u1', email: 'a@a', displayName: 'A' },
			addedAt: '2026-01-01T00:00:00Z'
		},
		community: {
			id: 'c1',
			name: 'Community',
			slug: 'community',
			description: null,
			accent_color: '#3E6B48',
			default_locale: 'en',
			listed_on_instance: false,
			require_real_names: false,
			viewer_can: []
		},
		...overrides
	};
}

// Anchor on a fixed local day so the local-calendar bucketing is deterministic.
function at(day: number, hour: number): string {
	return new Date(2026, 5, day, hour, 0, 0).toISOString();
}

describe('groupEventsByDay', () => {
	it('buckets events by local calendar day, soonest first', () => {
		const events = [
			event({ id: 'b', starts_at: at(11, 9) }),
			event({ id: 'a', starts_at: at(10, 18) }),
			event({ id: 'c', starts_at: at(11, 20) })
		];

		const days = groupEventsByDay(events);

		expect(days.map((d) => d.key)).toEqual(['2026-06-10', '2026-06-11']);
		expect(days[0].events.map((e) => e.id)).toEqual(['a']);
		// Within a day, earlier start comes first.
		expect(days[1].events.map((e) => e.id)).toEqual(['b', 'c']);
	});

	it('drops cancelled occurrences from the agenda', () => {
		const days = groupEventsByDay([
			event({ id: 'live', starts_at: at(10, 9) }),
			event({ id: 'gone', starts_at: at(10, 10), cancelled: true })
		]);

		expect(days).toHaveLength(1);
		expect(days[0].events.map((e) => e.id)).toEqual(['live']);
	});

	it('returns nothing for an empty list', () => {
		expect(groupEventsByDay([])).toEqual([]);
	});
});

describe('dayOffsetFromToday', () => {
	it('is 0 for today and 1 for tomorrow', () => {
		const now = new Date(2026, 5, 10, 12, 0, 0);
		expect(dayOffsetFromToday('2026-06-10', now)).toBe(0);
		expect(dayOffsetFromToday('2026-06-11', now)).toBe(1);
		expect(dayOffsetFromToday('2026-06-09', now)).toBe(-1);
		expect(dayOffsetFromToday('2026-06-17', now)).toBe(7);
	});
});
