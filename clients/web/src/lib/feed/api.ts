import { createApiClient } from '$lib/api/client.js';
import type { components } from '$lib/api/schema.js';
import type { Instance } from '$lib/instances/types.js';
import type { Comment, Community, Poll, Post, StoredFile } from './types.js';

type Group = components['schemas']['Group'];
export type { Group };

/**
 * How a feed write/read failed. The UI reacts differently per kind: `auth`
 * re-prompts sign-in for that instance (ties into the #159 failure kinds and
 * the socket's `noteAuthFailure`), `forbidden` explains a missing right,
 * `validation`/`too_large`/`rate_limited` are friendly composer errors, and
 * `network`/`server` are retryable.
 */
export type FeedErrorKind =
	| 'auth'
	| 'forbidden'
	| 'not_found'
	| 'validation'
	| 'too_large'
	| 'rate_limited'
	| 'network'
	| 'server';

export class FeedApiError extends Error {
	readonly kind: FeedErrorKind;
	readonly status: number | null;

	constructor(kind: FeedErrorKind, message: string, status: number | null = null) {
		super(message);
		this.name = 'FeedApiError';
		this.kind = kind;
		this.status = status;
	}
}

function kindForStatus(status: number): FeedErrorKind {
	switch (status) {
		case 401:
			return 'auth';
		case 403:
			return 'forbidden';
		case 404:
			return 'not_found';
		case 413:
			return 'too_large';
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

/** Turn an openapi-fetch `{ error, response }` into a typed FeedApiError. */
function fail(error: unknown, response: Response | undefined, fallback: string): FeedApiError {
	const status = response?.status ?? null;
	const kind = status ? kindForStatus(status) : 'server';
	return new FeedApiError(kind, messageFrom(error, fallback), status);
}

async function guard<T>(request: () => Promise<T>): Promise<T> {
	try {
		return await request();
	} catch (cause) {
		if (cause instanceof FeedApiError) throw cause;
		// fetch() itself rejected — DNS, refused connection, offline.
		throw new FeedApiError('network', 'Could not reach this community.', null);
	}
}

interface GroupRef {
	community: string;
	group: string;
}

/**
 * Resolve a community by slug (the merged Home and links carry slugs; the
 * feed screen needs the community's display name for provenance and its id).
 */
export async function fetchCommunity(instance: Instance, slug: string): Promise<Community> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET('/api/v1/communities');
		if (error || !data) throw fail(error, response, 'Could not load communities.');
		const match = data.data.find((community) => community.slug === slug);
		if (!match) throw new FeedApiError('not_found', 'Community not found.', 404);
		return match;
	});
}

/**
 * Resolve a group by slug within a community — needed for the feed channel
 * topic (`feed:group:<id>`), the group's `features` (which composer controls
 * to show), and its name.
 */
export async function fetchGroup(
	instance: Instance,
	communitySlug: string,
	groupSlug: string
): Promise<Group> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET(
			'/api/v1/communities/{community_slug}/groups',
			{ params: { path: { community_slug: communitySlug } } }
		);
		if (error || !data) throw fail(error, response, 'Could not load groups.');
		const match = data.data.find((group) => group.slug === groupSlug);
		if (!match) throw new FeedApiError('not_found', 'Group not found.', 404);
		return match;
	});
}

export interface FeedPage {
	posts: Post[];
	nextCursor: string | null;
}

export async function fetchFeedPage(
	instance: Instance,
	ref: GroupRef,
	cursor?: string | null
): Promise<FeedPage> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/posts',
			{
				params: {
					path: { community_slug: ref.community, group_slug: ref.group },
					query: cursor ? { after: cursor } : undefined
				}
			}
		);
		if (error || !data) throw fail(error, response, 'Could not load this feed.');
		return { posts: data.data, nextCursor: data.next_cursor ?? null };
	});
}

export interface CreatePostInput {
	body_markdown?: string;
	acknowledgment_required?: boolean;
	poll?: {
		options: { text: string }[];
		multiple_choice?: boolean;
		anonymous?: boolean;
		closes_at?: string | null;
	} | null;
	stored_file_ids?: string[];
}

export async function createPost(
	instance: Instance,
	ref: GroupRef,
	input: CreatePostInput
): Promise<Post> {
	return guard(async () => {
		const { data, error, response } = await client(instance).POST(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/posts',
			{
				params: { path: { community_slug: ref.community, group_slug: ref.group } },
				body: input
			}
		);
		if (error || !data) throw fail(error, response, 'Could not publish your post.');
		return data.data;
	});
}

export async function editPost(
	instance: Instance,
	ref: GroupRef,
	postId: string,
	bodyMarkdown: string
): Promise<Post> {
	return guard(async () => {
		const { data, error, response } = await client(instance).PUT(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/posts/{post_id}',
			{
				params: {
					path: { community_slug: ref.community, group_slug: ref.group, post_id: postId }
				},
				body: { body_markdown: bodyMarkdown }
			}
		);
		if (error || !data) throw fail(error, response, 'Could not save your edit.');
		return data.data;
	});
}

export async function deletePost(
	instance: Instance,
	ref: GroupRef,
	postId: string,
	options: { hard?: boolean } = {}
): Promise<Post> {
	return guard(async () => {
		const { data, error, response } = await client(instance).DELETE(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/posts/{post_id}',
			{
				params: {
					path: { community_slug: ref.community, group_slug: ref.group, post_id: postId },
					query: options.hard ? { hard: 'true' } : undefined
				}
			}
		);
		if (error || !data) throw fail(error, response, 'Could not delete this post.');
		return data.data;
	});
}

export async function reactToPost(
	instance: Instance,
	ref: GroupRef,
	postId: string,
	emoji: string
): Promise<Post> {
	return guard(async () => {
		const { data, error, response } = await client(instance).POST(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/posts/{post_id}/reactions',
			{
				params: {
					path: { community_slug: ref.community, group_slug: ref.group, post_id: postId }
				},
				body: { emoji }
			}
		);
		if (error || !data) throw fail(error, response, 'Could not react.');
		return data.data;
	});
}

export async function votePoll(
	instance: Instance,
	ref: GroupRef,
	postId: string,
	optionIds: string[]
): Promise<Poll> {
	return guard(async () => {
		const { data, error, response } = await client(instance).PUT(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/posts/{post_id}/poll/votes',
			{
				params: {
					path: { community_slug: ref.community, group_slug: ref.group, post_id: postId }
				},
				body: { option_ids: optionIds }
			}
		);
		if (error || !data || !data.data) throw fail(error, response, 'Could not record your vote.');
		return data.data;
	});
}

export async function acknowledgePost(
	instance: Instance,
	ref: GroupRef,
	postId: string
): Promise<Post> {
	return guard(async () => {
		const { data, error, response } = await client(instance).PUT(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/posts/{post_id}/acknowledgment',
			{
				params: {
					path: { community_slug: ref.community, group_slug: ref.group, post_id: postId }
				}
			}
		);
		if (error || !data) throw fail(error, response, 'Could not acknowledge this post.');
		return data.data;
	});
}

export async function setPinned(
	instance: Instance,
	ref: GroupRef,
	postId: string,
	pinned: boolean
): Promise<Post> {
	return guard(async () => {
		const path = { community_slug: ref.community, group_slug: ref.group, post_id: postId };
		const url = '/api/v1/communities/{community_slug}/groups/{group_slug}/posts/{post_id}/pin';
		const { data, error, response } = pinned
			? await client(instance).PUT(url, { params: { path } })
			: await client(instance).DELETE(url, { params: { path } });
		if (error || !data) throw fail(error, response, 'Could not update the pin.');
		return data.data;
	});
}

export async function createComment(
	instance: Instance,
	ref: GroupRef,
	postId: string,
	input: { body_markdown: string; parent_comment_id?: string | null }
): Promise<Comment> {
	return guard(async () => {
		const { data, error, response } = await client(instance).POST(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/posts/{post_id}/comments',
			{
				params: {
					path: { community_slug: ref.community, group_slug: ref.group, post_id: postId }
				},
				body: input
			}
		);
		if (error || !data) throw fail(error, response, 'Could not post your comment.');
		return data.data;
	});
}

export async function editComment(
	instance: Instance,
	ref: GroupRef,
	postId: string,
	commentId: string,
	bodyMarkdown: string
): Promise<Comment> {
	return guard(async () => {
		const { data, error, response } = await client(instance).PUT(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/posts/{post_id}/comments/{comment_id}',
			{
				params: {
					path: {
						community_slug: ref.community,
						group_slug: ref.group,
						post_id: postId,
						comment_id: commentId
					}
				},
				body: { body_markdown: bodyMarkdown }
			}
		);
		if (error || !data) throw fail(error, response, 'Could not save your edit.');
		return data.data;
	});
}

export async function deleteComment(
	instance: Instance,
	ref: GroupRef,
	postId: string,
	commentId: string
): Promise<Comment> {
	return guard(async () => {
		const { data, error, response } = await client(instance).DELETE(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/posts/{post_id}/comments/{comment_id}',
			{
				params: {
					path: {
						community_slug: ref.community,
						group_slug: ref.group,
						post_id: postId,
						comment_id: commentId
					}
				}
			}
		);
		if (error || !data) throw fail(error, response, 'Could not delete this comment.');
		return data.data;
	});
}

export async function reactToComment(
	instance: Instance,
	ref: GroupRef,
	postId: string,
	commentId: string,
	emoji: string
): Promise<Comment> {
	return guard(async () => {
		const { data, error, response } = await client(instance).POST(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/posts/{post_id}/comments/{comment_id}/reactions',
			{
				params: {
					path: {
						community_slug: ref.community,
						group_slug: ref.group,
						post_id: postId,
						comment_id: commentId
					}
				},
				body: { emoji }
			}
		);
		if (error || !data) throw fail(error, response, 'Could not react.');
		return data.data;
	});
}

/**
 * Upload one attachment (multipart). Done with `fetch` rather than the typed
 * client so we keep direct access to the status code — 413 (too large) is a
 * distinct, friendly composer error. `transient` skips the group file space
 * for a 30-day auto-expiring upload (SPEC §5).
 */
export async function uploadFile(
	instance: Instance,
	ref: GroupRef,
	file: File,
	options: { transient?: boolean } = {}
): Promise<StoredFile> {
	const form = new FormData();
	form.append('file', file);
	if (options.transient) form.append('transient', 'true');

	const url =
		`${instance.baseUrl.replace(/\/$/, '')}` +
		`/api/v1/communities/${encodeURIComponent(ref.community)}` +
		`/groups/${encodeURIComponent(ref.group)}/uploads`;

	let response: Response;
	try {
		response = await fetch(url, {
			method: 'POST',
			headers: { authorization: `Bearer ${instance.deviceToken}` },
			body: form
		});
	} catch {
		throw new FeedApiError('network', 'Could not reach this community.', null);
	}

	if (!response.ok) {
		let body: unknown = undefined;
		try {
			body = await response.json();
		} catch {
			/* non-JSON error body */
		}
		throw fail(body, response, 'Could not upload that file.');
	}

	const payload = (await response.json()) as { data: StoredFile };
	return payload.data;
}

/** Absolute URL for a serializer-relative file path (`/api/v1/files/...`). */
export function fileUrl(instance: Instance, path: string): string {
	return `${instance.baseUrl.replace(/\/$/, '')}${path}`;
}

/**
 * Fetch a Bearer-authorized file (post attachments are behind the API auth
 * pipeline, so a plain `<img src>` can't carry the token) and return an
 * object URL. The caller must `URL.revokeObjectURL` it when done.
 */
export async function fetchAuthedObjectUrl(instance: Instance, path: string): Promise<string> {
	const response = await fetch(fileUrl(instance, path), {
		headers: { authorization: `Bearer ${instance.deviceToken}` }
	});
	if (!response.ok) throw new FeedApiError(kindForStatus(response.status), 'Could not load file.');
	const blob = await response.blob();
	return URL.createObjectURL(blob);
}
