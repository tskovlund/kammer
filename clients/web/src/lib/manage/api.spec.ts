import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
	communityParamsErrorKeys,
	createBan,
	createCustomField,
	createGroup,
	createInstanceBan,
	denyJoinRequest,
	fetchJoinRequests,
	fetchReports,
	groupParamsErrorKeys,
	updateCustomField,
	updateLegalPage
} from './api';
import { ApiError } from '$lib/api/errors';
import type { Instance } from '$lib/instances/types';

function instance(): Instance {
	return {
		id: 'i1',
		baseUrl: 'https://kammer.example.com',
		instanceName: 'Example',
		deviceToken: 'token-1',
		user: { id: 'u1', email: 'a@example.com', displayName: 'Alice' },
		addedAt: '2026-01-01T00:00:00Z'
	};
}

function jsonResponse(status: number, body: unknown) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

describe('manage api', () => {
	beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
	afterEach(() => vi.unstubAllGlobals());

	it('unwraps the data envelope for the report queue', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse(200, { data: [{ id: 'r1', reason: 'spam', status: 'open' }] })
		);
		const reports = await fetchReports(instance(), 'my-community');
		expect(reports).toHaveLength(1);
		expect(reports[0]?.id).toBe('r1');
	});

	it('unwraps pending join requests from the data envelope', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse(200, {
				data: [{ id: 'jr1', user: { id: 'u9', display_name: 'Nora' }, requested_at: 'now' }]
			})
		);
		const requests = await fetchJoinRequests(instance(), 'my-community', 'crew');
		expect(requests[0]?.user.display_name).toBe('Nora');
	});

	it('denies a request with a DELETE to the request path — not approve’s verb or URL', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(new Response(null, { status: 204 }));
		await expect(
			denyJoinRequest(instance(), 'my-community', 'crew', 'jr1')
		).resolves.toBeUndefined();

		// Distinguishes deny from approve: a DELETE on the request itself,
		// never a PUT to its /approval sub-resource. A mis-wire to approve's
		// verb or URL fails here.
		const request = vi.mocked(fetch).mock.calls[0]?.[0] as Request;
		expect(request.method).toBe('DELETE');
		expect(request.url).toContain('/join-requests/jr1');
		expect(request.url).not.toContain('/approval');
	});

	it('bans by user id — the wire carries user_id and reason, and the created ban comes back', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse(201, { data: { id: 'b1', email: 'x@example.com', reason: 'spam' } })
		);
		const ban = await createBan(instance(), 'my-community', 'u9', 'spam');
		expect(ban.id).toBe('b1');

		// The server resolves the target by user_id and records the ban
		// against their email — the client never sends an email address.
		const request = vi.mocked(fetch).mock.calls[0]?.[0] as Request;
		expect(request.method).toBe('POST');
		expect(request.url).toContain('/moderation/bans');
		await expect(request.json()).resolves.toEqual({ user_id: 'u9', reason: 'spam' });
	});

	it('bans instance-wide by email — the wire carries the address itself, not a user id', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse(201, { data: { id: 'ib1', email: 'x@example.com', reason: null } })
		);
		const ban = await createInstanceBan(instance(), 'x@example.com');
		expect(ban.id).toBe('ib1');

		// Unlike the community ban's roster pick, an instance ban can block
		// an address with no account — so the request body is the email.
		const request = vi.mocked(fetch).mock.calls[0]?.[0] as Request;
		expect(request.method).toBe('POST');
		expect(request.url).toContain('/instance/moderation/bans');
		await expect(request.json()).resolves.toEqual({ email: 'x@example.com', reason: null });
	});

	it('publishes a legal page and unwraps the updated page from the envelope', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse(200, {
				data: {
					key: 'privacy',
					title: 'Privacy policy',
					content_markdown: '# Ours',
					content_html: '<h1>Ours</h1>',
					published: true
				}
			})
		);
		const page = await updateLegalPage(instance(), 'privacy', '# Ours');
		expect(page.published).toBe(true);

		const request = vi.mocked(fetch).mock.calls[0]?.[0] as Request;
		expect(request.method).toBe('PUT');
		expect(request.url).toContain('/legal/privacy');
		await expect(request.json()).resolves.toEqual({ content_markdown: '# Ours' });
	});

	it('adds a custom field — the composed definition goes over the wire, the created field comes back', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse(201, {
				data: {
					id: 'cf1',
					label: 'Section',
					field_type: 'single_select',
					options: ['Sopran'],
					required: false,
					visibility: 'members',
					position: 0
				}
			})
		);
		const created = await createCustomField(instance(), 'my-community', {
			label: 'Section',
			field_type: 'single_select',
			options: ['Sopran'],
			visibility: 'members',
			required: false
		});
		expect(created.id).toBe('cf1');

		const request = vi.mocked(fetch).mock.calls[0]?.[0] as Request;
		expect(request.method).toBe('POST');
		expect(request.url).toContain('/communities/my-community/custom-fields');
		await expect(request.json()).resolves.toEqual({
			label: 'Section',
			field_type: 'single_select',
			options: ['Sopran'],
			visibility: 'members',
			required: false
		});
	});

	it('creates a group — the composed GroupParams POSTs to the community, the new group comes back', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse(201, {
				data: { id: 'g1', name: 'Brass', slug: 'brass', visibility: 'community' }
			})
		);
		const created = await createGroup(instance(), 'my-community', {
			name: 'Brass',
			slug: 'brass',
			visibility: 'public_listed',
			posting_policy: 'admins_only',
			sealed: true
		});
		expect(created.id).toBe('g1');

		const request = vi.mocked(fetch).mock.calls[0]?.[0] as Request;
		expect(request.method).toBe('POST');
		expect(request.url).toContain('/communities/my-community/groups');
		// Whole body over the wire — a suggestion's pre-filled visibility/policy
		// and the create-only `sealed` flag must all reach the server.
		await expect(request.json()).resolves.toEqual({
			name: 'Brass',
			slug: 'brass',
			visibility: 'public_listed',
			posting_policy: 'admins_only',
			sealed: true
		});
	});

	it('sets a field required — a PUT to the field with the value in the body, not a bare toggle', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse(200, {
				data: {
					id: 'cf1',
					label: 'Section',
					field_type: 'text',
					options: [],
					required: true,
					visibility: 'members',
					position: 0
				}
			})
		);
		const updated = await updateCustomField(instance(), 'my-community', 'cf1', { required: true });
		expect(updated.required).toBe(true);

		// The desired value rides the wire (the client computes the flip, the
		// server just stores it) — a bug sending an empty body would silently
		// no-op the update.
		const request = vi.mocked(fetch).mock.calls[0]?.[0] as Request;
		expect(request.method).toBe('PUT');
		expect(request.url).toContain('/custom-fields/cf1');
		await expect(request.json()).resolves.toEqual({ required: true });
	});

	it('edits a field — a partial PUT carries only the changed label and visibility', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse(200, {
				data: {
					id: 'cf1',
					label: 'Main instrument',
					field_type: 'text',
					options: [],
					required: false,
					visibility: 'admins',
					position: 0
				}
			})
		);
		const updated = await updateCustomField(instance(), 'my-community', 'cf1', {
			label: 'Main instrument',
			visibility: 'admins'
		});
		expect(updated.label).toBe('Main instrument');

		// Partial update: the body carries exactly what changed — nothing
		// about type or options, which the server freezes at creation.
		const request = vi.mocked(fetch).mock.calls[0]?.[0] as Request;
		expect(request.method).toBe('PUT');
		await expect(request.json()).resolves.toEqual({
			label: 'Main instrument',
			visibility: 'admins'
		});
	});
});

function validation(details: Record<string, string[]>): ApiError {
	return new ApiError('validation', 'Validation failed.', 422, details);
}

describe('groupParamsErrorKeys', () => {
	it('routes each 422 field detail onto its key, leaving unaffected fields and the banner clear', () => {
		// A taken slug arrives keyed on `slug` (unique_constraint error_key,
		// #289); `version_retention` is the update-only numeric field. `name`
		// carries no detail here, so it stays null — and a mapped field
		// suppresses the fallback banner.
		expect(
			groupParamsErrorKeys(validation({ slug: ['taken'], version_retention: ['bad'] }))
		).toEqual({
			nameKey: null,
			slugKey: 'manage.field.error.slug',
			versionRetentionKey: 'manage.field.error.versionRetention',
			bannerKind: null
		});
	});

	it('falls back to the validation banner when a 422 carries no mapped field', () => {
		expect(groupParamsErrorKeys(validation({}))).toEqual({
			nameKey: null,
			slugKey: null,
			versionRetentionKey: null,
			bannerKind: 'validation'
		});
	});

	it('falls back to the kind banner for a non-validation failure', () => {
		expect(groupParamsErrorKeys(new Error('boom')).bannerKind).toBe('server');
		expect(groupParamsErrorKeys(new ApiError('forbidden', 'no', 403)).bannerKind).toBe('forbidden');
	});
});

describe('communityParamsErrorKeys', () => {
	it('routes a 422 name detail onto its key and skips the banner', () => {
		expect(communityParamsErrorKeys(validation({ name: ['blank'] }))).toEqual({
			nameKey: 'manage.field.error.name',
			slugKey: null,
			bannerKind: null
		});
	});

	it('falls back to a banner kind when no field matched or the failure is not a validation', () => {
		expect(communityParamsErrorKeys(validation({})).bannerKind).toBe('validation');
		expect(communityParamsErrorKeys('not an error').bannerKind).toBe('server');
	});
});
