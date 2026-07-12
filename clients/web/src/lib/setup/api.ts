import { createApiClient } from '$lib/api/client.js';
import { fail, guard } from '$lib/api/errors.js';
import type { components } from '$lib/api/schema.js';

export type SetupResult = components['schemas']['SetupResult']['data'];

// First-run setup errors through the shared `ApiError` (#270). It carries a
// one-shot setup token, not a device token, so there is no `auth` kind — a
// bad or already-consumed token comes back as a neutral `forbidden` (see
// `completeSetup`).

/** Whether first-run setup has already completed (SPEC §13). */
export async function fetchSetupStatus(baseUrl: string): Promise<boolean> {
	return guard(async () => {
		const { data, error, response } = await createApiClient(baseUrl).GET('/api/v1/setup');
		if (error || !data) throw fail(error, response, 'Could not check setup status.');
		return data.setup_completed;
	});
}

export interface CompleteSetupInput {
	token: string;
	operator: { email: string; display_name?: string | null };
	instance: {
		instance_name?: string | null;
		default_locale?: 'en' | 'da' | null;
		community_creation_policy?: 'operators_only' | 'any_user' | null;
	};
	community: { name: string; slug: string; accent_color?: string | null };
	group: { name: string; slug: string };
	demo_data?: boolean | null;
}

/**
 * Completes first-run setup: operator, instance settings, first community
 * and group. There is deliberately no separate token-check endpoint
 * (issue #230) — a boolean oracle over the setup credential — so the
 * setup token rides this same call and is validated server-side on every
 * submission; a bad or already-consumed token comes back as a neutral
 * `forbidden` (403), never a pre-flight yes/no.
 */
export async function completeSetup(
	baseUrl: string,
	input: CompleteSetupInput
): Promise<SetupResult> {
	return guard(async () => {
		const { data, error, response } = await createApiClient(baseUrl).POST('/api/v1/setup', {
			body: input
		});
		if (error || !data)
			throw fail(error, response, 'Setup failed — check the values and try again.');
		return data.data;
	});
}
