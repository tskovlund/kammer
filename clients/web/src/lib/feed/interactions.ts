import type { Poll } from './types.js';

/** The reaction state shared by posts and comments: emoji→count plus mine. */
export interface ReactionState {
	reactions: Record<string, number>;
	my_reactions: string[];
}

/**
 * Toggle the viewer's reaction for one emoji, returning fresh reaction state
 * — the optimistic update applied the instant the button is pressed, before
 * the server round-trip. Adding bumps the count and records the emoji as
 * mine; removing decrements and drops the emoji key entirely at zero (so the
 * pill disappears rather than lingering as "0"). The server response, shaped
 * by the same serializer, then replaces this state authoritatively.
 */
export function toggleReaction(state: ReactionState, emoji: string): ReactionState {
	const mine = state.my_reactions.includes(emoji);
	const reactions = { ...state.reactions };
	const current = reactions[emoji] ?? 0;

	if (mine) {
		const next = current - 1;
		if (next <= 0) delete reactions[emoji];
		else reactions[emoji] = next;
		return { reactions, my_reactions: state.my_reactions.filter((e) => e !== emoji) };
	}

	reactions[emoji] = current + 1;
	return { reactions, my_reactions: [...state.my_reactions, emoji] };
}

/** Whether the viewer currently reacts with `emoji`. */
export function hasReacted(state: ReactionState, emoji: string): boolean {
	return state.my_reactions.includes(emoji);
}

/** A poll is closed once its close time has passed — no more voting. */
export function pollClosed(poll: Poll, now: Date = new Date()): boolean {
	return poll.closes_at != null && now.getTime() >= new Date(poll.closes_at).getTime();
}

/** Whether the viewer's current selection includes `optionId`. */
export function hasVotedFor(poll: Poll, optionId: string): boolean {
	return poll.my_votes.includes(optionId);
}

/**
 * The full selection to PUT to `/poll/votes` after clicking one option — the
 * server takes the complete set, not a delta (single-choice keeps the first
 * id, multiple-choice keeps them all).
 *
 * - Closed poll: no change (returns the current selection unchanged).
 * - Single choice: clicking the selected option clears it (unvote); clicking
 *   another option replaces the selection.
 * - Multiple choice: toggles the option in or out of the set.
 */
export function nextPollSelection(poll: Poll, optionId: string, now: Date = new Date()): string[] {
	if (pollClosed(poll, now)) return [...poll.my_votes];
	const selected = poll.my_votes.includes(optionId);

	if (!poll.multiple_choice) {
		return selected ? [] : [optionId];
	}
	return selected ? poll.my_votes.filter((id) => id !== optionId) : [...poll.my_votes, optionId];
}

/**
 * Apply a new selection to a poll optimistically, adjusting each option's
 * vote count by the difference between the old and new selection so results
 * move the instant the viewer votes. Replaced by the server's poll on reply.
 */
export function applyOptimisticVote(poll: Poll, selection: string[]): Poll {
	const wasSelected = new Set(poll.my_votes);
	const nowSelected = new Set(selection);

	return {
		...poll,
		my_votes: [...selection],
		options: poll.options.map((option) => {
			const before = wasSelected.has(option.id);
			const after = nowSelected.has(option.id);
			let votes = option.votes;
			if (after && !before) votes += 1;
			else if (!after && before) votes -= 1;
			return { ...option, votes: Math.max(0, votes) };
		})
	};
}

/** Total votes cast across a poll's options (turnout, not voter count). */
export function totalPollVotes(poll: Poll): number {
	return poll.options.reduce((sum, option) => sum + option.votes, 0);
}

/** An option's share of the vote as a 0–100 percentage (0 when empty). */
export function pollOptionPercent(poll: Poll, optionId: string): number {
	const total = totalPollVotes(poll);
	if (total === 0) return 0;
	const option = poll.options.find((candidate) => candidate.id === optionId);
	if (!option) return 0;
	return Math.round((option.votes / total) * 100);
}
