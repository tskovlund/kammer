import type { FailedInstance, InstanceFailureKind } from '$lib/instances/home.js';
import type { Instance } from '$lib/instances/types.js';

/**
 * How an authenticated API read/write failed. The UI reacts differently
 * per kind: `auth` re-prompts sign-in for that instance (ties into the
 * #159 failure kinds and the socket's `noteAuthFailure`), `forbidden`
 * explains a missing right, `validation`/`too_large`/`rate_limited` are
 * friendly composer errors, and `network`/`server` are retryable.
 *
 * One shared home (rather than a per-feature copy of the class and its
 * status mapping): feed, events, and notifications all throw the same
 * error for the same server behavior, so a mapping change lands once.
 */
export type FeedErrorKind =
	| 'auth'
	| 'forbidden'
	| 'not_found'
	| 'validation'
	| 'too_large'
	| 'rate_limited'
	| 'network'
	| 'server';

export class FeedApiError extends Error {
	readonly kind: FeedErrorKind;
	readonly status: number | null;
	/**
	 * Field → messages from a 422's changeset details, `{}` otherwise.
	 * UI maps field NAMES onto its own i18n copy — the message strings
	 * are server-English and must never render (#253's direction).
	 */
	readonly details: Record<string, string[]>;

	constructor(
		kind: FeedErrorKind,
		message: string,
		status: number | null = null,
		details: Record<string, string[]> = {}
	) {
		super(message);
		this.name = 'FeedApiError';
		this.kind = kind;
		this.status = status;
		this.details = details;
	}
}

export function kindForStatus(status: number): FeedErrorKind {
	switch (status) {
		case 401:
			return 'auth';
		case 403:
			return 'forbidden';
		case 404:
			return 'not_found';
		case 413:
			return 'too_large';
		case 422:
			return 'validation';
		case 429:
			return 'rate_limited';
		default:
			return 'server';
	}
}

interface ErrorEnvelope {
	error?: { code?: string; message?: string; details?: Record<string, string[]> };
}

/** Turn an openapi-fetch `{ error, response }` into a typed FeedApiError. */
export function fail(
	error: unknown,
	response: Response | undefined,
	fallback: string
): FeedApiError {
	const status = response?.status ?? null;
	const kind = status ? kindForStatus(status) : 'server';
	const envelope = (error as ErrorEnvelope | undefined)?.error;
	return new FeedApiError(kind, envelope?.message ?? fallback, status, envelope?.details ?? {});
}

export async function guard<T>(request: () => Promise<T>): Promise<T> {
	try {
		return await request();
	} catch (cause) {
		if (cause instanceof FeedApiError) throw cause;
		// fetch() itself rejected — DNS, refused connection, offline.
		throw new FeedApiError('network', 'Could not reach this community.', null);
	}
}

/**
 * Collapse a caught error into the #159 per-instance failure kind the
 * multi-instance stores surface (`FailedInstance`) — `auth` and `network`
 * keep their meaning, everything else reads as that instance's server
 * misbehaving.
 */
export function failureKind(error: unknown): InstanceFailureKind {
	if (error instanceof FeedApiError) {
		if (error.kind === 'auth') return 'auth';
		if (error.kind === 'network') return 'network';
	}
	return 'server';
}

/** The `FailedInstance` for a caught per-instance error — see `failureKind`. */
export function instanceFailure(instance: Instance, error: unknown): FailedInstance {
	return { instance, kind: failureKind(error) };
}
