import { createApiClient } from '$lib/api/client.js';
import { fail, guard } from '$lib/api/errors.js';
import type { components } from '$lib/api/schema.js';

export type NewsletterConfirmation = components['schemas']['GuestConfirmation']['data'];

/**
 * Newsletter confirmation is tokenless like `$lib/guest/api.ts` (ADR 0024)
 * — the confirm token is the only credential, so an invalid/expired/used
 * one is one neutral `not_found`, never a distinct `auth`/`forbidden`
 * kind. Errors through the shared `ApiError` (#270); it stays its own
 * small module only because it is a distinct client surface from the guest
 * RSVP/claim/comment flows, even though the response shape happens to
 * match `GuestConfirmation`.
 */
export async function confirmNewsletterSubscription(
	baseUrl: string,
	token: string
): Promise<NewsletterConfirmation> {
	return guard(async () => {
		const { data, error, response } = await createApiClient(baseUrl).POST(
			'/api/v1/newsletter/confirm',
			{ body: { token } }
		);
		if (error || !data) throw fail(error, response, 'This link is no longer valid.');
		return data.data;
	});
}
