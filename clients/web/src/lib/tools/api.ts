import { createApiClient } from '$lib/api/client.js';
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
 * Error plumbing mirrors `$lib/manage/api.ts` and `$lib/feed/api.ts` (each
 * API module carries its own, per this codebase's convention) so callers get
 * a stable `{ kind, status }` shape without importing another surface's.
 */

export type AvailabilityPoll = components['schemas']['AvailabilityPoll'];
export type AvailabilityOption = AvailabilityPoll['options'][number];
export type AvailabilityAnswer = NonNullable<AvailabilityOption['my_answer']>;
export type Assignment = components['schemas']['Assignment'];
export type Decision = components['schemas']['Decision'];
export type DecisionOutcome = NonNullable<Decision['outcome']>;
export type SearchResults = components['schemas']['SearchResults'];
export type Comment = components['schemas']['Comment'];

export type ToolsErrorKind =
	'auth' | 'forbidden' | 'not_found' | 'validation' | 'rate_limited' | 'network' | 'server';

export class ToolsApiError extends Error {
	readonly kind: ToolsErrorKind;
	readonly status: number | null;

	constructor(kind: ToolsErrorKind, message: string, status: number | null = null) {
		super(message);
		this.name = 'ToolsApiError';
		this.kind = kind;
		this.status = status;
	}
}

function kindForStatus(status: number): ToolsErrorKind {
	switch (status) {
		case 401:
			return 'auth';
		case 403:
			return 'forbidden';
		case 404:
			return 'not_found';
		case 422:
			return 'validation';
		case 429:
			return 'rate_limited';
		default:
			return 'server';
	}
}

interface ErrorEnvelope {
	error?: { code?: string; message?: string };
}

function messageFrom(error: unknown, fallback: string): string {
	const envelope = error as ErrorEnvelope | undefined;
	return envelope?.error?.message ?? fallback;
}

function client(instance: Instance) {
	return createApiClient(instance.baseUrl, instance.deviceToken);
}

function fail(error: unknown, response: Response | undefined, fallback: string): ToolsApiError {
	const status = response?.status ?? null;
	const kind = status ? kindForStatus(status) : 'server';
	return new ToolsApiError(kind, messageFrom(error, fallback), status);
}

async function guard<T>(request: () => Promise<T>): Promise<T> {
	try {
		return await request();
	} catch (cause) {
		if (cause instanceof ToolsApiError) throw cause;
		throw new ToolsApiError('network', 'Could not reach this community.', null);
	}
}

const ERROR_KINDS: readonly ToolsErrorKind[] = [
	'auth',
	'forbidden',
	'not_found',
	'validation',
	'rate_limited',
	'network',
	'server'
];

/**
 * Normalize any caught error to a `ToolsErrorKind`. A screen that loads its
 * group via `$lib/feed/api` (a `FeedApiError`, whose kinds are a superset —
 * it also has `too_large`) and its tool data via this module can funnel both
 * through one branch; anything unrecognized (including `too_large`) collapses
 * to `server`.
 */
export function toolsErrorKind(cause: unknown): ToolsErrorKind {
	const kind = (cause as { kind?: unknown } | null)?.kind;
	return typeof kind === 'string' && (ERROR_KINDS as readonly string[]).includes(kind)
		? (kind as ToolsErrorKind)
		: 'server';
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
