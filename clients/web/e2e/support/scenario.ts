/**
 * Fixed scenario constants shared across the e2e specs. The suite runs
 * serially against one freshly-reset database (see global-setup.ts), so a
 * single hardcoded community/group/operator identity is enough — there is
 * no concurrency to dodge with unique-per-run names.
 */

export const PHOENIX_BASE = 'http://localhost:4000';
export const PWA_BASE = '/app';

export const OPERATOR = {
	email: 'frida@example.org',
	displayName: 'Frida'
};

export const INSTANCE_NAME = 'Kammer E2E';

export const COMMUNITY = {
	name: 'Kammerkoret',
	slug: 'kammerkoret'
};

export const GROUP = {
	name: 'General',
	slug: 'general'
};

// Fixed content bodies rather than `Date.now()`-suffixed ones: the suite
// runs serially against one freshly-reset database (no risk of colliding
// with a previous run's leftovers), and a stable string lets the guest
// spec assert on the exact post an earlier spec created without having to
// thread dynamic values through a shared file.
export const POST_BODY = 'Rehearsal notes — full run of the summer set on Thursday.';
export const EVENT_TITLE = 'Summer concert — dress rehearsal';

/** Prefixes every client-side route with the PWA's baked-in base path. */
export function appPath(path: string): string {
	return `${PWA_BASE}${path}`;
}
