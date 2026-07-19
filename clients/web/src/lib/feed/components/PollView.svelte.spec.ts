import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/svelte';
import { flushSync } from 'svelte';
import PollView from './PollView.svelte';
import type { Poll } from '$lib/feed/types.js';

function poll(overrides: Partial<Poll> = {}): Poll {
	return {
		id: 'poll-1',
		multiple_choice: false,
		anonymous: false,
		closes_at: null,
		my_votes: [],
		options: [
			{ id: 'a', text: 'Pizza', votes: 0 },
			{ id: 'b', text: 'Salad', votes: 0 }
		],
		...overrides
	};
}

describe('PollView', () => {
	beforeEach(() => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-07-16T12:00:00Z'));
	});
	afterEach(() => {
		vi.useRealTimers();
		document.body.innerHTML = '';
	});

	// The fossilization fix (#316): `closed` derives from the reactive
	// `minuteNow()`, so an open poll disables its options the minute the
	// deadline passes even on a quiet screen — not only on the next
	// interaction or remount.
	it('closes an open poll the minute its deadline passes', () => {
		render(PollView, {
			props: {
				poll: poll({ closes_at: '2026-07-16T12:00:30Z' }),
				onVote: () => {},
				idPrefix: 'x'
			}
		});

		const option = screen.getByRole('button', { name: /Pizza/ });
		expect(option.hasAttribute('disabled')).toBe(false);

		// A minute later the deadline is 30s past — the buttons must lock.
		vi.advanceTimersByTime(60_000);
		flushSync();

		expect(option.hasAttribute('disabled')).toBe(true);
	});
});
