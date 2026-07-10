import { createApiClient } from '$lib/api/client.js';
import type { components } from '$lib/api/schema.js';

export type SetupResult = components['schemas']['SetupResult']['data'];

export type SetupErrorKind = 'forbidden' | 'validation' | 'rate_limited' | 'network' | 'server';

export class SetupApiError extends Error {
	readonly kind: SetupErrorKind;
	readonly status: number | null;

	constructor(kind: SetupErrorKind, message: string, status: number | null = null) {
		super(message);
		this.name = 'SetupApiError';
		this.kind = kind;
		this.status = status;
	}
}

function kindForStatus(status: number): SetupErrorKind {
	switch (status) {
		case 403:
			return 'forbidden';
		case 400:
		case 422:
			return 'validation';
		case 429:
			return 'rate_limited';
		default:
			return 'server';
	}
}

interface ErrorEnvelope {
	error?: { code?: string; message?: string };
}

function messageFrom(error: unknown, fallback: string): string {
	const envelope = error as ErrorEnvelope | undefined;
	return envelope?.error?.message ?? fallback;
}

function fail(error: unknown, response: Response | undefined, fallback: string): SetupApiError {
	const status = response?.status ?? null;
	const kind = status ? kindForStatus(status) : 'server';
	return new SetupApiError(kind, messageFrom(error, fallback), status);
}

async function guard<T>(request: () => Promise<T>): Promise<T> {
	try {
		return await request();
	} catch (cause) {
		if (cause instanceof SetupApiError) throw cause;
		throw new SetupApiError('network', 'Could not reach this instance.', null);
	}
}

/** Whether first-run setup has already completed (SPEC §13). */
export async function fetchSetupStatus(baseUrl: string): Promise<boolean> {
	return guard(async () => {
		const { data, error, response } = await createApiClient(baseUrl).GET('/api/v1/setup');
		if (error || !data) throw fail(error, response, 'Could not check setup status.');
		return data.setup_completed;
	});
}

export interface CompleteSetupInput {
	token: string;
	operator: { email: string; display_name?: string | null };
	instance: {
		instance_name?: string | null;
		default_locale?: 'en' | 'da' | null;
		community_creation_policy?: 'operators_only' | 'any_user' | null;
	};
	community: { name: string; slug: string; accent_color?: string | null };
	group: { name: string; slug: string };
	demo_data?: boolean | null;
}

/**
 * Completes first-run setup: operator, instance settings, first community
 * and group. There is deliberately no separate token-check endpoint
 * (issue #230) — a boolean oracle over the setup credential — so the
 * setup token rides this same call and is validated server-side on every
 * submission; a bad or already-consumed token comes back as a neutral
 * `forbidden` (403), never a pre-flight yes/no.
 */
export async function completeSetup(
	baseUrl: string,
	input: CompleteSetupInput
): Promise<SetupResult> {
	return guard(async () => {
		const { data, error, response } = await createApiClient(baseUrl).POST('/api/v1/setup', {
			body: input
		});
		if (error || !data)
			throw fail(error, response, 'Setup failed — check the values and try again.');
		return data.data;
	});
}
