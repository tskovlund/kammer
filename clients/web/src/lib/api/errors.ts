import type { FailedInstance, InstanceFailureKind } from '$lib/instances/home.js';
import type { Instance } from '$lib/instances/types.js';

/**
 * How any API read/write failed. The UI reacts differently per kind:
 * `auth` re-prompts sign-in for that instance (ties into the #159 failure
 * kinds and the socket's `noteAuthFailure`), `forbidden` explains a
 * missing right, `validation`/`too_large`/`rate_limited` are friendly
 * composer errors, and `network`/`server` are retryable.
 *
 * The single shared home for every API surface — authenticated (feed,
 * events, notifications, manage, tools, push) and tokenless (public,
 * guest, newsletter, legal, setup) alike. All of them throw this one
 * `ApiError` for the same server behavior, so the status→kind mapping and
 * its plumbing live in exactly one place (#270). A surface that a server
 * never issues 401/403 for (a tokenless read) simply never produces
 * `auth`/`forbidden` — the narrowing is documented per module, not forked
 * into separate classes.
 */
export type ApiErrorKind =
	| 'auth'
	| 'forbidden'
	| 'not_found'
	| 'validation'
	| 'too_large'
	| 'rate_limited'
	| 'network'
	| 'server';

export class ApiError extends Error {
	readonly kind: ApiErrorKind;
	readonly status: number | null;
	/**
	 * Field → messages from a 422's changeset details, `{}` otherwise.
	 * UI maps field NAMES onto its own i18n copy — the message strings
	 * are server-English and must never render (#253's direction).
	 */
	readonly details: Record<string, string[]>;

	constructor(
		kind: ApiErrorKind,
		message: string,
		status: number | null = null,
		details: Record<string, string[]> = {}
	) {
		super(message);
		this.name = 'ApiError';
		this.kind = kind;
		this.status = status;
		this.details = details;
	}
}

export function kindForStatus(status: number): ApiErrorKind {
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

/** Turn an openapi-fetch `{ error, response }` into a typed ApiError. */
export function fail(error: unknown, response: Response | undefined, fallback: string): ApiError {
	const status = response?.status ?? null;
	const kind = status ? kindForStatus(status) : 'server';
	const envelope = (error as ErrorEnvelope | undefined)?.error;
	return new ApiError(kind, envelope?.message ?? fallback, status, envelope?.details ?? {});
}

export async function guard<T>(request: () => Promise<T>): Promise<T> {
	try {
		return await request();
	} catch (cause) {
		if (cause instanceof ApiError) throw cause;
		// fetch() itself rejected — DNS, refused connection, offline.
		throw new ApiError('network', 'Could not reach this community.', null);
	}
}

/** Collapse any caught error to a kind; non-ApiError (or an unexpected shape) reads as `server`. */
export function errorKind(cause: unknown): ApiErrorKind {
	return cause instanceof ApiError ? cause.kind : 'server';
}

/**
 * Collapse a caught error into the #159 per-instance failure kind the
 * multi-instance stores surface (`FailedInstance`) — `auth` and `network`
 * keep their meaning, everything else reads as that instance's server
 * misbehaving.
 */
export function failureKind(error: unknown): InstanceFailureKind {
	if (error instanceof ApiError) {
		if (error.kind === 'auth') return 'auth';
		if (error.kind === 'network') return 'network';
	}
	return 'server';
}

/** The `FailedInstance` for a caught per-instance error — see `failureKind`. */
export function instanceFailure(instance: Instance, error: unknown): FailedInstance {
	return { instance, kind: failureKind(error) };
}
