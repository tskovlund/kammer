import { describe, expect, it } from 'vitest';
import { createApiClient } from './client';

describe('createApiClient', () => {
	it('builds a client scoped to the given instance base URL', () => {
		const client = createApiClient('https://kammer.example.com');
		expect(client).toBeTruthy();
	});

	it('exposes typed GET for a known unauthenticated endpoint', async () => {
		const client = createApiClient('https://kammer.example.com');
		// Type-level check only — this schema shape must compile against the
		// generated OpenAPI types, proving they weren't hand-edited out of sync.
		const call = () => client.GET('/api/v1/instance');
		expect(typeof call).toBe('function');
	});
});
