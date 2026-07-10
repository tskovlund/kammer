import { createApiClient } from '$lib/api/client.js';
import type { components } from '$lib/api/schema.js';

export type NewsletterConfirmation = components['schemas']['GuestConfirmation']['data'];

/**
 * Tokenless like `$lib/guest/api.ts` (ADR 0024) — the confirm token is the
 * only credential, so an invalid/expired/used one is one neutral 404,
 * never a distinct `auth`/`forbidden` kind. Kept as its own small module
 * per this codebase's convention (each API module carries its own error
 * plumbing — see `$lib/manage/api.ts`), since newsletter confirmation is a
 * distinct client surface from the guest RSVP/claim/comment flows even
 * though the response shape happens to match `GuestConfirmation`.
 */
export type NewsletterErrorKind =
	'not_found' | 'validation' | 'rate_limited' | 'network' | 'server';

export class NewsletterApiError extends Error {
	readonly kind: NewsletterErrorKind;
	readonly status: number | null;

	constructor(kind: NewsletterErrorKind, message: string, status: number | null = null) {
		super(message);
		this.name = 'NewsletterApiError';
		this.kind = kind;
		this.status = status;
	}
}

function kindForStatus(status: number): NewsletterErrorKind {
	switch (status) {
		case 404:
			return 'not_found';
		case 400:
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

function fail(
	error: unknown,
	response: Response | undefined,
	fallback: string
): NewsletterApiError {
	const status = response?.status ?? null;
	const kind = status ? kindForStatus(status) : 'server';
	return new NewsletterApiError(kind, messageFrom(error, fallback), status);
}

export async function confirmNewsletterSubscription(
	baseUrl: string,
	token: string
): Promise<NewsletterConfirmation> {
	try {
		const { data, error, response } = await createApiClient(baseUrl).POST(
			'/api/v1/newsletter/confirm',
			{ body: { token } }
		);
		if (error || !data) throw fail(error, response, 'This link is no longer valid.');
		return data.data;
	} catch (cause) {
		if (cause instanceof NewsletterApiError) throw cause;
		throw new NewsletterApiError('network', 'Could not reach this community.', null);
	}
}
