import { createApiClient } from '$lib/api/client.js';
import { fail, guard } from '$lib/api/errors.js';
import type { components } from '$lib/api/schema.js';

export type LegalPage = components['schemas']['LegalPage']['data'];
export type LegalPageKey = LegalPage['key'];

/**
 * Fetches a public legal page. Tokenless and unauthenticated (SPEC §13),
 * erroring through the shared `ApiError`: an unpublished or unknown key is
 * a neutral `not_found` (404), transport failures are `network`, and
 * anything else the server returns is `server`.
 */
export async function fetchLegalPage(baseUrl: string, key: string): Promise<LegalPage> {
	return guard(async () => {
		const { data, error, response } = await createApiClient(baseUrl).GET('/api/v1/legal/{key}', {
			params: { path: { key } }
		});
		if (error || !data) throw fail(error, response, "This page isn't available.");
		return data.data;
	});
}
