import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
	beginPasskeyRegistration,
	completePasskeyRegistration,
	deletePasskey,
	fetchPasskeys,
	inviteParamsErrorKeys,
	profileParamsErrorKeys
} from './api.js';
import { ApiError } from '$lib/api/errors.js';
import type { Instance } from '$lib/instances/types.js';

function jsonResponse(body: unknown, status = 200) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

function fixture(overrides: Partial<Instance> = {}): Instance {
	return {
		id: 'instance-1',
		baseUrl: 'https://kammer.example.com',
		instanceName: 'Example',
		deviceToken: 'token-1',
		user: { id: 'user-1', email: 'a@example.com', displayName: 'Alice' },
		addedAt: '2026-01-01T00:00:00Z',
		...overrides
	};
}

beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
afterEach(() => vi.unstubAllGlobals());

describe('passkey enrollment', () => {
	it('begins registration against the challenge endpoint and returns the options', async () => {
		const challenge = {
			challenge: 'chal',
			rp_id: 'kammer.example.com',
			challenge_token: 'token',
			user_id: 'AQID',
			user_name: 'a@example.com',
			user_display_name: 'Alice',
			exclude_credentials: []
		};
		vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ data: challenge }));

		await expect(beginPasskeyRegistration(fixture())).resolves.toEqual(challenge);
		const [request] = vi.mocked(fetch).mock.calls[0] as [Request];
		expect(request.method).toBe('POST');
		expect(request.url).toBe('https://kammer.example.com/api/v1/me/passkeys/challenge');
	});

	it('completes registration by posting the attestation and returns the stored passkey', async () => {
		const passkey = {
			id: 'passkey-1',
			nickname: 'My phone',
			created_at: '2026-01-02T00:00:00Z',
			last_used_at: null
		};
		vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ data: passkey }, 201));

		const body = {
			challenge_token: 'token',
			attestation_object: 'AQID',
			client_data_json: 'BAU',
			nickname: 'My phone'
		};
		await expect(completePasskeyRegistration(fixture(), body)).resolves.toEqual(passkey);
		const [request] = vi.mocked(fetch).mock.calls[0] as [Request];
		expect(request.url).toBe('https://kammer.example.com/api/v1/me/passkeys');
		expect(await request.json()).toEqual(body);
	});

	it('surfaces the server-neutral 422 as a validation error, not the raw message', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({ error: { code: 'invalid_params', message: 'Could not register.' } }, 422)
		);

		await expect(
			completePasskeyRegistration(fixture(), {
				challenge_token: 't',
				attestation_object: 'a',
				client_data_json: 'c'
			})
		).rejects.toMatchObject({ kind: 'validation', status: 422 });
	});
});

describe('fetchPasskeys', () => {
	it('lists the caller passkeys', async () => {
		const passkeys = [
			{ id: 'p1', nickname: null, created_at: '2026-01-01T00:00:00Z', last_used_at: null }
		];
		vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ data: passkeys }));

		await expect(fetchPasskeys(fixture())).resolves.toEqual(passkeys);
		const [request] = vi.mocked(fetch).mock.calls[0] as [Request];
		expect(request.url).toBe('https://kammer.example.com/api/v1/me/passkeys');
	});
});

describe('deletePasskey', () => {
	it('deletes by id against the scoped endpoint', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ status: 'revoked' }));

		await expect(deletePasskey(fixture(), 'passkey-1')).resolves.toBeUndefined();
		const [request] = vi.mocked(fetch).mock.calls[0] as [Request];
		expect(request.method).toBe('DELETE');
		expect(request.url).toBe('https://kammer.example.com/api/v1/me/passkeys/passkey-1');
	});
});

function validation(details: Record<string, string[]>): ApiError {
	return new ApiError('validation', 'Validation failed.', 422, details);
}

describe('inviteParamsErrorKeys', () => {
	it('routes an invited_email 422 onto its key and suppresses the banner', () => {
		expect(inviteParamsErrorKeys(validation({ invited_email: ['has invalid format'] }))).toEqual({
			invitedEmailKey: 'invites.error.email',
			bannerKind: null
		});
	});

	it('falls back to the banner kind for unmapped 422s and other failures', () => {
		expect(inviteParamsErrorKeys(validation({})).bannerKind).toBe('validation');
		expect(inviteParamsErrorKeys(new Error('boom')).bannerKind).toBe('server');
	});
});

describe('profileParamsErrorKeys', () => {
	it('routes display_name/pronouns 422 details onto their keys and suppresses the banner', () => {
		expect(
			profileParamsErrorKeys(validation({ display_name: ['blank'], pronouns: ['too long'] }))
		).toEqual({
			displayNameKey: 'profile.error.displayName',
			pronounsKey: 'profile.error.pronouns',
			bannerKey: null
		});
	});

	it('keeps the Select-field-specific banner copy when no mapped field matched', () => {
		// A `timezone` 422 (unreachable through the Select, but the server can
		// still name it) keeps its specific copy rather than the generic one.
		expect(profileParamsErrorKeys(validation({ timezone: ['is not a known time zone'] }))).toEqual({
			displayNameKey: null,
			pronounsKey: null,
			bannerKey: 'profile.error.timezone'
		});
	});

	it('falls back to a generic validation banner, then the body copy for a non-validation failure', () => {
		expect(profileParamsErrorKeys(validation({})).bannerKey).toBe('profile.error.validation');
		expect(profileParamsErrorKeys(new Error('boom')).bannerKey).toBe('profile.error.body');
	});
});
