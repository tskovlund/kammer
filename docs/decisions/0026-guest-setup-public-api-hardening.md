# ADR 0026: Hardening the guest/setup public API

Date: 2026-07-10
Status: accepted

## Context

Issue #185 shipped the account-less guest surfaces and first-run setup
over `/api/v1` (ADR 0013/0024), closely matching the LiveView routes.
Issue #230's follow-up mandate: diverge from that precedent wherever
the API's own shape makes a different design strictly better. Four
findings: a token-validity oracle (`POST /setup/verify-token`), no
rate limit on `POST /setup`, the setup token's body placement made by
default rather than deliberately, and the long-lived guest management
token traveling as a URL path segment — into every access log, proxy
log, and browser history entry.

## Decision

1. **Remove `POST /setup/verify-token`.** `complete` already validates
   the token on every submission (neutral 403), so the wizard
   validates on submit; no boolean oracle over the credential.
   `GET /setup` stays — the completed bit isn't a secret.
2. **Rate-limit `POST /setup`**: `RateLimit.hit_setup_ip/1`, a fixed
   10/hour/IP mirroring `hit_signup_ip/1`. Deliberately hardcoded — a
   security limit behind a config knob is a footgun, and pre-setup is
   exactly when no operator is around to notice it turned. The check
   runs in the controller before the body is inspected (unlike other
   limits, which live in contexts): a malformed body must burn budget
   too, which a context called after parameter matching cannot ensure.
3. **The setup token stays in the request body**, now as the deliberate
   choice: a one-shot bootstrap credential exchanged in a single POST —
   the confirm-token shape, not a standing `Authorization` credential —
   and body placement keeps it out of loggable URLs.
4. **The guest management token moves to `Authorization: Bearer`.**
   The six manage routes drop their `:token` segment; the shared API
   Bearer parser reads the header, and a missing or malformed header
   gets the same neutral 404 as an invalid token — the no-oracle
   property must hold for the header's presence, not just its content.
   The emailed link carries the token in the URL **fragment**
   (`…/guest/manage#<token>`), which browsers never transmit to any
   server; the PWA reads `location.hash` and attaches the header. The
   single-use confirm links keep their path token deliberately: they
   are magic-link-shaped (ADR 0003's accepted risk), consumed once,
   with none of the management token's standing exposure. The OpenAPI
   document gains a distinct `"guestToken"` bearer scheme for the six
   manage operations.

## Consequences

- Only a client of the removed `verify-token` endpoint needs updating;
  none shipped (the PWA screens for this surface come after this PR).
- The PWA guest-manage screen must read `location.hash` and send the
  Bearer header — deliberately different from the confirm-link
  pattern; don't copy-paste it by habit.
- No context-layer change: contexts still take the token as a plain
  string; only the controllers' transport changed (the ADR 0014
  boundary).

## References

Refines ADR 0013 and ADR 0024; issue #230, following #185/#229.
