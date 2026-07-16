import type { HandleClientError } from '@sveltejs/kit';

/**
 * The floor under unexpected client errors (part of #270): anything that
 * escapes a route — a crashed load, a render error during navigation — is
 * logged for debugging (console is the only sink; no telemetry exists) and
 * reduced to SvelteKit's own generic, status-derived message. `+error.svelte`
 * renders localized copy from `page.status` alone, so nothing from the raw
 * error — stack, server detail, third-party message — can ever reach the UI.
 */
export const handleError: HandleClientError = ({ error, status, message }) => {
	console.error(`[kammer] unexpected client error (${status})`, error);
	return { message };
};
