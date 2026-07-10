import { test, expect } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { SETUP_TOKEN_FILE, STORAGE_STATE_FILE } from './global-setup.js';
import { waitForMagicLinkToken } from './support/mailbox.js';
import { appPath, COMMUNITY, GROUP, INSTANCE_NAME, OPERATOR } from './support/scenario.js';

// First-run setup wizard (SPEC §13, ADR 0010) over the PWA, then sign-in
// via the magic link the wizard emails the operator — the same
// dev-mailbox path scripts/screenshots.mjs uses for the LiveView smoke
// test, but landing on this client's own deep-link route
// (`/app/sign-in/{token}`) instead of `/users/log-in/{token}`.
//
// Every later spec depends on this one having run first: `playwright.
// config.ts` pins `workers: 1` and file names are numbered so Playwright's
// default (alphabetical) run order matches the dependency. This spec ends
// by persisting the signed-in browser storage state to disk so
// 02-content.spec.ts can pick the session back up.
test.describe.serial('first-run setup and sign-in', () => {
	test('operator completes the wizard and signs in', async ({ page, context }) => {
		const { token } = JSON.parse(readFileSync(SETUP_TOKEN_FILE, 'utf8')) as { token: string };

		await page.goto(appPath('/setup'));
		await page.locator('#setup-token-input').fill(token);
		await page.locator('#setup-operator-email').fill(OPERATOR.email);
		await page.locator('#setup-operator-display-name').fill(OPERATOR.displayName);
		await page.locator('#setup-instance-name').fill(INSTANCE_NAME);
		await page.locator('#setup-operator-submit').click();

		await page.locator('#setup-community-name').fill(COMMUNITY.name);
		await page.locator('#setup-community-slug').fill(COMMUNITY.slug);
		await page.locator('#setup-group-name').fill(GROUP.name);
		await page.locator('#setup-group-slug').fill(GROUP.slug);
		await page.locator('#setup-community-submit').click();

		await expect(page.getByText('Your instance is ready')).toBeVisible();
		await expect(page.getByText(COMMUNITY.slug)).toBeVisible();

		const magicToken = await waitForMagicLinkToken(OPERATOR.email);
		await page.goto(appPath(`/sign-in/${magicToken}`));

		// The deep-link route probes the current origin, exchanges the
		// token for a device token, adds the instance, and redirects home.
		await expect(page).toHaveURL(new RegExp(`${appPath('/')}$`));
		await expect(page.getByRole('heading', { name: 'Home' })).toBeVisible();

		await context.storageState({ path: STORAGE_STATE_FILE });
	});
});
