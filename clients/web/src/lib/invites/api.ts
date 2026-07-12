import { resolve } from '$app/paths';
import { createApiClient } from '$lib/api/client.js';
import { fail, guard } from '$lib/api/errors.js';
import type { components } from '$lib/api/schema.js';
import type { Instance } from '$lib/instances/types.js';

export type InvitePreview = components['schemas']['InvitePreview'];
export type InviteAccept = components['schemas']['InviteAcceptResponse'];

/**
 * The invite endpoints (issue #255, the client twin of
 * `KammerWeb.Api.InviteController`), erroring through the shared
 * `ApiError` machinery. What the kinds mean HERE: the server
 * deliberately collapses revoked, expired, used-up, and unknown tokens
 * into one neutral 404 — so `not_found` reads as "this invitation is no
 * longer valid" — and `forbidden` is the accept endpoint's only
 * distinguishable refusal: the invite is bound to a different email.
 */

/**
 * Public invite preview — the token is the credential, no device token.
 * `baseUrl` is the origin serving the invite landing page: invite links
 * are instance-served, same trust model as the deep-link sign-in route.
 */
export async function fetchInvitePreview(baseUrl: string, token: string): Promise<InvitePreview> {
	return guard(async () => {
		const client = createApiClient(baseUrl);
		const { data, error, response } = await client.GET('/api/v1/invites/{token}', {
			params: { path: { token } }
		});
		if (error || !data) throw fail(error, response, 'This invitation is no longer valid.');
		return data.data;
	});
}

/** Accept as the signed-in user: join the community (and group, if any). */
export async function acceptInvite(instance: Instance, token: string): Promise<InviteAccept> {
	return guard(async () => {
		const client = createApiClient(instance.baseUrl, instance.deviceToken);
		const { data, error, response } = await client.POST('/api/v1/invites/{token}/accept', {
			params: { path: { token } }
		});
		if (error || !data) throw fail(error, response, 'Could not accept this invitation.');
		return data.data;
	});
}

/**
 * Where a just-accepted invite lands. When the community requires
 * profile fields the newcomer hasn't answered, the profile page comes
 * first — the server includes `missing_required_fields` precisely so
 * the client collects them next (the LiveView flow's complete-profile
 * step; the profile page shows the missing-required nag). Otherwise:
 * the group's feed for a group invite; the Groups tab for a
 * community-wide one — the PWA has no community landing page
 * (community-first navigation, ADR 0024, merges communities into the
 * tabs), and the Groups tab is where the newly joined community's
 * directory shows up.
 */
export function joinedHref(instanceId: string, accepted: InviteAccept): string {
	if (accepted.missing_required_fields.length > 0) {
		return resolve(`/you/${instanceId}/profile`);
	}
	if (!accepted.group) return resolve('/groups');
	return resolve(`/i/${instanceId}/c/${accepted.community.slug}/g/${accepted.group.slug}`);
}
