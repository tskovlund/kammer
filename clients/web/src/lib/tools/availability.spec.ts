import { describe, expect, it } from 'vitest';
import type { AvailabilityOption, AvailabilityPoll } from './api.js';
import { pollsForGroup, tallyAnswers } from './availability.js';

function option(answers: AvailabilityOption['responses']): AvailabilityOption {
	return { id: 'o1', starts_at: '2026-06-10T18:00:00Z', position: 0, responses: answers };
}

function poll(id: string, groupId: string, createdAt: string): AvailabilityPoll {
	return {
		id,
		group_id: groupId,
		title: `Poll ${id}`,
		closed: false,
		created_at: createdAt,
		options: [],
		viewer_can: []
	};
}

describe('tallyAnswers', () => {
	it('counts each answer for a candidate date', () => {
		const tally = tallyAnswers(
			option([
				{ answer: 'yes', user: { id: 'u1', display_name: 'A' } },
				{ answer: 'yes', user: { id: 'u2', display_name: 'B' } },
				{ answer: 'if_needed', user: { id: 'u3', display_name: 'C' } },
				{ answer: 'no', user: { id: 'u4', display_name: 'D' } }
			])
		);
		expect(tally).toEqual({ yes: 2, if_needed: 1, no: 1 });
	});
});

describe('pollsForGroup', () => {
	it('keeps only the group and orders newest first', () => {
		const polls = [
			poll('old', 'g1', '2026-06-01T00:00:00Z'),
			poll('other', 'g2', '2026-06-05T00:00:00Z'),
			poll('new', 'g1', '2026-06-09T00:00:00Z')
		];
		expect(pollsForGroup(polls, 'g1').map((p) => p.id)).toEqual(['new', 'old']);
	});
});
