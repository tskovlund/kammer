import { createApiClient } from '$lib/api/client.js';
import { ApiError, errorKind, fail, guard, type ApiErrorKind } from '$lib/api/errors.js';
import { fetchAuthedObjectUrl } from '$lib/feed/api.js';
import type { MessageKey } from '$lib/i18n/format.js';
import type { Instance } from '$lib/instances/types.js';
import type {
	Device,
	Invite,
	NotificationLevel,
	NotificationLevelValue,
	Passkey,
	PasskeyRegistrationChallenge,
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

/** Active invites into a single group (issue #259). */
export async function fetchGroupInvites(instance: Instance, ref: GroupRef): Promise<Invite[]> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/invites',
			{ params: { path: { community_slug: ref.community, group_slug: ref.group } } }
		);
		if (error || !data) throw fail(error, response, 'Could not load the invites.');
		return data.data;
	});
}

/**
 * Creates a group invite: redeeming it joins the group (and the
 * community). `invited_email` delivers it and binds redemption to that
 * address.
 */
export async function createGroupInvite(
	instance: Instance,
	ref: GroupRef,
	params: { invited_email?: string; max_uses?: number } = {}
): Promise<Invite> {
	return guard(async () => {
		const { data, error, response } = await client(instance).POST(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/invites',
			{
				params: { path: { community_slug: ref.community, group_slug: ref.group } },
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

/**
 * Emails the new address a single-use confirmation link (issue #258).
 * Nothing changes until `/confirm-email/{token}` lands and confirms.
 */
export async function requestEmailChange(instance: Instance, email: string): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(instance).POST('/api/v1/me/email-change', {
			body: { email }
		});
		if (error) throw fail(error, response, 'Could not request the email change.');
	});
}

/**
 * Consumes the emailed token. Device tokens are bound to the address
 * they were issued under, so the server answers with a rotated
 * `device_token` for this device — the caller must persist it (every
 * other device signs out).
 */
export async function confirmEmailChange(
	instance: Instance,
	token: string
): Promise<{ profile: Profile; deviceToken: string }> {
	return guard(async () => {
		const { data, error, response } = await client(instance).POST(
			'/api/v1/me/email-change/confirm',
			{ body: { token } }
		);
		if (error || !data) throw fail(error, response, 'Could not confirm the email change.');
		return { profile: data.data, deviceToken: data.device_token };
	});
}

/**
 * Deletes the account (SPEC §12): the server requires the account's own
 * email typed back and answers 422 (`validation`) on a mismatch.
 */
export async function deleteAccount(instance: Instance, confirmEmail: string): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(instance).DELETE('/api/v1/me', {
			body: { confirm_email: confirmEmail }
		});
		if (error) throw fail(error, response, 'Could not delete the account.');
	});
}

/**
 * The GDPR export zip (SPEC §12) as an object URL for a download link —
 * the endpoint sits behind Bearer auth, so a plain `<a href>` can't
 * reach it. The caller must `URL.revokeObjectURL` it when done.
 */
export async function fetchAccountExportUrl(instance: Instance): Promise<string> {
	return guard(() => fetchAuthedObjectUrl(instance, '/api/v1/me/export'));
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

/** The caller's registered passkeys (ADR 0018, issue #260 port 5b). */
export async function fetchPasskeys(instance: Instance): Promise<Passkey[]> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET('/api/v1/me/passkeys');
		if (error || !data) throw fail(error, response, 'Could not load your passkeys.');
		return data.data;
	});
}

/**
 * Starts passkey enrollment: the server mints WebAuthn registration
 * options and a signed `challenge_token` that carries the ceremony state.
 * Feed the options to `createPasskey`, then hand the attestation (plus the
 * same token) to `completePasskeyRegistration`.
 */
export async function beginPasskeyRegistration(
	instance: Instance
): Promise<PasskeyRegistrationChallenge> {
	return guard(async () => {
		const { data, error, response } = await client(instance).POST('/api/v1/me/passkeys/challenge');
		if (error || !data) throw fail(error, response, 'Could not start passkey registration.');
		return data.data;
	});
}

/**
 * Finishes passkey enrollment: verifies the attestation against the
 * challenge and stores the credential, returning it. The server collapses
 * every failure into one neutral 422, so `fail` surfaces a generic
 * message with no oracle for which step went wrong.
 */
export async function completePasskeyRegistration(
	instance: Instance,
	body: {
		challenge_token: string;
		attestation_object: string;
		client_data_json: string;
		nickname?: string | null;
	}
): Promise<Passkey> {
	return guard(async () => {
		const { data, error, response } = await client(instance).POST('/api/v1/me/passkeys', {
			body
		});
		if (error || !data) throw fail(error, response, 'Could not register this passkey.');
		return data.data;
	});
}

export async function deletePasskey(instance: Instance, passkeyId: string): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(instance).DELETE('/api/v1/me/passkeys/{passkey_id}', {
			params: { path: { passkey_id: passkeyId } }
		});
		if (error) throw fail(error, response, 'Could not remove that passkey.');
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

// --- Invite email validation → i18n keys (#253 mechanism; #305) -------------
//
// A 422 from the invite create endpoints carries `details` (field → messages)
// keyed by the changeset field atoms of
// `Kammer.Invitations.Invite.create_changeset/2` — verified against that
// changeset: `invited_email` is the only field the email form's free-text
// control can make invalid (`max_uses` is fixed by the form, `expires_at` is
// never sent). Anything else resolves to `bannerKind` for the shared
// `ErrorBanner`. Server message strings never render — only our keys.

export interface InviteParamsErrors {
	invitedEmailKey: MessageKey | null;
	/** Fallback banner kind; null exactly when the field-level key was set. */
	bannerKind: ApiErrorKind | null;
}

/** Maps a failed invite create onto the email field's key or a banner kind. */
export function inviteParamsErrorKeys(cause: unknown): InviteParamsErrors {
	if (cause instanceof ApiError && cause.kind === 'validation') {
		const invitedEmailKey = cause.details.invited_email ? ('invites.error.email' as const) : null;
		return { invitedEmailKey, bannerKind: invitedEmailKey ? null : 'validation' };
	}
	return { invitedEmailKey: null, bannerKind: errorKind(cause) };
}

// --- Profile form validation → i18n keys (#253) -----------------------------
//
// A 422 from `PUT /api/v1/me` carries `details` (field → messages) from
// `Kammer.Accounts.User.settings_changeset/2` via `traverse_errors`, so its
// keys are the changeset field atoms — verified against that changeset:
// `display_name` (required, ≤100 chars) and `pronouns` (≤40 chars) are the
// free-text `Input` fields a control can trip, so they take per-field copy.
// `locale`/`timezone`/`digest_frequency` carry validations too, but their
// `Select`s can't reach an out-of-range value — those (and any unmapped field)
// resolve to a banner, keeping the existing field-specific banner copy where
// the server names one. Server message strings never render.

export interface ProfileParamsErrors {
	displayNameKey: MessageKey | null;
	pronounsKey: MessageKey | null;
	/** Banner copy; null exactly when a field-level key was set. */
	bannerKey: MessageKey | null;
}

/** Maps a failed profile save onto per-field keys plus a fallback banner key. */
export function profileParamsErrorKeys(cause: unknown): ProfileParamsErrors {
	if (cause instanceof ApiError && cause.kind === 'validation') {
		const displayNameKey = cause.details.display_name
			? ('profile.error.displayName' as const)
			: null;
		const pronounsKey = cause.details.pronouns ? ('profile.error.pronouns' as const) : null;
		if (displayNameKey || pronounsKey) {
			return { displayNameKey, pronounsKey, bannerKey: null };
		}
		// No mapped field matched: keep the Select-field-specific copy where the
		// server named one, else a generic validation banner.
		const bannerKey: MessageKey =
			(cause.details.timezone && 'profile.error.timezone') ||
			(cause.details.locale && 'profile.error.language') ||
			(cause.details.digest_frequency && 'profile.error.digest') ||
			'profile.error.validation';
		return { displayNameKey: null, pronounsKey: null, bannerKey };
	}
	return { displayNameKey: null, pronounsKey: null, bannerKey: 'profile.error.body' };
}
