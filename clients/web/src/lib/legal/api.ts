import { createApiClient } from '$lib/api/client.js';
import type { components } from '$lib/api/schema.js';

export type LegalPage = components['schemas']['LegalPage']['data'];
export type LegalPageKey = LegalPage['key'];

export type LegalErrorKind = 'not_found' | 'network' | 'server';

export class LegalApiError extends Error {
	readonly kind: LegalErrorKind;
	readonly status: number | null;

	constructor(kind: LegalErrorKind, message: string, status: number | null = null) {
		super(message);
		this.name = 'LegalApiError';
		this.kind = kind;
		this.status = status;
	}
}

/** Fetches a public legal page. Tokenless and unauthenticated (SPEC §13). */
export async function fetchLegalPage(baseUrl: string, key: string): Promise<LegalPage> {
	try {
		const { data, error, response } = await createApiClient(baseUrl).GET('/api/v1/legal/{key}', {
			params: { path: { key } }
		});
		if (error || !data) {
			const status = response?.status ?? null;
			throw new LegalApiError(
				status === 404 ? 'not_found' : 'server',
				"This page isn't available.",
				status
			);
		}
		return data.data;
	} catch (cause) {
		if (cause instanceof LegalApiError) throw cause;
		throw new LegalApiError('network', 'Could not reach this community.', null);
	}
}
