import { createApiClient } from '$lib/api/client.js';
import { fail, guard } from '$lib/api/errors.js';
import type { components } from '$lib/api/schema.js';
import type { Instance } from '$lib/instances/types.js';

/**
 * Community creation over the API (issue #259, part of #187). Who may
 * create is the instance's own policy (SPEC §3: operators only / any
 * user) — the server decides and answers 403 when refused; the client
 * gates its entry point on the `can_create_community` capability the
 * instance doc reports rather than guessing the policy.
 *
 * Shares the feed's typed-error machinery (`$lib/api/errors`) so a 422's
 * changeset `details` reach the form the same way registration's do.
 */

export type Community = components['schemas']['Community'];
export type CommunityParams = components['schemas']['CommunityParams'];

function client(instance: Instance) {
	return createApiClient(instance.baseUrl, instance.deviceToken);
}

/**
 * Whether this instance's user may create a community — the per-viewer
 * capability from the instance doc, sent with the device token so the
 * answer is for this account, not the anonymous probe. Best-effort:
 * `false`, never a thrown error, when the instance can't answer, so a
 * hidden entry point never becomes a broken tab.
 */
export async function fetchCommunityCreationCapability(instance: Instance): Promise<boolean> {
	try {
		const { data } = await client(instance).GET('/api/v1/instance');
		return data?.can_create_community ?? false;
	} catch {
		return false;
	}
}

/** Creates a community; the caller becomes its owner. */
export async function createCommunity(
	instance: Instance,
	params: CommunityParams
): Promise<Community> {
	return guard(async () => {
		const { data, error, response } = await client(instance).POST('/api/v1/communities', {
			body: params
		});
		if (error || !data) throw fail(error, response, 'Could not create the community.');
		return data.data;
	});
}
