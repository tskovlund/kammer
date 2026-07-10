import { createApiClient } from '$lib/api/client.js';
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
export type Ban = components['schemas']['Ban'];
export type AuditEvent = components['schemas']['AuditEvent'];
export type InstanceSettings = components['schemas']['InstanceSettings'];
export type Community = components['schemas']['Community'];
export type Group = components['schemas']['Group'];
export type CommunityParams = components['schemas']['CommunityParams'];
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

	constructor(kind: ManageErrorKind, message: string, status: number | null = null) {
		super(message);
		this.name = 'ManageApiError';
		this.kind = kind;
		this.status = status;
	}
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
	error?: { code?: string; message?: string };
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
	return new ManageApiError(kind, messageFrom(error, fallback), status);
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

// --- Group management -------------------------------------------------------

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
