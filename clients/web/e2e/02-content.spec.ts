import { test, expect } from '@playwright/test';
import { STORAGE_STATE_FILE } from './global-setup.js';
import { appPath, EVENT_TITLE, GROUP, POST_BODY } from './support/scenario.js';

test.use({ storageState: STORAGE_STATE_FILE });

// Picks up the signed-in operator session 01-onboarding.spec.ts left
// behind and drives the two authenticated content flows: posting (with a
// file attachment) and seeing it in the feed, then creating an event and
// RSVPing to it. The default group from setup ships with `events` and
// `files` enabled (`Kammer.Groups.Group.@default_features`), so both
// surfaces are reachable without any extra setup. 03-guest.spec.ts reads
// back the post/event this spec creates (public once it flips the group's
// visibility), so their bodies are fixed strings from scenario.ts rather
// than randomized.
test.describe.serial('post, feed, and event flows', () => {
	test('operator publishes a post with an attachment, and sees it in the feed', async ({
		page
	}) => {
		await page.goto(appPath('/groups'));
		await page.getByRole('link', { name: GROUP.name }).click();
		await expect(page.getByRole('heading', { name: GROUP.name })).toBeVisible();

		await page.locator('#post-composer textarea').fill(POST_BODY);
		await page.locator('#post-composer input[type="file"]').setInputFiles({
			name: 'sheet-music.pdf',
			mimeType: 'application/pdf',
			buffer: Buffer.from('%PDF-1.4\n%% e2e fixture\n%%EOF\n')
		});
		await expect(page.getByText('sheet-music.pdf')).toBeVisible();
		await page.locator('#post-composer button[type="submit"]').click();

		await expect(page.getByText(POST_BODY)).toBeVisible();
		await expect(page.getByText('sheet-music.pdf')).toBeVisible();
	});

	test('operator creates an event and RSVPs to it', async ({ page }) => {
		await page.goto(appPath('/events/new'));
		await page.getByRole('link', { name: GROUP.name }).click();
		await expect(page.locator('#event-form')).toBeVisible();

		await page.locator('#event-form-title').fill(EVENT_TITLE);
		const startsAt = new Date(Date.now() + 9 * 24 * 60 * 60 * 1000);
		startsAt.setUTCHours(19, 0, 0, 0);
		await page.locator('#event-form-starts-at').fill(startsAt.toISOString().slice(0, 16));
		await page.locator('#event-form button[type="submit"]').click();

		await expect(page.getByRole('heading', { name: EVENT_TITLE })).toBeVisible();

		await page.locator('#rsvp-yes').click();
		await expect(page.locator('#rsvp-yes')).toHaveAttribute('aria-pressed', 'true');

		// The store applies RSVPs optimistically (event-store.svelte.ts) and
		// only rolls back on rejection, so the assertion above can pass on a
		// dead server path. Reload and re-assert: only a server-persisted
		// RSVP survives a fresh fetch — the round-trip this suite exists to
		// prove (#187 gate).
		await page.reload();
		await expect(page.getByRole('heading', { name: EVENT_TITLE })).toBeVisible();
		await expect(page.locator('#rsvp-yes')).toHaveAttribute('aria-pressed', 'true');
	});
});
