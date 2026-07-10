/**
 * Whether a user-entered URL is safe to render as a raw `<a href>`
 * (issue #247): only `http`/`https` may become clickable —
 * `javascript:`/`data:` execute same-origin on click, and
 * `rel="noopener noreferrer"` does not neutralize them. Returns the
 * URL unchanged when safe, `null` otherwise (callers fall back to
 * plain text).
 *
 * An anchored scheme allowlist, not `new URL()` parsing, on purpose:
 * the href's security is decided entirely by the scheme, and this
 * mirrors the server's `Kammer.Validation.http_url?/1` — WHATWG
 * parsing accepts forms the server rejects (`https:example.com`) and
 * vice versa, which made the two guards disagree about the same
 * stored row. (The mirror isn't byte-for-byte — trim semantics
 * differ on exotic Unicode whitespace — but every divergence fails
 * closed: rejected values render as plain text, never as a link.)
 */
const HTTP_URL = /^https?:\/\/[^\s/]/i;

export function safeHttpUrl(url: string | null | undefined): string | null {
	if (!url || !HTTP_URL.test(url.trim())) return null;
	return url;
}
