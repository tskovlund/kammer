// Drives a fresh Kammer dev instance through the real product flows —
// first-run wizard, invite-link signups, posting, reactions, a poll,
// an acknowledgment post, an event with RSVPs, file uploads, a sealed
// group — and captures the screenshots embedded in the README. Nothing
// is seeded behind the scenes: everything on screen happened through
// the UI. Doubles as the CI smoke test (any step failing throws).
//
// Assumes the fresh database that scripts/screenshots.sh provides.
// Direct usage:
//
//   node scripts/screenshots.mjs --base http://localhost:4000 \
//     --token <setup-token-from-server-log> --out docs/screenshots
//
// Requires a Chromium binary: CHROMIUM_BIN env var, or the Playwright
// default install (npx playwright install chromium).
import { chromium } from "playwright-core";
import { mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const arg = (name, fallback) => {
  const index = process.argv.indexOf(`--${name}`);
  return index === -1 ? fallback : process.argv[index + 1];
};

const BASE = arg("base", "http://localhost:4000");
const TOKEN = arg("token");
const OUT = arg("out", "docs/screenshots");
if (!TOKEN) throw new Error("--token <setup token> is required");
mkdirSync(OUT, { recursive: true });

// The cast is a nod you might just recognize. First names only — it's a
// wink, not a claim. Frida conducts and runs the instance.
const COMMUNITY = { name: "Kammerkoret", slug: "kammerkoret" };
const FRIDA = { email: "frida@example.org", name: "Frida" };
const MEMBERS = [
  { email: "agnetha@example.org", name: "Agnetha" },
  { email: "bjorn@example.org", name: "Björn" },
  { email: "benny@example.org", name: "Benny" },
];

const DESKTOP = { width: 1440, height: 900 };
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

// Same-URL navigations restore the previous scroll position — pin the
// viewport to the top so every shot frames the page header.
const shot = async (page, name) => {
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(200);
  await page.screenshot({ path: `${OUT}/${name}.png`, fullPage: false });
};

const groupUrl = `${BASE}/c/${COMMUNITY.slug}/g/general`;

// --- Mailbox helpers (dev-only Swoosh preview at /dev/mailbox/json)
const tokenFromMailbox = async (email) => {
  for (let attempt = 0; attempt < 20; attempt++) {
    const { data } = await (await fetch(`${BASE}/dev/mailbox/json`)).json();
    const message = data.find((m) => m.to.some((to) => to.includes(email)));
    const match = message?.text_body.match(/users\/log-in\/([\w-]+)/);
    if (match) return match[1];
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error(`no magic link for ${email} in /dev/mailbox/json`);
};

// Magic-link confirmation is a two-phase submit (LiveView, then a
// phx-trigger-action browser POST): wait for the signed-in header
// marker rather than racing redirects.
const confirmMagicLink = async (page, token) => {
  await page.goto(`${BASE}/users/log-in/${token}`);
  await settle(page);
  await page.locator("main form button.btn-primary").first().click();
  await page.waitForSelector('[href="/users/log-out"]', { timeout: 20_000 });
};

// Invite flow: the accept endpoint requires auth and remembers the
// return path, so a new member visits the invite, registers, confirms
// the emailed link, and lands back on the invite — redeemed.
const joinViaInvite = async (member, inviteUrl) => {
  const context = await browser.newContext({ viewport: DESKTOP });
  const page = await context.newPage();
  await page.goto(inviteUrl);
  await settle(page);
  await page.click('a:has-text("Sign in to accept")');
  await page.waitForURL(/users\/log-in/, { timeout: 10_000 });
  await page.goto(`${BASE}/users/register`);
  await settle(page);
  await page.fill('input[name="user[display_name]"]', member.name);
  await page.fill('input[name="user[email]"]', member.email);
  await page.click('#registration_form button:not([type="button"])');
  await confirmMagicLink(page, await tokenFromMailbox(member.email));
  // The wizard invite joins the community; the group is one click more.
  await page.goto(groupUrl);
  await settle(page);
  await page.click('button[phx-click="join"]');
  await page.waitForTimeout(400);
  return { context, page };
};

// --- Feed interaction helpers, all scoped to the post's card
// .first(): a pinned post can render both in the pinned section and in
// the feed — interact with the topmost card.
const postCard = (page, text) =>
  page.locator('article[id^="post-"]', { hasText: text }).first();

const post = async (page, text, { ack = false } = {}) => {
  await page.goto(groupUrl);
  await settle(page);
  await page.fill("#composer_body", text);
  if (ack) {
    await page.check(
      '#composer_form input[type="checkbox"][name="post[acknowledgment_required]"]',
    );
  }
  await page.click('#composer_form button:not([type="button"])');
  await page.waitForTimeout(700);
};

const react = async (page, text, emoji) => {
  const card = postCard(page, text);
  // .first(): comments carry their own reaction bar — the post's comes
  // first in the card.
  await card.locator('button[title="Add reaction"]').first().click();
  await card
    .locator(`.dropdown-content button:has-text("${emoji}")`)
    .first()
    .click();
  await page.waitForTimeout(300);
};

const comment = async (page, text, body) => {
  const card = postCard(page, text);
  await card.locator('textarea[name="body_markdown"]').first().fill(body);
  await card
    .locator('form[phx-submit="create_comment"] button[type="submit"]')
    .first()
    .click();
  await page.waitForTimeout(500);
};

const vote = async (page, optionText) => {
  await page.goto(groupUrl);
  await settle(page);
  await page
    .locator(`button[phx-click="vote_poll"]:has-text("${optionText}")`)
    .first()
    .click();
  await page.waitForTimeout(300);
};

const acknowledge = async (page) => {
  await page.goto(groupUrl);
  await settle(page);
  await page.locator('button[phx-click="acknowledge"]').first().click();
  await page.waitForTimeout(300);
};

const rsvp = async (page, eventUrl, status) => {
  await page.goto(eventUrl);
  await settle(page);
  await page.locator(`button[phx-value-status="${status}"]`).first().click();
  await page.waitForTimeout(300);
};

// --- 1. First-run wizard (the real flow), operator = Frida
const fridaContext = await browser.newContext({ viewport: DESKTOP });
const frida = await fridaContext.newPage();

await frida.goto(`${BASE}/setup`);
await settle(frida);
await frida.fill('input[name="token"]', TOKEN);
await frida.click("#setup-token-form button");
await frida.waitForSelector('input[name="operator_email"]');
await frida.fill('input[name="operator_email"]', FRIDA.email);
await frida.fill('input[name="operator_display_name"]', FRIDA.name);
await frida.fill('input[name="instance_name"]', "Kammer");
await frida.click("#setup-instance-form button");
await frida.waitForSelector('input[name="community_name"]');
await frida.fill('input[name="community_name"]', COMMUNITY.name);
await frida.fill('input[name="community_slug"]', COMMUNITY.slug);
await frida.fill('input[name="group_name"]', "General");
await frida.fill('input[name="group_slug"]', "general");
await frida.click("#setup-community-form button");
await frida.waitForSelector("#invite-url", { timeout: 15_000 });
const inviteUrl = (await frida.textContent("#invite-url")).trim();

await confirmMagicLink(frida, await tokenFromMailbox(FRIDA.email));

// --- 2. Frida sets the stage: pinned welcome, ack notice, rehearsal
// notes, an event, the sealed board group, and sheet music in Files.
await post(
  frida,
  "Welcome to our new home 🎶\n\n" +
    "No ads, no algorithm — just us. Rehearsal notes live here, sheet " +
    "music goes in **Files**, and concerts are under **Events**.",
);
const welcome = postCard(frida, "Welcome to our new home");
await welcome.locator(".dropdown-end > button").click();
await welcome.locator('button[phx-click="toggle_pin"]').click();
await frida.waitForTimeout(400);

await post(
  frida,
  "We're moving to the new rehearsal room from **August** — same street, " +
    "twice the acoustics. Please acknowledge so I know everyone has seen " +
    "this. 🔑",
  { ack: true },
);

await post(
  frida,
  "Rehearsal notes — Thursday\n\n" +
    "- Warm-up, then a full run of the summer set\n" +
    "- New one: the ABBA medley — verses first, harmonies next week\n" +
    "- Bring the blue folder\n\n" +
    "Coffee duty: Benny ☕",
);

const startsAt = new Date(Date.now() + 9 * 24 * 60 * 60 * 1000);
await frida.goto(`${BASE}/c/${COMMUNITY.slug}/events/new`);
await settle(frida);
await frida.fill(
  'input[name="event[title]"]',
  "Summer concert — dress rehearsal",
);
await frida.fill(
  'textarea[name="event[description_markdown]"]',
  "Full run-through in concert dress. Doors at 18:30 for warm-up — " +
    "bring water and your black folder.",
);
await frida.fill(
  'input[name="event[starts_on]"]',
  startsAt.toISOString().slice(0, 10),
);
await frida.fill('input[name="event[starts_time]"]', "19:00");
await frida.fill('input[name="event[location_name]"]', "Sankt Markus Church");
await frida.click('#event_form button:not([type="button"])');
await frida.waitForURL(/events\/[0-9a-f-]+$/, { timeout: 10_000 });
const eventUrl = frida.url();
await rsvp(frida, eventUrl, "yes");

// The board's sealed group — visible in the sidebar, closed to everyone
// else, community admins included. That's the point.
await frida.goto(`${BASE}/c/${COMMUNITY.slug}/groups/new`);
await settle(frida);
await frida.fill('input[name="group[name]"]', "Bestyrelsen");
await frida.fill('input[name="group[slug]"]', "bestyrelsen");
await frida.selectOption('select[name="group[visibility]"]', "private");
await frida.check('#group_form input[type="checkbox"][name="group[sealed]"]');
await frida.click('#group_form button:not([type="button"])');
await frida.waitForTimeout(700);

// Sheet music: a folder and two (tiny but real) PDFs, uploaded via the UI.
const pdf = (title) =>
  "%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n" +
  "2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n" +
  "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 595 842]>>endobj\n" +
  `trailer<</Root 1 0 R>>\n%% ${title}\n%%EOF\n`;
const pdfPaths = ["abba-medley-satb.pdf", "summer-set-2026.pdf"].map((name) => {
  const path = join(tmpdir(), name);
  writeFileSync(path, pdf(name));
  return path;
});
await frida.goto(`${groupUrl}/files`);
await settle(frida);
await frida.fill(
  'form[phx-submit="create_folder"] input[name="name"]',
  "Sheet music",
);
await frida.click('form[phx-submit="create_folder"] button[type="submit"]');
await frida.waitForTimeout(500);
await frida
  .locator('button[phx-click="open_folder"]', { hasText: "Sheet music" })
  .click();
await frida.waitForTimeout(500);
await frida.setInputFiles('input[type="file"]', pdfPaths);
await frida.locator('form[phx-submit="upload"] button[type="submit"]').click();
await frida.waitForTimeout(1500);

// --- 3. The rest of the quartet joins via the invite link and lives in
// the space: a poll, votes, reactions, comments, RSVPs, acknowledgments.
const [agnetha, bjorn, benny] = await Promise.all(
  MEMBERS.map((member) => joinViaInvite(member, inviteUrl)),
).then((sessions) => sessions.map(({ page }) => page));

// Agnetha: the encore poll, plus her share of the fun
await agnetha.goto(groupUrl);
await settle(agnetha);
await agnetha.fill(
  "#composer_body",
  "Encore for the summer concert? Vote before Thursday 💃",
);
await agnetha.click('#composer_form button[phx-click="toggle_poll_builder"]');
await agnetha.fill(
  'input[name="post[poll][options][0][text]"]',
  "Waterloo (again)",
);
await agnetha.fill(
  'input[name="post[poll][options][1][text]"]',
  "Dancing Queen",
);
await agnetha.click('#composer_form button[phx-click="add_poll_option"]');
await agnetha.fill('input[name="post[poll][options][2][text]"]', "Surprise us");
await agnetha.click('#composer_form button:not([type="button"])');
await agnetha.waitForTimeout(700);
await vote(agnetha, "Waterloo (again)");
await react(agnetha, "Welcome to our new home", "❤️");
await acknowledge(agnetha);
await rsvp(agnetha, eventUrl, "yes");

// Björn: folder logistics and a vote for the other camp
await bjorn.goto(groupUrl);
await settle(bjorn);
// Anchor on "Coffee duty" — the welcome post also says "Rehearsal notes".
await comment(bjorn, "Coffee duty", "I'll bring the spare blue folder.");
await react(bjorn, "Coffee duty", "👍");
await vote(bjorn, "Dancing Queen");
await acknowledge(bjorn);
await rsvp(bjorn, eventUrl, "yes");

// Benny: reactions, a maybe, and a question for the conductor.
// (No acknowledgment from Benny — someone always has to be chased.)
await benny.goto(groupUrl);
await settle(benny);
await react(benny, "Welcome to our new home", "🎉");
await react(benny, "Coffee duty", "🎺");
await vote(benny, "Dancing Queen");
await rsvp(benny, eventUrl, "maybe");
await benny.goto(eventUrl);
await settle(benny);
await benny
  .locator('textarea[name="body_markdown"]')
  .first()
  .fill("Can we run the encore twice?");
await benny
  .locator('form[phx-submit="create_comment"] button[type="submit"]')
  .first()
  .click();
await benny.waitForTimeout(500);

// Frida breaks the tie herself
await vote(frida, "Waterloo (again)");

// --- 4. Capture, as the signed-in conductor
await frida.goto(groupUrl);
await settle(frida);
await shot(frida, "feed-desktop");

await frida.goto(`${BASE}/c/${COMMUNITY.slug}/events`);
await settle(frida);
await shot(frida, "events-desktop");

await frida.goto(eventUrl);
await settle(frida);
await shot(frida, "event-desktop");

await frida.goto(`${groupUrl}/files`);
await settle(frida);
await frida
  .locator('button[phx-click="open_folder"]', { hasText: "Sheet music" })
  .click();
await frida.waitForTimeout(500);
await shot(frida, "files-desktop");

await frida.goto(`${BASE}/`);
await settle(frida);
await shot(frida, "home-desktop");

const state = await fridaContext.storageState();

const dark = await browser.newContext({
  viewport: DESKTOP,
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
