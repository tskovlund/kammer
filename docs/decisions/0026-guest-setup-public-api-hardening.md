# ADR 0026: Hardening the guest/setup public API

Date: 2026-07-10
Status: accepted

## Context

Issue #185 shipped the account-less guest surfaces (RSVP, signup-slot
claim, comment, newsletter) and first-run setup over `/api/v1`
(ADR 0024's parity ladder), tokenless by design (ADR 0013: the signed
link is the whole credential). That PR matched the existing LiveView
routes closely rather than re-deriving the shape from scratch. Issue
#230 asked for a follow-up hardening pass with a mandate to diverge
from the LiveView precedent wherever the API's own shape (a stateless,
machine-consumed contract with no session or Referer suppression from
a browser chrome) makes a different design strictly better. Four
findings came out of that review:

1. `POST /api/v1/setup/verify-token` is a boolean oracle over the
   setup credential: it answers `{valid: true|false}` for any
   candidate string, which is exactly the shape a credential-guessing
   loop wants, and `complete` already re-validates the token itself.
2. `POST /api/v1/setup` had no rate limit, unlike every other
   credential-bearing public endpoint in this API (magic link, login
   code, signup, guest requests all have one).
3. The setup token travels in the request body — worth confirming
   deliberately rather than by default.
4. The guest **management** token — long-lived, unlike the single-use
   confirm tokens — travels as a URL path segment
   (`/guest/manage/{token}`), which lands it in every access log,
   proxy log, and browser history entry between the emailed link and
   the PWA.

## Decision

**1. Remove `POST /api/v1/setup/verify-token`.** `SetupController.complete/2`
already calls `Setup.valid_token?/1` before doing any work and answers
a neutral 403 on a bad or missing token — the same check the removed
endpoint duplicated, minus the oracle. The wizard validates on submit
instead of pre-flighting a check. `GET /api/v1/setup` (`status`)
stays: it reports only the completed bit, which the browser's
`require_setup` redirect already reveals to an unauthenticated caller,
so it isn't a secret.

**2. Rate-limit `POST /api/v1/setup`.** `Kammer.RateLimit.hit_setup_ip/1`
adds a fixed 10-per-hour-per-IP budget, mirroring `hit_signup_ip/1`
exactly — same shape, same constant-per-hour window, `nil -> {:allow,
0}` for an unknown remote IP. It is deliberately a hardcoded constant
with no runtime config knob: a security limit that an operator (or an
attacker who reaches instance settings) can dial to infinity is a
footgun, and the pre-setup window is exactly when there is no operator
around yet to notice the knob got turned. This is defense-in-depth —
the setup token is the real gate — for the one window in an instance's
life where there's no account holder to notice abuse.

**3. The setup token stays in the request body.** Unlike the
management token below, it's a one-shot bootstrap credential exchanged
in a single POST, structurally the same shape as the confirm tokens
guests submit — not a long-lived bearer credential presented on every
request, so it is not the right fit for an `Authorization` header
(that scheme is for a caller re-authenticating a series of requests
with a stable credential; setup happens exactly once). Body placement
also keeps it out of any URL that could be logged, cached, or
`Referer`-leaked before the one submission that consumes it.

**4. The guest management token moves from the URL path to
`Authorization: Bearer`.** The six manage routes
(`/api/v1/guest/manage`, `/rsvps/{event_id}`, `/claims/{claim_id}`,
`/subscriptions/{subscription_id}`, both directions) drop their
`:token` path segment; `GuestController.fetch_manage_token/1` reads
the token from the first `authorization` request header, parsing a
`Bearer <token>` scheme case-insensitively with surrounding whitespace
trimmed. A missing or malformed header answers the exact same neutral
404 (`invalid_link/1`) an invalid token already gets — the no-oracle
property (ADR 0013's original design goal) has to hold for the
header's mere *presence* too, not just its content, or the header
becomes a side channel of its own.

`PublicLinks.manage_url/2` emails a link with the token in the URL
**fragment** — `.../guest/manage#<token>`, not `.../guest/manage/<token>`
— the same technique OAuth's implicit grant and most password-reset
flows use to keep a bearer credential out of any server's view. A
fragment is never transmitted in an HTTP request to any origin or
intermediate proxy; only client-side JavaScript reads it
(`location.hash`). The PWA reads the fragment when the guest opens the
link and attaches it as `Authorization: Bearer <token>` on every
manage call, instead of a URL segment persisting in server access
logs and the browser's history for as long as the guest identity
exists (which, unlike the confirm tokens, is indefinite — cleared only
by the guest's own erase action).

**The single-use confirm links (`/guest/rsvp/confirm/{token}`,
`/guest/claim/confirm/{token}`, `/guest/comment/confirm/{token}`,
`/newsletter/confirm/{token}`) are an accepted, deliberate exception
and keep their token in the path.** They are consumed exactly once —
structurally a magic link, the same risk shape ADR 0003 already
accepted for sign-in — so they don't accumulate the same standing
exposure a management token does by staying valid indefinitely. Moving
them to a fragment+header scheme would add complexity (the PWA would
need a one-off client-side redirect-and-attach dance for a token it
uses exactly once) without a matching security gain.

The OpenAPI document gains a second security scheme, `"guestToken"`
(`http`/`bearer`, distinct from the account `"bearer"` scheme —
different credential, different authorization scope), applied to the
six manage operations in place of `security: []`; their `token` path
parameter is removed accordingly.

## Consequences

- The setup and guest-confirm request shapes are unchanged for any
  client that already only calls `complete`/`confirm_*` — only a
  client that called the now-removed `verify-token` endpoint needs an
  update, and no client shipped before this PR (the PWA screens for
  this surface haven't landed yet, per #185's CHANGELOG note).
- The PWA's guest-manage screen (not yet built) must read the token
  from `window.location.hash` on load rather than a route param, and
  attach it as a Bearer header on every manage call — a small but
  real client-side difference from every other path-token flow in
  this API, worth calling out explicitly when that screen is built so
  it isn't copy-pasted from the confirm-link pattern by habit.
- `Kammer.RateLimit` gains one more fixed, non-configurable IP budget,
  consistent with the existing `hit_signup_ip/1`/`hit_guest_ip/1`
  precedent and the project's stance against config-driven security
  limits.
- No context-layer code changed: `Kammer.Guests`, `Kammer.Events`,
  `Kammer.Newsletters`, and `Kammer.Setup` all still take a token as a
  plain string argument. Only the controllers' *transport* — where
  that string comes from on the request — changed, which is exactly
  the boundary ADR 0014 draws between the API layer and the contexts
  it calls.

## References

- Refines ADR 0013 (guest identities and the signed-link lifecycle)
  and ADR 0024 (the guest/setup API surface itself).
- Issue #230 (this hardening pass), following #185/#229 (the initial
  guest/setup API PR).
