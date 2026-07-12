import { createApiClient } from '$lib/api/client.js';
import { FeedApiError } from '$lib/api/errors.js';
import type { components } from '$lib/api/schema.js';
import type { Instance } from '$lib/instances/types.js';

/**
 * The management surface over the API (issue #183): moderation queue and
 * bans, community/group settings, invite issuance, and instance-operator
 * settings. Every screen consumes `viewer_can` to decide whether to show
 * the controls, but the server is the enforcer — these calls surface the
 * same typed errors the feed does, so a `forbidden` from a stale
 * capability list degrades gracefully.
 *
 * Error plumbing mirrors `$lib/feed/api.ts` (each API module carries its
 * own, per this codebase's convention) so callers get a stable
 * `{ kind, status }` shape without importing the feed.
 */

export type Report = components['schemas']['Report'];
export type JoinRequest = components['schemas']['JoinRequest'];
export type Ban = components['schemas']['Ban'];
export type AuditEvent = components['schemas']['AuditEvent'];
export type InstanceSettings = components['schemas']['InstanceSettings'];
export type Community = components['schemas']['Community'];
export type Group = components['schemas']['Group'];
export type CommunityParams = components['schemas']['CommunityParams'];
export type CustomField = components['schemas']['CustomField'];
export type CustomFieldParams = components['schemas']['CustomFieldParams'];
export type GroupParams = components['schemas']['GroupParams'];
export type InstanceSettingsParams = components['schemas']['InstanceSettingsParams'];
export type GroupFeature = NonNullable<
	components['schemas']['GroupFeaturesParams']['features']
>[number];

export type ManageErrorKind =
	'auth' | 'forbidden' | 'not_found' | 'validation' | 'rate_limited' | 'network' | 'server';

export class ManageApiError extends Error {
	readonly kind: ManageErrorKind;
	readonly status: number | null;
	/**
	 * Field → messages from a 422's changeset details, `{}` otherwise.
	 * A settings form maps field NAMES onto its own i18n copy — the
	 * server message strings are English and must never render (#253).
	 */
	readonly details: Record<string, string[]>;

	constructor(
		kind: ManageErrorKind,
		message: string,
		status: number | null = null,
		details: Record<string, string[]> = {}
	) {
		super(message);
		this.name = 'ManageApiError';
		this.kind = kind;
		this.status = status;
		this.details = details;
	}
}

/**
 * Classifies a load-path failure that may come from either error family:
 * manage pages routinely pair a feed-family fetch (`fetchCommunity`/
 * `fetchGroup`, which throw `FeedApiError`) with manage calls. Collapses
 * to a `ManageErrorKind` so a page keys its error states off one union
 * (`too_large` can't occur on a read and maps to `server`). Extracted
 * after the fourth per-page copy (#271's pattern, then #259 slice C).
 */
export function loadErrorKind(cause: unknown): ManageErrorKind {
	if (cause instanceof ManageApiError) return cause.kind;
	if (cause instanceof FeedApiError && cause.kind !== 'too_large') return cause.kind;
	return 'server';
}

function kindForStatus(status: number): ManageErrorKind {
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
	error?: { code?: string; message?: string; details?: Record<string, string[]> };
}

function messageFrom(error: unknown, fallback: string): string {
	const envelope = error as ErrorEnvelope | undefined;
	return envelope?.error?.message ?? fallback;
}

function client(instance: Instance) {
	return createApiClient(instance.baseUrl, instance.deviceToken);
}

function fail(error: unknown, response: Response | undefined, fallback: string): ManageApiError {
	const status = response?.status ?? null;
	const kind = status ? kindForStatus(status) : 'server';
	const details = (error as ErrorEnvelope | undefined)?.error?.details ?? {};
	return new ManageApiError(kind, messageFrom(error, fallback), status, details);
}

async function guard<T>(request: () => Promise<T>): Promise<T> {
	try {
		return await request();
	} catch (cause) {
		if (cause instanceof ManageApiError) throw cause;
		throw new ManageApiError('network', 'Could not reach this community.', null);
	}
}

// --- Moderation ------------------------------------------------------------

export async function fetchReports(instance: Instance, communitySlug: string): Promise<Report[]> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET(
			'/api/v1/communities/{community_slug}/moderation/reports',
			{ params: { path: { community_slug: communitySlug } } }
		);
		if (error || !data) throw fail(error, response, 'Could not load the report queue.');
		return data.data;
	});
}

export async function resolveReport(
	instance: Instance,
	communitySlug: string,
	reportId: string
): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(instance).POST(
			'/api/v1/communities/{community_slug}/moderation/reports/{report_id}/resolve',
			{ params: { path: { community_slug: communitySlug, report_id: reportId } } }
		);
		if (error) throw fail(error, response, 'Could not resolve this report.');
	});
}

export async function dismissReport(
	instance: Instance,
	communitySlug: string,
	reportId: string
): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(instance).POST(
			'/api/v1/communities/{community_slug}/moderation/reports/{report_id}/dismiss',
			{ params: { path: { community_slug: communitySlug, report_id: reportId } } }
		);
		if (error) throw fail(error, response, 'Could not dismiss this report.');
	});
}

export async function fetchBans(instance: Instance, communitySlug: string): Promise<Ban[]> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET(
			'/api/v1/communities/{community_slug}/moderation/bans',
			{ params: { path: { community_slug: communitySlug } } }
		);
		if (error || !data) throw fail(error, response, 'Could not load bans.');
		return data.data;
	});
}

/**
 * Bans a member by user id (SPEC §11): the server removes their
 * membership and records the ban against their email. Community admins
 * only; the server refuses admins/owners and self-bans, and answers
 * 422 with an `email` detail when that address is already banned.
 */
export async function createBan(
	instance: Instance,
	communitySlug: string,
	userId: string,
	reason: string | null = null
): Promise<Ban> {
	return guard(async () => {
		const { data, error, response } = await client(instance).POST(
			'/api/v1/communities/{community_slug}/moderation/bans',
			{
				params: { path: { community_slug: communitySlug } },
				body: { user_id: userId, reason }
			}
		);
		if (error || !data) throw fail(error, response, 'Could not ban this member.');
		return data.data;
	});
}

export async function liftBan(
	instance: Instance,
	communitySlug: string,
	banId: string
): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(instance).DELETE(
			'/api/v1/communities/{community_slug}/moderation/bans/{ban_id}',
			{ params: { path: { community_slug: communitySlug, ban_id: banId } } }
		);
		if (error) throw fail(error, response, 'Could not lift this ban.');
	});
}

export async function fetchAuditLog(
	instance: Instance,
	communitySlug: string
): Promise<AuditEvent[]> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET(
			'/api/v1/communities/{community_slug}/audit-log',
			{ params: { path: { community_slug: communitySlug } } }
		);
		if (error || !data) throw fail(error, response, 'Could not load the audit log.');
		return data.data;
	});
}

// --- Community settings -----------------------------------------------------

export async function updateCommunity(
	instance: Instance,
	communitySlug: string,
	params: CommunityParams
): Promise<Community> {
	return guard(async () => {
		const { data, error, response } = await client(instance).PUT(
			'/api/v1/communities/{community_slug}',
			{ params: { path: { community_slug: communitySlug } }, body: params }
		);
		if (error || !data) throw fail(error, response, 'Could not save the community settings.');
		return data.data;
	});
}

// --- Custom profile fields (issue #259, ADR 0020) ---------------------------

/** The community's custom profile-field definitions. Managers only. */
export async function fetchCustomFields(
	instance: Instance,
	communitySlug: string
): Promise<CustomField[]> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET(
			'/api/v1/communities/{community_slug}/custom-fields',
			{ params: { path: { community_slug: communitySlug } } }
		);
		if (error || !data) throw fail(error, response, 'Could not load the profile fields.');
		return data.data;
	});
}

/**
 * Adds a custom profile field. A `single_select` needs a non-empty
 * `options` list — the server answers 422 with an `options` (or `label`)
 * detail the form maps to its own copy.
 */
export async function createCustomField(
	instance: Instance,
	communitySlug: string,
	params: CustomFieldParams
): Promise<CustomField> {
	return guard(async () => {
		const { data, error, response } = await client(instance).POST(
			'/api/v1/communities/{community_slug}/custom-fields',
			{ params: { path: { community_slug: communitySlug } }, body: params }
		);
		if (error || !data) throw fail(error, response, 'Could not add this field.');
		return data.data;
	});
}

/**
 * Edits a field's label, visibility, or required flag — a partial
 * update, so pass only what changes. Type and options are fixed at
 * creation (changing them would orphan existing answers). Making a
 * field required after members have joined never locks anyone out; it
 * just starts nudging them to fill it in (ADR 0020). A 422's `label`
 * detail maps to the form's own copy.
 */
export async function updateCustomField(
	instance: Instance,
	communitySlug: string,
	fieldId: string,
	params: Partial<Pick<CustomField, 'label' | 'visibility' | 'required'>>
): Promise<CustomField> {
	return guard(async () => {
		const { data, error, response } = await client(instance).PUT(
			'/api/v1/communities/{community_slug}/custom-fields/{id}',
			{ params: { path: { community_slug: communitySlug, id: fieldId } }, body: params }
		);
		if (error || !data) throw fail(error, response, 'Could not update this field.');
		return data.data;
	});
}

/** Deletes a field and every member's answer to it. */
export async function deleteCustomField(
	instance: Instance,
	communitySlug: string,
	fieldId: string
): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(instance).DELETE(
			'/api/v1/communities/{community_slug}/custom-fields/{id}',
			{ params: { path: { community_slug: communitySlug, id: fieldId } } }
		);
		if (error) throw fail(error, response, 'Could not delete this field.');
	});
}

// --- Group management -------------------------------------------------------

/**
 * Creates a group in a community (issue #278) — the PWA's first
 * group-creation path (the LiveView's `group_live/new.ex` was the only
 * one before the #187 cut). The caller gates the affordance on its own
 * `viewer_can: create_group`; the server authorizes `:create_group` and
 * makes the creator the group's owner. New groups default to the
 * `[feed, events, files]` feature set server-side (SPEC §3).
 */
export async function createGroup(
	instance: Instance,
	communitySlug: string,
	params: GroupParams
): Promise<Group> {
	return guard(async () => {
		const { data, error, response } = await client(instance).POST(
			'/api/v1/communities/{community_slug}/groups',
			{ params: { path: { community_slug: communitySlug } }, body: params }
		);
		if (error || !data) throw fail(error, response, 'Could not create the group.');
		return data.data;
	});
}

export async function updateGroup(
	instance: Instance,
	communitySlug: string,
	groupSlug: string,
	params: GroupParams
): Promise<Group> {
	return guard(async () => {
		const { data, error, response } = await client(instance).PUT(
			'/api/v1/communities/{community_slug}/groups/{group_slug}',
			{ params: { path: { community_slug: communitySlug, group_slug: groupSlug } }, body: params }
		);
		if (error || !data) throw fail(error, response, 'Could not save the group settings.');
		return data.data;
	});
}

export async function setGroupFeatures(
	instance: Instance,
	communitySlug: string,
	groupSlug: string,
	features: GroupFeature[]
): Promise<Group> {
	return guard(async () => {
		const { data, error, response } = await client(instance).PUT(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/features',
			{
				params: { path: { community_slug: communitySlug, group_slug: groupSlug } },
				body: { features }
			}
		);
		if (error || !data) throw fail(error, response, 'Could not update the features.');
		return data.data;
	});
}

/**
 * Deletes a group and everything in it (SPEC §3): group owners, and
 * community admins — their sole power over sealed groups (ADR 0005).
 * The client gates its control on the `delete_group` capability.
 */
export async function deleteGroup(
	instance: Instance,
	communitySlug: string,
	groupSlug: string
): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(instance).DELETE(
			'/api/v1/communities/{community_slug}/groups/{group_slug}',
			{ params: { path: { community_slug: communitySlug, group_slug: groupSlug } } }
		);
		if (error) throw fail(error, response, 'Could not delete this group.');
	});
}

export async function setGroupArchived(
	instance: Instance,
	communitySlug: string,
	groupSlug: string,
	archived: boolean
): Promise<Group> {
	return guard(async () => {
		const path = { community_slug: communitySlug, group_slug: groupSlug };
		const call = archived
			? client(instance).PUT('/api/v1/communities/{community_slug}/groups/{group_slug}/archive', {
					params: { path }
				})
			: client(instance).DELETE(
					'/api/v1/communities/{community_slug}/groups/{group_slug}/archive',
					{ params: { path } }
				);
		const { data, error, response } = await call;
		if (error || !data) throw fail(error, response, 'Could not change the archive state.');
		return data.data;
	});
}

// --- Group join requests ----------------------------------------------------

export async function fetchJoinRequests(
	instance: Instance,
	communitySlug: string,
	groupSlug: string
): Promise<JoinRequest[]> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/join-requests',
			{ params: { path: { community_slug: communitySlug, group_slug: groupSlug } } }
		);
		if (error || !data) throw fail(error, response, 'Could not load the join requests.');
		return data.data;
	});
}

/** Approve a pending request, creating the membership (422 when banned). */
export async function approveJoinRequest(
	instance: Instance,
	communitySlug: string,
	groupSlug: string,
	requestId: string
): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(instance).PUT(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/join-requests/{request_id}/approval',
			{
				params: {
					path: { community_slug: communitySlug, group_slug: groupSlug, request_id: requestId }
				}
			}
		);
		if (error) throw fail(error, response, 'Could not approve this request.');
	});
}

export async function denyJoinRequest(
	instance: Instance,
	communitySlug: string,
	groupSlug: string,
	requestId: string
): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(instance).DELETE(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/join-requests/{request_id}',
			{
				params: {
					path: { community_slug: communitySlug, group_slug: groupSlug, request_id: requestId }
				}
			}
		);
		if (error) throw fail(error, response, 'Could not deny this request.');
	});
}

// --- Instance operator settings ---------------------------------------------

export async function fetchInstanceSettings(instance: Instance): Promise<InstanceSettings> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET('/api/v1/instance/settings');
		if (error || !data) throw fail(error, response, 'Could not load instance settings.');
		return data.data;
	});
}

export async function updateInstanceSettings(
	instance: Instance,
	params: InstanceSettingsParams
): Promise<InstanceSettings> {
	return guard(async () => {
		const { data, error, response } = await client(instance).PUT('/api/v1/instance/settings', {
			body: params
		});
		if (error || !data) throw fail(error, response, 'Could not save instance settings.');
		return data.data;
	});
}

// --- Instance-wide moderation (issue #259, SPEC §11) --------------------------

/** Active instance-wide email bans. Operators only — a 403 gates the page. */
export async function fetchInstanceBans(instance: Instance): Promise<Ban[]> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET(
			'/api/v1/instance/moderation/bans'
		);
		if (error || !data) throw fail(error, response, 'Could not load instance bans.');
		return data.data;
	});
}

/**
 * Bans an email instance-wide (SPEC §11): the server purges the
 * account's memberships everywhere and blocks rejoin on every
 * community. Keyed on the email itself — unlike the community ban's
 * user id — so an address without an account can be blocked too. The
 * server refuses self-bans, other operators, and community owners, and
 * answers 422 with an `email` detail when the address already carries
 * an instance ban.
 */
export async function createInstanceBan(
	instance: Instance,
	email: string,
	reason: string | null = null
): Promise<Ban> {
	return guard(async () => {
		const { data, error, response } = await client(instance).POST(
			'/api/v1/instance/moderation/bans',
			{ body: { email, reason } }
		);
		if (error || !data) throw fail(error, response, 'Could not ban this email.');
		return data.data;
	});
}

export async function liftInstanceBan(instance: Instance, banId: string): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(instance).DELETE(
			'/api/v1/instance/moderation/bans/{ban_id}',
			{ params: { path: { ban_id: banId } } }
		);
		if (error) throw fail(error, response, 'Could not lift this ban.');
	});
}

// --- Legal pages (issue #259, SPEC §13) ---------------------------------------

/**
 * Publishes a legal page's markdown, replacing the built-in template.
 * Operators only; a 422's `content_markdown` detail maps to the form's
 * own copy.
 */
export async function updateLegalPage(
	instance: Instance,
	key: 'privacy' | 'imprint',
	contentMarkdown: string
): Promise<components['schemas']['LegalPage']['data']> {
	return guard(async () => {
		const { data, error, response } = await client(instance).PUT('/api/v1/legal/{key}', {
			params: { path: { key } },
			body: { content_markdown: contentMarkdown }
		});
		if (error || !data) throw fail(error, response, 'Could not publish this page.');
		return data.data;
	});
}
