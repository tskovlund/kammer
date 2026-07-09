import { describe, expect, it } from 'vitest';
import {
	applyOptimisticVote,
	hasReacted,
	nextPollSelection,
	pollClosed,
	pollOptionPercent,
	toggleReaction,
	totalPollVotes,
	type ReactionState
} from './interactions';
import type { Poll } from './types';

function poll(overrides: Partial<Poll> = {}): Poll {
	return {
		id: 'poll-1',
		multiple_choice: false,
		anonymous: false,
		closes_at: null,
		my_votes: [],
		options: [
			{ id: 'a', text: 'A', votes: 0 },
			{ id: 'b', text: 'B', votes: 0 }
		],
		...overrides
	};
}

describe('toggleReaction', () => {
	it('adds a new reaction and records it as mine', () => {
		const state: ReactionState = { reactions: { '👍': 2 }, my_reactions: [] };
		const next = toggleReaction(state, '👍');
		expect(next.reactions['👍']).toBe(3);
		expect(next.my_reactions).toContain('👍');
	});

	it('removes my reaction and deletes the emoji key at zero', () => {
		const state: ReactionState = { reactions: { '🎉': 1 }, my_reactions: ['🎉'] };
		const next = toggleReaction(state, '🎉');
		expect(next.reactions['🎉']).toBeUndefined();
		expect(next.my_reactions).not.toContain('🎉');
	});

	it('decrements but keeps the pill when others still reacted', () => {
		const state: ReactionState = { reactions: { '❤️': 3 }, my_reactions: ['❤️'] };
		const next = toggleReaction(state, '❤️');
		expect(next.reactions['❤️']).toBe(2);
	});

	it('does not mutate the input state', () => {
		const state: ReactionState = { reactions: { '👍': 1 }, my_reactions: [] };
		toggleReaction(state, '👍');
		expect(state).toEqual({ reactions: { '👍': 1 }, my_reactions: [] });
	});

	it('round-trips to the original state when toggled twice', () => {
		const state: ReactionState = { reactions: { '👍': 2 }, my_reactions: [] };
		const there = toggleReaction(state, '👍');
		const back = toggleReaction(there, '👍');
		expect(back).toEqual(state);
	});

	it('derives whether I have reacted', () => {
		expect(hasReacted({ reactions: {}, my_reactions: ['👍'] }, '👍')).toBe(true);
		expect(hasReacted({ reactions: {}, my_reactions: [] }, '👍')).toBe(false);
	});
});

describe('nextPollSelection — single choice', () => {
	it('selects an option when none is chosen', () => {
		expect(nextPollSelection(poll(), 'a')).toEqual(['a']);
	});

	it('replaces the current choice with a different one', () => {
		expect(nextPollSelection(poll({ my_votes: ['a'] }), 'b')).toEqual(['b']);
	});

	it('unvotes when clicking the already-selected option', () => {
		expect(nextPollSelection(poll({ my_votes: ['a'] }), 'a')).toEqual([]);
	});
});

describe('nextPollSelection — multiple choice', () => {
	it('adds an option to the existing selection', () => {
		expect(nextPollSelection(poll({ multiple_choice: true, my_votes: ['a'] }), 'b')).toEqual([
			'a',
			'b'
		]);
	});

	it('removes just the clicked option from the selection', () => {
		expect(nextPollSelection(poll({ multiple_choice: true, my_votes: ['a', 'b'] }), 'a')).toEqual([
			'b'
		]);
	});
});

describe('nextPollSelection — closed poll', () => {
	it('refuses to change the selection after the close time', () => {
		const closed = poll({ closes_at: '2026-01-01T00:00:00Z', my_votes: ['a'] });
		const now = new Date('2026-02-01T00:00:00Z');
		expect(nextPollSelection(closed, 'b', now)).toEqual(['a']);
	});

	it('still allows voting before the close time', () => {
		const open = poll({ closes_at: '2026-12-01T00:00:00Z' });
		const now = new Date('2026-06-01T00:00:00Z');
		expect(nextPollSelection(open, 'a', now)).toEqual(['a']);
	});
});

describe('pollClosed', () => {
	it('is false for a poll with no close date', () => {
		expect(pollClosed(poll())).toBe(false);
	});

	it('is true once the close time has passed', () => {
		expect(pollClosed(poll({ closes_at: '2026-01-01T00:00:00Z' }), new Date('2026-02-01'))).toBe(
			true
		);
	});
});

describe('applyOptimisticVote', () => {
	it('moves a single-choice vote between options, adjusting counts', () => {
		const p = poll({
			my_votes: ['a'],
			options: [
				{ id: 'a', text: 'A', votes: 3 },
				{ id: 'b', text: 'B', votes: 1 }
			]
		});
		const next = applyOptimisticVote(p, ['b']);
		expect(next.options.find((o) => o.id === 'a')?.votes).toBe(2);
		expect(next.options.find((o) => o.id === 'b')?.votes).toBe(2);
		expect(next.my_votes).toEqual(['b']);
	});

	it('increments only newly added options and decrements removed ones', () => {
		const p = poll({
			multiple_choice: true,
			my_votes: ['a'],
			options: [
				{ id: 'a', text: 'A', votes: 2 },
				{ id: 'b', text: 'B', votes: 2 }
			]
		});
		const next = applyOptimisticVote(p, ['a', 'b']);
		expect(next.options.find((o) => o.id === 'a')?.votes).toBe(2); // unchanged
		expect(next.options.find((o) => o.id === 'b')?.votes).toBe(3); // added
	});

	it('never drives a count below zero', () => {
		const p = poll({
			my_votes: ['a'],
			options: [{ id: 'a', text: 'A', votes: 0 }]
		});
		expect(applyOptimisticVote(p, []).options[0].votes).toBe(0);
	});
});

describe('poll tallies', () => {
	it('totals votes across options', () => {
		const p = poll({
			options: [
				{ id: 'a', text: 'A', votes: 3 },
				{ id: 'b', text: 'B', votes: 1 }
			]
		});
		expect(totalPollVotes(p)).toBe(4);
	});

	it('computes an option percentage, and 0 for an empty poll', () => {
		const p = poll({
			options: [
				{ id: 'a', text: 'A', votes: 3 },
				{ id: 'b', text: 'B', votes: 1 }
			]
		});
		expect(pollOptionPercent(p, 'a')).toBe(75);
		expect(pollOptionPercent(poll(), 'a')).toBe(0);
	});
});
