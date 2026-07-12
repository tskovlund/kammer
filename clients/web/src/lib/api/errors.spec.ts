import { describe, expect, it } from 'vitest';
import { ApiError, errorKind, fail, guard } from './errors.js';

function response(status: number): Response {
	return new Response(null, { status });
}

// The one canonical status→kind mapping test for the whole client. Every
// API module throws this shared `ApiError` (#270), so the per-module specs
// assert only their own paths/bodies/invariants and trust this to prove the
// mapping once.
describe('fail', () => {
	it.each([
		[401, 'auth'],
		[403, 'forbidden'],
		[404, 'not_found'],
		[413, 'too_large'],
		[422, 'validation'],
		[429, 'rate_limited'],
		[400, 'server'],
		[500, 'server']
	])('maps status %i to kind %s', (status, kind) => {
		const error = fail(undefined, response(status as number), 'fallback');
		expect(error).toBeInstanceOf(ApiError);
		expect(error.kind).toBe(kind);
		expect(error.status).toBe(status);
	});

	it('is a server error with a null status when there is no response', () => {
		const error = fail(undefined, undefined, 'fallback');
		expect(error.kind).toBe('server');
		expect(error.status).toBeNull();
	});

	it("carries a 422 envelope's field details and message, falling back when absent", () => {
		const withEnvelope = fail(
			{
				error: {
					code: 'validation',
					message: 'Slug has already been taken.',
					details: { slug: ['taken'] }
				}
			},
			response(422),
			'fallback'
		);
		// The field NAME drives the UI; the English message is for debugging
		// only (#253) — but both must survive the plumbing intact.
		expect(withEnvelope.details).toEqual({ slug: ['taken'] });
		expect(withEnvelope.message).toBe('Slug has already been taken.');

		const bare = fail(undefined, response(422), 'fallback');
		expect(bare.details).toEqual({});
		expect(bare.message).toBe('fallback');
	});
});

describe('guard', () => {
	it('rethrows an ApiError untouched', async () => {
		const original = new ApiError('forbidden', 'nope', 403);
		await expect(
			guard(async () => {
				throw original;
			})
		).rejects.toBe(original);
	});

	it('wraps a raw fetch rejection as a network ApiError', async () => {
		const error = await guard(async () => {
			throw new TypeError('Failed to fetch');
		}).catch((cause) => cause);
		expect(error).toBeInstanceOf(ApiError);
		expect(error.kind).toBe('network');
		expect(error.status).toBeNull();
	});

	it('returns the request value on success', async () => {
		await expect(guard(async () => 42)).resolves.toBe(42);
	});
});

describe('errorKind', () => {
	it("returns an ApiError's kind, preserving too_large", () => {
		expect(errorKind(new ApiError('too_large', 'big', 413))).toBe('too_large');
	});

	// instanceof, not duck-typing: a plain object that merely looks like an
	// error (or any non-ApiError) reads as `server`.
	it('collapses any non-ApiError to server', () => {
		expect(errorKind(new TypeError('boom'))).toBe('server');
		expect(errorKind({ kind: 'auth' })).toBe('server');
		expect(errorKind(null)).toBe('server');
	});
});
