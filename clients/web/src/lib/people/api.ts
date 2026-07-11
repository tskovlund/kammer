import { createApiClient } from '$lib/api/client.js';
import { fail, guard } from '$lib/api/errors.js';
import type { Instance } from '$lib/instances/types.js';
import type {
	Device,
	Invite,
	NotificationLevel,
	NotificationLevelValue,
	Profile,
	ProfileParams,
	Role,
	Roster
} from './types.js';

function client(instance: Instance) {
	return createApiClient(instance.baseUrl, instance.deviceToken);
}

interface GroupRef {
	community: string;
	group: string;
}

/**
 * The roster's filter map (`field id → required value`) as the flat
 * `filter[<id>]=<value>` query pairs Phoenix parses into a nested map.
 * Empty values mean "no filter on this field" and are dropped; an empty
 * result means no query at all.
 */
export function rosterFilterQuery(
	filter: Record<string, string>
): Record<string, string> | undefined {
	const entries = Object.entries(filter).filter(([, value]) => value !== '');
	if (entries.length === 0) return undefined;
	return Object.fromEntries(entries.map(([fieldId, value]) => [`filter[${fieldId}]`, value]));
}

/** The member directory, redacted server-side for the caller's role. */
export async function fetchRoster(
	instance: Instance,
	communitySlug: string,
	filter: Record<string, string> = {}
): Promise<Roster> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET(
			'/api/v1/communities/{community_slug}/members',
			{
				params: {
					path: { community_slug: communitySlug },
					// The generated type says `filter?: string`; the server
					// actually reads `filter[<field_id>]` pairs — serialize
					// them as flat keys the router nests back together.
					query: rosterFilterQuery(filter) as { filter?: string } | undefined
				}
			}
		);
		if (error || !data) throw fail(error, response, 'Could not load the members.');
		return { members: data.data, fields: data.fields };
	});
}

export async function updateMemberRole(
	instance: Instance,
	communitySlug: string,
	userId: string,
	role: Role
): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(instance).PUT(
			'/api/v1/communities/{community_slug}/members/{user_id}/role',
			{
				params: { path: { community_slug: communitySlug, user_id: userId } },
				body: { role }
			}
		);
		if (error) throw fail(error, response, 'Could not change that role.');
	});
}

export async function removeMember(
	instance: Instance,
	communitySlug: string,
	userId: string
): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(instance).DELETE(
			'/api/v1/communities/{community_slug}/members/{user_id}',
			{ params: { path: { community_slug: communitySlug, user_id: userId } } }
		);
		if (error) throw fail(error, response, 'Could not remove that member.');
	});
}

export async function fetchInvites(instance: Instance, communitySlug: string): Promise<Invite[]> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET(
			'/api/v1/communities/{community_slug}/invites',
			{ params: { path: { community_slug: communitySlug } } }
		);
		if (error || !data) throw fail(error, response, 'Could not load the invites.');
		return data.data;
	});
}

export async function createInvite(
	instance: Instance,
	communitySlug: string,
	params: { invited_email?: string; max_uses?: number } = {}
): Promise<Invite> {
	return guard(async () => {
		const { data, error, response } = await client(instance).POST(
			'/api/v1/communities/{community_slug}/invites',
			{
				params: { path: { community_slug: communitySlug } },
				body: params
			}
		);
		if (error || !data) throw fail(error, response, 'Could not create that invite.');
		return data.data;
	});
}

export async function revokeInvite(
	instance: Instance,
	communitySlug: string,
	inviteId: string
): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(instance).DELETE(
			'/api/v1/communities/{community_slug}/invites/{invite_id}',
			{ params: { path: { community_slug: communitySlug, invite_id: inviteId } } }
		);
		if (error) throw fail(error, response, 'Could not revoke that invite.');
	});
}

/** The web-served accept URL an invite token opens — what admins share. */
export function inviteUrl(instance: Instance, invite: Invite): string {
	return `${instance.baseUrl.replace(/\/$/, '')}/invite/${invite.token}`;
}

export async function fetchProfile(instance: Instance): Promise<Profile> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET('/api/v1/me');
		if (error || !data) throw fail(error, response, 'Could not load your profile.');
		return data.data;
	});
}

export async function updateProfile(instance: Instance, params: ProfileParams): Promise<Profile> {
	return guard(async () => {
		const { data, error, response } = await client(instance).PUT('/api/v1/me', {
			body: params
		});
		if (error || !data) throw fail(error, response, 'Could not save your profile.');
		return data.data;
	});
}

export async function fetchDevices(instance: Instance): Promise<Device[]> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET('/api/v1/me/devices');
		if (error || !data) throw fail(error, response, 'Could not load your devices.');
		return data.data;
	});
}

export async function revokeDevice(instance: Instance, deviceId: string): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(instance).DELETE('/api/v1/me/devices/{device_id}', {
			params: { path: { device_id: deviceId } }
		});
		if (error) throw fail(error, response, 'Could not revoke that device.');
	});
}

export async function fetchNotificationLevel(
	instance: Instance,
	ref: GroupRef
): Promise<NotificationLevel> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/notification-level',
			{ params: { path: { community_slug: ref.community, group_slug: ref.group } } }
		);
		if (error || !data) throw fail(error, response, 'Could not load notification settings.');
		return data.data;
	});
}

export async function setNotificationLevel(
	instance: Instance,
	ref: GroupRef,
	level: NotificationLevelValue
): Promise<NotificationLevel> {
	return guard(async () => {
		const { data, error, response } = await client(instance).PUT(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/notification-level',
			{
				params: { path: { community_slug: ref.community, group_slug: ref.group } },
				body: { level }
			}
		);
		if (error || !data) throw fail(error, response, 'Could not save notification settings.');
		return data.data;
	});
}

/** Join per the group's policy; resolves to the membership outcome. */
export async function joinGroup(
	instance: Instance,
	ref: GroupRef
): Promise<'joined' | 'requested'> {
	return guard(async () => {
		const { data, error, response } = await client(instance).PUT(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/membership',
			{ params: { path: { community_slug: ref.community, group_slug: ref.group } } }
		);
		if (error || !data) throw fail(error, response, 'Could not join this group.');
		return data.status === 'requested' ? 'requested' : 'joined';
	});
}

export async function leaveGroup(instance: Instance, ref: GroupRef): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(instance).DELETE(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/membership',
			{ params: { path: { community_slug: ref.community, group_slug: ref.group } } }
		);
		if (error) throw fail(error, response, 'Could not leave this group.');
	});
}
