import { test, expect } from '@playwright/test';
import { STORAGE_STATE_FILE } from './global-setup.js';
import { allowGuestComments, createFixtureEvent, makeGroupPublic } from './support/api.js';
import { readDeviceToken } from './support/auth.js';
import { appPath, COMMUNITY, GROUP, PHOENIX_BASE, POST_BODY } from './support/scenario.js';

// The tokenless public surface (issue #185 slice B, #246): anonymous
// browsing of a public community/group/post/event, plus the guest
// comment/RSVP request forms — the last piece gating the LiveView removal
// (#187). No storageState here on purpose: every test in this file runs
// as an anonymous visitor.
//
// `GroupLive.Settings`'s PWA twin doesn't expose visibility/comment-policy
// controls yet (only name, description, and features —
// `(app)/i/[instance]/c/[community]/g/[group]/settings/+page.svelte`), so
// flipping those two flags is a direct API call using the operator's
// device token, the same way seeding a database directly would be. Both
// starts off; each test below can also serve as the "form absent while
// the flag is off" check for the other's flag before it flips them on.
let deviceToken: string;
let guestEventId: string;

test.beforeAll(async () => {
	deviceToken = readDeviceToken(STORAGE_STATE_FILE, PHOENIX_BASE);
	guestEventId = await createFixtureEvent(deviceToken, 'Guest RSVP fixture concert');
	await makeGroupPublic(deviceToken);
});

test('guest browses the public community, group, and post', async ({ page }) => {
	await page.goto(appPath(`/c/${COMMUNITY.slug}`));
	await expect(page.getByRole('heading', { name: COMMUNITY.name })).toBeVisible();

	await page.getByRole('link', { name: GROUP.name }).click();
	await expect(page.getByRole('heading', { name: GROUP.name })).toBeVisible();
	await expect(page.getByText(POST_BODY)).toBeVisible();
});

test('guest comment request form is hidden until the group allows it, then works', async ({
	page
}) => {
	await page.goto(appPath(`/c/${COMMUNITY.slug}/g/${GROUP.slug}`));
	await page.locator('a', { hasText: POST_BODY }).first().click();
	await expect(page).toHaveURL(new RegExp(`/g/${GROUP.slug}/p/`));

	// comment_policy is still the schema default (`members`) at this point
	// — `can_guest_comment?/1` is false, so the request form must not
	// render at all.
	await expect(page.locator('#public-post-comment-form')).toHaveCount(0);

	await allowGuestComments(deviceToken);
	await page.reload();

	await page.locator('#public-post-comment-name').fill('Camilla Guest');
	await page.locator('#public-post-comment-email').fill('camilla@example.org');
	await page.locator('#public-post-comment-body').fill('Loved the summer set - see you Thursday!');
	await page.locator('#public-post-comment-submit').click();

	// A neutral "check your email" state, never a synchronous comment —
	// approval happens after the guest confirms via the emailed link
	// (issue #185 slice B; out of scope here, see guest/comment/confirm).
	await expect(page.getByText('Comment sent')).toBeVisible();
});

test('guest RSVP request form works on a public event', async ({ page }) => {
	await page.goto(appPath(`/c/${COMMUNITY.slug}/events/${guestEventId}`));
	await page.locator('#public-event-rsvp-reveal').click();

	await page.locator('#public-event-rsvp-status-maybe').click();
	await page.locator('#public-event-rsvp-name').fill('Dennis Guest');
	await page.locator('#public-event-rsvp-email').fill('dennis@example.org');
	await page.locator('#public-event-rsvp-submit').click();

	await expect(page.getByText('RSVP sent')).toBeVisible();
});
