import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fetchReports, ManageApiError, resolveReport, updateInstanceSettings } from './api';
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

	it('wraps a network failure rather than leaking the raw fetch rejection', async () => {
		vi.mocked(fetch).mockRejectedValueOnce(new TypeError('offline'));
		const error = await updateInstanceSettings(instance(), { instance_name: 'x' }).catch((e) => e);
		expect(error).toBeInstanceOf(ManageApiError);
		expect(error.kind).toBe('network');
	});
});
