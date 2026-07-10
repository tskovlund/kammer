import { PWA_BASE, PHOENIX_BASE } from './scenario.js';

interface SwooshMessage {
	to: { email: string }[] | string[];
	text_body: string;
}

// The setup wizard's magic link points at the PWA's own deep-link route
// (`KammerWeb.Api.PublicLinks.sign_in_url/2`: `pwa_url(conn, "/sign-in/"
// <> token)`, i.e. `{PWA_BASE}/sign-in/{token}`) — not the LiveView-era
// `/users/log-in/{token}` scripts/screenshots.mjs still matches for the
// smoke test. Both mechanisms coexist (ADR 0024); this suite drives the
// PWA only, so it must match the link this instance actually sends.
const MAGIC_LINK_PATTERN = new RegExp(`${PWA_BASE}/sign-in/([\\w-]+)`);

/**
 * Polls the dev-only Swoosh mailbox preview (`/dev/mailbox/json`, only
 * mounted when `mix phx.server` runs in `:dev` — see `router.ex`) for the
 * magic-link email sent to `email`, and returns the sign-in token.
 */
export async function waitForMagicLinkToken(email: string): Promise<string> {
	for (let attempt = 0; attempt < 20; attempt++) {
		const response = await fetch(`${PHOENIX_BASE}/dev/mailbox/json`);
		const { data } = (await response.json()) as { data: SwooshMessage[] };
		const message = data.find((candidate) =>
			candidate.to.some((to) => (typeof to === 'string' ? to : to.email).includes(email))
		);
		const match = message?.text_body.match(MAGIC_LINK_PATTERN);
		if (match) return match[1];
		await new Promise((resolve) => setTimeout(resolve, 500));
	}
	throw new Error(`no magic link for ${email} in /dev/mailbox/json`);
}
