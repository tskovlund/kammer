import { createApiClient } from '$lib/api/client.js';
import { ApiError, fail, guard } from '$lib/api/errors.js';
import type { Instance } from './types.js';
import { getPasskeyAssertion, isPasskeySupported, sameOriginInstance } from './webauthn.js';

/**
 * The client half of step-up re-auth (issue #294, ADR 0029). A
 * credential-changing endpoint answers 401 `step_up_required` when the
 * calling device token hasn't recently re-asserted a root of trust;
 * `StepUpModal` then runs one of the two ceremonies here — a passkey
 * assertion, or an emailed confirmation link — and the caller retries
 * its original action (the elevation lives server-side, on the device
 * token row, so the retry simply succeeds).
 */

/** Whether a caught error is the #294 gate asking for a step-up. */
export function isStepUpRequired(cause: unknown): boolean {
	return cause instanceof ApiError && cause.kind === 'step_up';
}

/**
 * Whether the passkey method is even worth offering: the browser must
 * support assertions and the instance must be served from this very
 * origin (WebAuthn's rp_id binding — same gate as sign-in and
 * enrollment). Whether the ACCOUNT has passkeys only the challenge
 * knows; `performPasskeyStepUp` reports that as a plain failure.
 */
export function canStepUpWithPasskey(instance: Instance): boolean {
	return isPasskeySupported() && sameOriginInstance(instance.baseUrl);
}

/**
 * Runs the whole passkey step-up ceremony: challenge → browser
 * assertion → verify. Resolves to `'stepped_up'`, or `'cancelled'`
 * when the browser produced no credential (a dismissed prompt is a
 * deliberate cancel, not a failure). Throws on everything else —
 * including an account with no passkeys, whose empty `allow_credentials`
 * can only end in a failed or dismissed prompt. Prompt-dismissal
 * exceptions (NotAllowedError/AbortError) also read as `'cancelled'`,
 * matching the enrollment flow's stance.
 */
export async function performPasskeyStepUp(
	instance: Instance
): Promise<'stepped_up' | 'cancelled'> {
	const client = createApiClient(instance.baseUrl, instance.deviceToken);

	const challenge = await guard(async () => {
		const { data, error, response } = await client.POST('/api/v1/auth/step-up/passkey/challenge');
		if (error || !data) throw fail(error, response, 'Could not start the confirmation.');
		return data.data;
	});

	let assertion;
	try {
		assertion = await getPasskeyAssertion(
			challenge.challenge,
			challenge.rp_id,
			challenge.allow_credentials
		);
	} catch (cause) {
		if (isUserCancellation(cause)) return 'cancelled';
		throw cause;
	}
	if (!assertion) return 'cancelled';

	await guard(async () => {
		const { error, response } = await client.POST('/api/v1/auth/step-up/passkey/verify', {
			body: { challenge_token: challenge.challenge_token, ...assertion }
		});
		// The server's one neutral 422 — never a hint at which step failed.
		if (error) throw fail(error, response, 'Could not confirm it.');
	});

	return 'stepped_up';
}

/**
 * Emails the account's own address a single-use confirmation link
 * bound to this device. Rate-limited server-side with the sign-in
 * email budget, so a `rate_limited` ApiError is a real possibility
 * the UI must word for.
 */
export async function requestStepUpLink(instance: Instance): Promise<void> {
	return guard(async () => {
		const client = createApiClient(instance.baseUrl, instance.deviceToken);
		const { error, response } = await client.POST('/api/v1/auth/step-up/request-link');
		if (error) throw fail(error, response, 'Could not send the confirmation link.');
	});
}

/**
 * Consumes an emailed step-up token — the `/step-up/{token}` landing
 * page's call. Public and instance-relative: the link may be opened in
 * a browser holding no signed-in instance at all, so `baseUrl` is the
 * page's own origin (the emailed link always points at the instance
 * that sent it), and no Bearer is attached.
 */
export async function confirmStepUp(baseUrl: string, token: string): Promise<void> {
	return guard(async () => {
		const client = createApiClient(baseUrl);
		const { error, response } = await client.POST('/api/v1/auth/step-up/confirm', {
			body: { token }
		});
		if (error) throw fail(error, response, 'That confirmation link is invalid or has expired.');
	});
}

/**
 * A WebAuthn prompt the user dismissed throws NotAllowedError (or
 * AbortError on timeout) — a deliberate cancel, not a failure. Shared
 * with the devices page's enrollment flow, which applies the same rule.
 */
export function isUserCancellation(cause: unknown): boolean {
	const name = (cause as { name?: string } | null)?.name;
	return name === 'NotAllowedError' || name === 'AbortError';
}
