import { COMMUNITY, GROUP, PHOENIX_BASE } from './scenario.js';

/**
 * Thin fetch wrappers around the JSON API for the small amount of setup
 * the e2e specs need that has no PWA surface yet (group visibility /
 * comment policy — `manage/group/settings` only exposes name, description,
 * and features today). Everything a real user can do through the product
 * stays UI-driven; these calls only stand in for an admin control the PWA
 * hasn't grown yet, the same way seeding a database directly would.
 */

async function authedJson<T>(
	deviceToken: string,
	path: string,
	init: RequestInit = {}
): Promise<T> {
	const response = await fetch(`${PHOENIX_BASE}/api/v1${path}`, {
		...init,
		headers: {
			'content-type': 'application/json',
			authorization: `Bearer ${deviceToken}`,
			...init.headers
		}
	});
	if (!response.ok) {
		throw new Error(`${init.method ?? 'GET'} ${path} -> ${response.status}`);
	}
	return response.json() as Promise<T>;
}

/**
 * Flips the operator's own group to `public_listed` (issue #185 slice B's
 * guest surface only activates on the public visibility presets — see
 * `Kammer.Authorization.can_guest_rsvp?/1`). Comment policy is left at its
 * default (`members`) so the guest-comment-request test can assert the
 * form is absent before flipping it on separately.
 */
export async function makeGroupPublic(deviceToken: string): Promise<void> {
	await authedJson(deviceToken, `/communities/${COMMUNITY.slug}/groups/${GROUP.slug}`, {
		method: 'PUT',
		body: JSON.stringify({ visibility: 'public_listed' })
	});
}

export async function allowGuestComments(deviceToken: string): Promise<void> {
	await authedJson(deviceToken, `/communities/${COMMUNITY.slug}/groups/${GROUP.slug}`, {
		method: 'PUT',
		body: JSON.stringify({ comment_policy: 'members_and_guests' })
	});
}

interface CreatedInvite {
	data: { token: string };
}

/**
 * Mints the community invite the join spec's newcomer follows. Invite
 * creation through the UI is a real PWA surface (the community invites
 * page), but 04-join.spec.ts is about the *invitee's* path — this is a
 * seed, same rationale as `createFixtureEvent`.
 */
export async function createCommunityInvite(deviceToken: string): Promise<string> {
	const { data } = await authedJson<CreatedInvite>(
		deviceToken,
		`/communities/${COMMUNITY.slug}/invites`,
		{ method: 'POST', body: JSON.stringify({}) }
	);
	return data.token;
}

interface CreatedEvent {
	data: { id: string };
}

/**
 * Creates the fixture event the guest-RSVP test browses to. Event
 * creation through the UI is already covered by 02-content.spec.ts; this
 * is a seed, not a re-test of that flow.
 */
export async function createFixtureEvent(deviceToken: string, title: string): Promise<string> {
	const startsAt = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString();
	const { data } = await authedJson<CreatedEvent>(
		deviceToken,
		`/communities/${COMMUNITY.slug}/groups/${GROUP.slug}/events`,
		{
			method: 'POST',
			body: JSON.stringify({ title, starts_at: startsAt })
		}
	);
	return data.id;
}
