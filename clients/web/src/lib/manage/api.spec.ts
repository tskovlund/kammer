import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
	approveJoinRequest,
	createBan,
	createInstanceBan,
	denyJoinRequest,
	fetchJoinRequests,
	fetchReports,
	ManageApiError,
	resolveReport,
	updateCommunity,
	updateInstanceSettings,
	updateLegalPage
} from './api';
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

function errorResponse(status: number, code = 'error', message = 'nope') {
	return jsonResponse(status, { error: { code, message } });
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

	it('maps 403 to forbidden — a stale capability that the server still refuses', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(errorResponse(403, 'forbidden', 'Not allowed.'));
		await expect(resolveReport(instance(), 'my-community', 'r1')).rejects.toMatchObject({
			kind: 'forbidden',
			status: 403
		});
	});

	it('maps 429 to rate_limited and surfaces the server message', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			errorResponse(429, 'rate_limited', 'Too many attempts. Try again later.')
		);
		await expect(resolveReport(instance(), 'my-community', 'r1')).rejects.toMatchObject({
			kind: 'rate_limited',
			message: 'Too many attempts. Try again later.'
		});
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

	it('maps a 422 on approval to validation — the requester is banned', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(errorResponse(422, 'banned', 'That person is banned.'));
		await expect(
			approveJoinRequest(instance(), 'my-community', 'crew', 'jr1')
		).rejects.toMatchObject({ kind: 'validation', status: 422 });
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

	it('carries a 422 changeset detail so a settings form can key its own copy off the field name', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse(422, {
				error: {
					code: 'validation',
					message: 'Slug has already been taken.',
					details: { slug: ['taken'] }
				}
			})
		);
		const error = await updateCommunity(instance(), 'my-community', { slug: 'taken' }).catch(
			(e) => e
		);
		expect(error).toBeInstanceOf(ManageApiError);
		expect(error.kind).toBe('validation');
		// The field NAME drives the UI; the English message string never renders
		// (#253). Assert the whole payload so mangled plumbing can't pass.
		expect(error.details).toEqual({ slug: ['taken'] });
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

	it('wraps a network failure rather than leaking the raw fetch rejection', async () => {
		vi.mocked(fetch).mockRejectedValueOnce(new TypeError('offline'));
		const error = await updateInstanceSettings(instance(), { instance_name: 'x' }).catch((e) => e);
		expect(error).toBeInstanceOf(ManageApiError);
		expect(error.kind).toBe('network');
	});
});
