import { createApiClient } from '$lib/api/client.js';
import { fail, guard } from '$lib/api/errors.js';
import type { components } from '$lib/api/schema.js';

export type GuestConfirmation = components['schemas']['GuestConfirmation']['data'];
export type GuestManageState = components['schemas']['GuestManageState']['data'];
export type GuestRsvpStatus = GuestManageState['rsvps'][number]['status'];
export type GuestCadence = GuestManageState['subscriptions'][number]['cadence'];

/**
 * These guest (tokenless) flows throw the shared `ApiError`. They never
 * carry a device token (ADR 0024) — the signed link/token in the URL is
 * the whole credential — and the server never issues 401/403 here, so the
 * `auth`/`forbidden` kinds never arise: an invalid, expired, or
 * already-used token is one neutral `not_found` (the API answers a single
 * 404 for all of those, never an oracle — see
 * `KammerWeb.Api.GuestController`), alongside the usual transport kinds.
 */
function client(baseUrl: string, manageToken?: string) {
	return createApiClient(baseUrl, manageToken);
}

export async function confirmGuestRsvp(baseUrl: string, token: string): Promise<GuestConfirmation> {
	return guard(async () => {
		const { data, error, response } = await client(baseUrl).POST('/api/v1/guest/rsvp/confirm', {
			body: { token }
		});
		if (error || !data) throw fail(error, response, 'This link is no longer valid.');
		return data.data;
	});
}

export async function confirmGuestClaim(
	baseUrl: string,
	token: string
): Promise<GuestConfirmation> {
	return guard(async () => {
		const { data, error, response } = await client(baseUrl).POST('/api/v1/guest/claim/confirm', {
			body: { token }
		});
		if (error || !data) throw fail(error, response, 'This link is no longer valid.');
		return data.data;
	});
}

export async function confirmGuestComment(
	baseUrl: string,
	token: string
): Promise<GuestConfirmation> {
	return guard(async () => {
		const { data, error, response } = await client(baseUrl).POST('/api/v1/guest/comment/confirm', {
			body: { token }
		});
		if (error || !data) throw fail(error, response, 'This link is no longer valid.');
		return data.data;
	});
}

// The management token is long-lived (unlike the single-use confirm
// tokens above), so it travels in the `Authorization: Bearer` header
// instead of a URL path segment (issue #230, ADR 0026) — a path segment
// would leak it into access logs, proxy logs, browser history, and
// `Referer`. `client(baseUrl, token)` sets the header; none of the
// `/guest/manage` paths below carry a `{token}` segment.

export async function fetchGuestManageState(
	baseUrl: string,
	token: string
): Promise<GuestManageState> {
	return guard(async () => {
		const { data, error, response } = await client(baseUrl, token).GET('/api/v1/guest/manage');
		if (error || !data) throw fail(error, response, 'This link is no longer valid.');
		return data.data;
	});
}

export async function setGuestRsvp(
	baseUrl: string,
	token: string,
	eventId: string,
	status: GuestRsvpStatus
): Promise<GuestManageState> {
	return guard(async () => {
		const { data, error, response } = await client(baseUrl, token).PUT(
			'/api/v1/guest/manage/rsvps/{event_id}',
			{ params: { path: { event_id: eventId } }, body: { status } }
		);
		if (error || !data) throw fail(error, response, 'Could not update your RSVP.');
		return data.data;
	});
}

export async function releaseGuestClaim(
	baseUrl: string,
	token: string,
	claimId: string
): Promise<GuestManageState> {
	return guard(async () => {
		const { data, error, response } = await client(baseUrl, token).DELETE(
			'/api/v1/guest/manage/claims/{claim_id}',
			{ params: { path: { claim_id: claimId } } }
		);
		if (error || !data) throw fail(error, response, 'Could not release this signup.');
		return data.data;
	});
}

export async function setGuestCadence(
	baseUrl: string,
	token: string,
	subscriptionId: string,
	cadence: GuestCadence
): Promise<GuestManageState> {
	return guard(async () => {
		const { data, error, response } = await client(baseUrl, token).PUT(
			'/api/v1/guest/manage/subscriptions/{subscription_id}',
			{ params: { path: { subscription_id: subscriptionId } }, body: { cadence } }
		);
		if (error || !data) throw fail(error, response, 'Could not update this subscription.');
		return data.data;
	});
}

export async function unsubscribeGuest(
	baseUrl: string,
	token: string,
	subscriptionId: string
): Promise<GuestManageState> {
	return guard(async () => {
		const { data, error, response } = await client(baseUrl, token).DELETE(
			'/api/v1/guest/manage/subscriptions/{subscription_id}',
			{ params: { path: { subscription_id: subscriptionId } } }
		);
		if (error || !data) throw fail(error, response, 'Could not unsubscribe.');
		return data.data;
	});
}

export async function eraseGuest(baseUrl: string, token: string): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(baseUrl, token).DELETE('/api/v1/guest/manage');
		if (error) throw fail(error, response, 'Could not erase your data.');
	});
}
