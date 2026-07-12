import { createApiClient } from '$lib/api/client.js';
import { fail, guard } from '$lib/api/errors.js';
import type { components } from '$lib/api/schema.js';
import type { Instance } from '$lib/instances/types.js';

/**
 * The collaborative-tools surface over the API (issue #184): availability
 * (date-finding) polls, group assignments, and the decisions register, plus
 * cross-community global search (SPEC §10). Every screen consumes each
 * entry's `viewer_can` to decide which controls to show, but the server is
 * the enforcer — a `forbidden` from a stale capability list degrades to an
 * inline error rather than a broken screen.
 *
 * Errors through the shared `ApiError` (#270) — the same class the feed
 * fetch a tools screen loads its group from throws, so a page pairing a
 * feed-family fetch with a tool call funnels both through one `errorKind`.
 */

export type AvailabilityPoll = components['schemas']['AvailabilityPoll'];
export type AvailabilityOption = AvailabilityPoll['options'][number];
export type AvailabilityAnswer = NonNullable<AvailabilityOption['my_answer']>;
export type Assignment = components['schemas']['Assignment'];
export type Decision = components['schemas']['Decision'];
export type DecisionOutcome = NonNullable<Decision['outcome']>;
export type SearchResults = components['schemas']['SearchResults'];
export type Comment = components['schemas']['Comment'];

function client(instance: Instance) {
	return createApiClient(instance.baseUrl, instance.deviceToken);
}

// --- Availability polls (issue #39) ----------------------------------------

/** Open date-finding polls across the community (a group view filters by id). */
export async function fetchPolls(
	instance: Instance,
	communitySlug: string
): Promise<AvailabilityPoll[]> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET(
			'/api/v1/communities/{community_slug}/availability',
			{ params: { path: { community_slug: communitySlug } } }
		);
		if (error || !data) throw fail(error, response, 'Could not load polls.');
		return data.data;
	});
}

export async function createPoll(
	instance: Instance,
	communitySlug: string,
	groupSlug: string,
	body: { title: string; options: string[] }
): Promise<AvailabilityPoll> {
	return guard(async () => {
		const { data, error, response } = await client(instance).POST(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/availability',
			{
				params: { path: { community_slug: communitySlug, group_slug: groupSlug } },
				body
			}
		);
		if (error || !data) throw fail(error, response, 'Could not create the poll.');
		return data.data;
	});
}

export async function respondPoll(
	instance: Instance,
	communitySlug: string,
	pollId: string,
	body: { option_id: string; answer: AvailabilityAnswer }
): Promise<AvailabilityPoll> {
	return guard(async () => {
		const { data, error, response } = await client(instance).PUT(
			'/api/v1/communities/{community_slug}/availability/{poll_id}/responses',
			{ params: { path: { community_slug: communitySlug, poll_id: pollId } }, body }
		);
		if (error || !data) throw fail(error, response, 'Could not save your answer.');
		return data.data;
	});
}

export async function closePoll(
	instance: Instance,
	communitySlug: string,
	pollId: string
): Promise<AvailabilityPoll> {
	return guard(async () => {
		const { data, error, response } = await client(instance).PUT(
			'/api/v1/communities/{community_slug}/availability/{poll_id}/closure',
			{ params: { path: { community_slug: communitySlug, poll_id: pollId } } }
		);
		if (error || !data) throw fail(error, response, 'Could not close the poll.');
		return data.data;
	});
}

export async function convertPoll(
	instance: Instance,
	communitySlug: string,
	pollId: string,
	body: { option_id: string }
): Promise<AvailabilityPoll> {
	return guard(async () => {
		const { data, error, response } = await client(instance).PUT(
			'/api/v1/communities/{community_slug}/availability/{poll_id}/conversion',
			{ params: { path: { community_slug: communitySlug, poll_id: pollId } }, body }
		);
		if (error || !data) throw fail(error, response, 'Could not convert the poll.');
		return data.data;
	});
}

// --- Assignments (issue #17) ------------------------------------------------

export async function fetchAssignments(
	instance: Instance,
	communitySlug: string,
	groupSlug: string
): Promise<Assignment[]> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/assignments',
			{ params: { path: { community_slug: communitySlug, group_slug: groupSlug } } }
		);
		if (error || !data) throw fail(error, response, 'Could not load the task list.');
		return data.data;
	});
}

export async function fetchAssignment(
	instance: Instance,
	communitySlug: string,
	assignmentId: string
): Promise<Assignment> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET(
			'/api/v1/communities/{community_slug}/assignments/{assignment_id}',
			{ params: { path: { community_slug: communitySlug, assignment_id: assignmentId } } }
		);
		if (error || !data) throw fail(error, response, 'Could not load this task.');
		return data.data;
	});
}

export async function createAssignment(
	instance: Instance,
	communitySlug: string,
	groupSlug: string,
	body: { title: string; due_at?: string | null; notes_markdown?: string | null }
): Promise<Assignment> {
	return guard(async () => {
		const { data, error, response } = await client(instance).POST(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/assignments',
			{
				params: { path: { community_slug: communitySlug, group_slug: groupSlug } },
				body
			}
		);
		if (error || !data) throw fail(error, response, 'Could not create the task.');
		return data.data;
	});
}

export async function setAssignmentClaim(
	instance: Instance,
	communitySlug: string,
	assignmentId: string,
	claimed: boolean
): Promise<Assignment> {
	return guard(async () => {
		const path = { community_slug: communitySlug, assignment_id: assignmentId };
		const call = claimed
			? client(instance).PUT(
					'/api/v1/communities/{community_slug}/assignments/{assignment_id}/claim',
					{ params: { path } }
				)
			: client(instance).DELETE(
					'/api/v1/communities/{community_slug}/assignments/{assignment_id}/claim',
					{ params: { path } }
				);
		const { data, error, response } = await call;
		if (error || !data) throw fail(error, response, 'Could not update your claim.');
		return data.data;
	});
}

export async function setAssignmentCompleted(
	instance: Instance,
	communitySlug: string,
	assignmentId: string,
	completed: boolean
): Promise<Assignment> {
	return guard(async () => {
		const path = { community_slug: communitySlug, assignment_id: assignmentId };
		const call = completed
			? client(instance).PUT(
					'/api/v1/communities/{community_slug}/assignments/{assignment_id}/completion',
					{ params: { path } }
				)
			: client(instance).DELETE(
					'/api/v1/communities/{community_slug}/assignments/{assignment_id}/completion',
					{ params: { path } }
				);
		const { data, error, response } = await call;
		if (error || !data) throw fail(error, response, 'Could not update the task.');
		return data.data;
	});
}

export async function commentAssignment(
	instance: Instance,
	communitySlug: string,
	assignmentId: string,
	body: { body_markdown: string; parent_comment_id?: string | null }
): Promise<Comment> {
	return guard(async () => {
		const { data, error, response } = await client(instance).POST(
			'/api/v1/communities/{community_slug}/assignments/{assignment_id}/comments',
			{ params: { path: { community_slug: communitySlug, assignment_id: assignmentId } }, body }
		);
		if (error || !data) throw fail(error, response, 'Could not post your comment.');
		return data.data;
	});
}

/**
 * Report an assignment comment to the moderators (issue #262). The server
 * answers a bare `{status: "reported"}` — reporting the same comment again
 * answers the same — so there is nothing to merge back into the assignment.
 */
export async function reportAssignmentComment(
	instance: Instance,
	communitySlug: string,
	assignmentId: string,
	commentId: string,
	reason: string
): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(instance).POST(
			'/api/v1/communities/{community_slug}/assignments/{assignment_id}/comments/{comment_id}/report',
			{
				params: {
					path: {
						community_slug: communitySlug,
						assignment_id: assignmentId,
						comment_id: commentId
					}
				},
				body: { reason }
			}
		);
		if (error) throw fail(error, response, 'Could not send your report.');
	});
}

export async function deleteAssignment(
	instance: Instance,
	communitySlug: string,
	assignmentId: string
): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(instance).DELETE(
			'/api/v1/communities/{community_slug}/assignments/{assignment_id}',
			{ params: { path: { community_slug: communitySlug, assignment_id: assignmentId } } }
		);
		if (error) throw fail(error, response, 'Could not delete this task.');
	});
}

// --- Decisions register (issue #43) ----------------------------------------

export async function fetchDecisions(
	instance: Instance,
	communitySlug: string,
	groupSlug: string
): Promise<Decision[]> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/decisions',
			{ params: { path: { community_slug: communitySlug, group_slug: groupSlug } } }
		);
		if (error || !data) throw fail(error, response, 'Could not load the register.');
		return data.data;
	});
}

export async function createDecision(
	instance: Instance,
	communitySlug: string,
	groupSlug: string,
	body: { title: string; motion_markdown?: string | null; with_vote?: boolean }
): Promise<Decision> {
	return guard(async () => {
		const { data, error, response } = await client(instance).POST(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/decisions',
			{
				params: { path: { community_slug: communitySlug, group_slug: groupSlug } },
				body
			}
		);
		if (error || !data) throw fail(error, response, 'Could not raise the motion.');
		return data.data;
	});
}

export async function recordOutcome(
	instance: Instance,
	communitySlug: string,
	decisionId: string,
	body: { outcome: DecisionOutcome; outcome_note?: string | null }
): Promise<Decision> {
	return guard(async () => {
		const { data, error, response } = await client(instance).PUT(
			'/api/v1/communities/{community_slug}/decisions/{decision_id}/outcome',
			{ params: { path: { community_slug: communitySlug, decision_id: decisionId } }, body }
		);
		if (error || !data) throw fail(error, response, 'Could not record the outcome.');
		return data.data;
	});
}

// --- Global search (SPEC §10) ----------------------------------------------

/** Community-scoped search; a blank query returns empty sections. */
export async function search(
	instance: Instance,
	communitySlug: string,
	query: string
): Promise<SearchResults> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET(
			'/api/v1/communities/{community_slug}/search',
			{ params: { path: { community_slug: communitySlug }, query: { q: query } } }
		);
		if (error || !data) throw fail(error, response, 'Could not search this community.');
		return data.data;
	});
}
