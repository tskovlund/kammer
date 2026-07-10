import type { AvailabilityOption, AvailabilityPoll } from './api.js';

/** The three answers a member can give for a candidate date. */
export interface AnswerTally {
	yes: number;
	if_needed: number;
	no: number;
}

/** Count each answer for one candidate date (the winning date is the most `yes`). */
export function tallyAnswers(option: AvailabilityOption): AnswerTally {
	const tally: AnswerTally = { yes: 0, if_needed: 0, no: 0 };
	for (const response of option.responses) tally[response.answer] += 1;
	return tally;
}

/**
 * The community-wide poll index, narrowed to one group (the endpoint has no
 * per-group route) and ordered newest-first so a freshly raised poll leads.
 */
export function pollsForGroup(polls: AvailabilityPoll[], groupId: string): AvailabilityPoll[] {
	return polls
		.filter((poll) => poll.group_id === groupId)
		.sort((a, b) => (b.created_at ?? '').localeCompare(a.created_at ?? ''));
}
