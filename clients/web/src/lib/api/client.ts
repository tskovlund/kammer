import createClient from 'openapi-fetch';
import type { paths } from './schema.js';

/**
 * One client per added instance (ADR 0001's multi-instance model) — callers
 * construct this per instance base URL, not as a module-level singleton.
 */
export function createApiClient(baseUrl: string, deviceToken?: string) {
	return createClient<paths>({
		baseUrl,
		headers: deviceToken ? { authorization: `Bearer ${deviceToken}` } : undefined
	});
}

export type ApiClient = ReturnType<typeof createApiClient>;
