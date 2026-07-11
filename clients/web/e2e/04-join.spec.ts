import { test, expect } from '@playwright/test';
import { STORAGE_STATE_FILE } from './global-setup.js';
import { createCommunityInvite } from './support/api.js';
import { readDeviceToken } from './support/auth.js';
import { waitForMagicLinkToken } from './support/mailbox.js';
import { appPath, COMMUNITY, PHOENIX_BASE } from './support/scenario.js';

// The PWA join flow (issue #255): an invited newcomer follows the shared
// invite link, registers with just a name and an email, opens the magic
// link, and lands joined — the invitee's half of the invites feature
// (the admin's half, minting links, is 02-content territory and seeded
// via the API here). No storageState: the whole point is starting from
// nothing. The pending invite rides a TTL'd localStorage entry, so the
// magic link works same-tab (driven here) and new-tab alike.
test('an invited newcomer registers and lands in the joined community', async ({ page }) => {
	const deviceToken = readDeviceToken(STORAGE_STATE_FILE, PHOENIX_BASE);
	const inviteToken = await createCommunityInvite(deviceToken);
	// Unique per attempt: registration is the one flow that is NOT
	// idempotent against this run's own first try — a fixed address would
	// turn any transient flake into a deterministic 422 on CI's retry.
	const email = `jonas+${Date.now()}@example.org`;

	await page.goto(appPath(`/invite/${inviteToken}`));
	await expect(page.getByText(`You're invited to ${COMMUNITY.name}`)).toBeVisible();

	await page.locator('#invite-register').click();
	await page.locator('#register-display-name').fill('Jonas');
	await page.locator('#register-email').fill(email);
	await page.locator('#register-submit').click();
	await expect(page.locator('#invite-confirm-form')).toBeVisible();

	const magicToken = await waitForMagicLinkToken(email);
	await page.goto(appPath(`/sign-in/${magicToken}`));

	// The deep-link route exchanges the token, picks up the pending
	// invite, accepts it, and lands on the Groups tab — where the newly
	// joined community's directory lives (community-wide invites have no
	// dedicated community page in the PWA).
	await expect(page).toHaveURL(new RegExp(`${appPath('/groups')}$`));
	await expect(page.getByRole('heading', { name: COMMUNITY.name })).toBeVisible();
});

test('a dead invite token gets the calm invalid state, not a crash', async ({ page }) => {
	await page.goto(appPath('/invite/not-a-real-token'));
	await expect(page.getByText('This invitation is no longer valid')).toBeVisible();
});
