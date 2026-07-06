// Drives a fresh Kammer dev instance through the real first-run flow
// and captures the screenshots embedded in the README. Run via
// scripts/screenshots.sh (which owns the database/server lifecycle);
// direct usage:
//
//   node scripts/screenshots.mjs --base http://localhost:4000 \
//     --token <setup-token-from-server-log> --out docs/screenshots
//
// Requires a Chromium binary: CHROMIUM_BIN env var, or the Playwright
// default install (npx playwright install chromium).
import { chromium } from "playwright-core";
import { mkdirSync } from "node:fs";

const arg = (name, fallback) => {
  const index = process.argv.indexOf(`--${name}`);
  return index === -1 ? fallback : process.argv[index + 1];
};

const BASE = arg("base", "http://localhost:4000");
const TOKEN = arg("token");
const OUT = arg("out", "docs/screenshots");
if (!TOKEN) throw new Error("--token <setup token> is required");
mkdirSync(OUT, { recursive: true });

// Operator name is a nod to Else Marie Pade, the Danish pioneer of
// electronic music (and wartime resistance member).
const COMMUNITY = { name: "Kammerkoret", slug: "kammerkoret" };
const OPERATOR = { email: "else@example.org", name: "Else Marie Pade" };

const browser = await chromium.launch({
  executablePath: process.env.CHROMIUM_BIN || undefined,
  args: ["--no-sandbox"],
});

const settle = async (page) => {
  await page.waitForSelector("[data-phx-main].phx-connected", {
    timeout: 10_000,
  });
  await page.waitForTimeout(400);
};

const shot = (page, name) =>
  page.screenshot({ path: `${OUT}/${name}.png`, fullPage: false });

// --- First-run wizard (the real flow, nothing seeded behind the scenes)
const context = await browser.newContext({
  viewport: { width: 1440, height: 900 },
});
const page = await context.newPage();

await page.goto(`${BASE}/setup`);
await settle(page);
// Resume-safe: if setup already completed (rerun), the gate bounces home.
const tokenInput = page.locator('input[name="token"]');
if (await tokenInput.count()) {
  await page.fill('input[name="token"]', TOKEN);
  await page.click("#setup-token-form button");
  await page.waitForSelector('input[name="operator_email"]');
  await page.fill('input[name="operator_email"]', OPERATOR.email);
  await page.fill('input[name="operator_display_name"]', OPERATOR.name);
  await page.fill('input[name="instance_name"]', "Kammer");
  await page.click("#setup-instance-form button");
  await page.waitForSelector('input[name="community_name"]');
  await page.fill('input[name="community_name"]', COMMUNITY.name);
  await page.fill('input[name="community_slug"]', COMMUNITY.slug);
  await page.fill('input[name="group_name"]', "General");
  await page.fill('input[name="group_slug"]', "general");
  await page.click("#setup-community-form button");
  await page.waitForSelector("#invite-url", { timeout: 15_000 });
}

// --- Sign in via a magic link from the dev mailbox. The wizard's own
// email is used first; if that token was already consumed (rerun), a
// fresh link is requested through the real login form.
const latestToken = async () => {
  const mailbox = await (await fetch(`${BASE}/dev/mailbox/json`)).text();
  const match = mailbox.match(/users\/log-in\/([\w-]+)/);
  if (!match) throw new Error("no magic link found in /dev/mailbox/json");
  return match[1];
};
const trySignIn = async (token) => {
  await page.goto(`${BASE}/users/log-in/${token}`);
  await settle(page);
  const confirm = page.locator("main form button.btn-primary").first();
  if (!(await confirm.count())) return false;
  // Two-phase submit (LiveView -> phx-trigger-action -> controller POST):
  // wait for the signed-in header marker rather than racing redirects.
  await confirm.click();
  return await page
    .waitForSelector('[href="/users/log-out"]', { timeout: 20_000 })
    .then(() => true)
    .catch(() => false);
};
if (!(await trySignIn(await latestToken()))) {
  await page.goto(`${BASE}/users/log-in`);
  await settle(page);
  await page.fill('input[name="user[email]"]', OPERATOR.email);
  await page.locator("main form button").last().click();
  await page.waitForTimeout(1500);
  if (!(await trySignIn(await latestToken()))) {
    throw new Error("magic-link sign-in failed twice");
  }
}

// --- Author believable content through the real UI
const groupUrl = `${BASE}/c/${COMMUNITY.slug}/g/general`;
const post = async (text) => {
  await page.goto(groupUrl);
  await settle(page);
  await page.fill("#composer_body", text);
  await page.click('#composer_form button:not([type="button"])');
  await page.waitForTimeout(600);
};

await post(
  "Welcome to our new home 🎶\n\n" +
    "No ads, no algorithm — just us. Rehearsal notes live here, sheet " +
    "music goes in **Files**, and concerts are under **Events**.",
);
await post(
  "Rehearsal notes — Thursday\n\n" +
    "- Warm-up, then a full run of the summer set\n" +
    "- New one: the ABBA medley — verses first, harmonies next week\n" +
    "- Bring the blue folder\n\n" +
    "Coffee duty: Jonas ☕",
);

const startsAt = new Date(Date.now() + 9 * 24 * 60 * 60 * 1000);
startsAt.setHours(19, 0, 0, 0);
await page.goto(`${BASE}/c/${COMMUNITY.slug}/events/new`);
await settle(page);
await page.fill(
  'input[name="event[title]"]',
  "Summer concert — dress rehearsal",
);
await page.fill(
  'input[name="event[starts_on]"]',
  startsAt.toISOString().slice(0, 10),
);
await page.fill('input[name="event[starts_time]"]', "19:00");
await page.fill('input[name="event[location_name]"]', "Sankt Markus Church");
await page.click('#event_form button:not([type="button"])');
await page.waitForURL(/events\/[0-9a-f-]+$/, { timeout: 10_000 });
const eventUrl = page.url();
await settle(page);
const going = page.locator("button", { hasText: "Going" }).first();
if (await going.count()) await going.click();
await page.waitForTimeout(500);

// --- Capture
await page.goto(groupUrl);
await settle(page);
await shot(page, "feed-desktop");

await page.goto(`${BASE}/c/${COMMUNITY.slug}/events`);
await settle(page);
await shot(page, "events-desktop");

await page.goto(eventUrl);
await settle(page);
await shot(page, "event-desktop");

await page.goto(`${BASE}/`);
await settle(page);
await shot(page, "home-desktop");

const state = await context.storageState();

const dark = await browser.newContext({
  viewport: { width: 1440, height: 900 },
  colorScheme: "dark",
  storageState: state,
});
const darkPage = await dark.newPage();
await darkPage.goto(groupUrl);
await settle(darkPage);
await shot(darkPage, "feed-desktop-dark");

const mobile = await browser.newContext({
  viewport: { width: 390, height: 844 },
  deviceScaleFactor: 2,
  isMobile: true,
  storageState: state,
});
const mobilePage = await mobile.newPage();
await mobilePage.goto(groupUrl);
await settle(mobilePage);
await shot(mobilePage, "feed-mobile");

await browser.close();
console.log(`screenshots written to ${OUT}/`);
