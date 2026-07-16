# ADR 0024: The Svelte PWA replaces LiveView entirely

## Context

ADR 0001 made LiveView the v1 vehicle and already said it would be
"frozen and retired" once the Svelte client landed, but day-to-day
work kept treating the two UIs as long-lived siblings, with LiveView
still accreting features. The owner confirmed (2026-07-09) the
sharper reading: the Svelte PWA — and the native apps that follow it
per ADR 0022 — is the real product; LiveView was a first-build
stepping stone and will be **removed from the repo**, not maintained
alongside. The forcing drivers are capabilities LiveView cannot
have: offline mode (ADR 0022) and multi-instance session-holding
with client-side merging (ADR 0023) — a server-rendered UI can be
neither.

## Decision

The Svelte PWA becomes the product UI; LiveView is deleted once the
PWA reaches full parity. Owner-confirmed parameters:

- **Instance-served hosting**: the Phoenix release bundles and
  serves the built PWA at the instance's own domain. Magic links
  land in the PWA; multi-instance merging works from any deployed
  copy via CORS (#164).
- **Freeze + parity ladder**: LiveView is feature-frozen **now**
  (bugfixes only). The PWA climbs surface-by-surface, and each
  surface ships with full write parity — including the API
  endpoints it is missing (reactions, poll votes, attachments,
  acknowledgments, slots are LiveView-only today) — before the next
  surface starts. LiveView is removed in one cut at full
  member+admin+guest coverage, not incrementally.
- **Guest surfaces** (guest RSVP/comment/claim links, newsletter
  unsubscribe, legal pages, setup wizard) move into the PWA on new
  public API endpoints as their turn on the ladder comes. RSS/iCal
  stay plain HTTP feeds.
- **PWA-native sign-in**: the email link deep-links into the
  instance-served PWA (`/sign-in/{token}`), which calls the exchange
  endpoint; emails also carry a short code for cross-device sign-in
  (a new short-code token variant server-side). Passkeys ship in
  client v1 via new API challenge/verify endpoints.
- **Community-first IA**: users shouldn't care about instances as
  an abstraction — merged views and per-community views are both
  easy, and provenance is shown as community, not server.
- **Phoenix Channels realtime** from day one of the client
  foundation (device-token socket auth).
- **Client v1 quality bar**: dark mode, EN+DA i18n,
  reduced-motion-respecting subtle interactions, in-repo app icon.
- **Native apps** (Kotlin/Swift, ADR 0022) come strictly after PWA
  parity, generated from the same OpenAPI document.

Tracking: #165 is the transition umbrella; #30 the near-term API
slice; #32 the client work.

Alternatives rejected: a **permanent LiveView companion** (ADR 0001
already named dual-UI maintenance a trap, and LiveView can never do
the offline/multi-instance core); a **central-hosted-only client**
(breaks self-hosting ethos, and magic links must land somewhere
every instance is guaranteed to have — its own domain);
**incremental LiveView removal** (a half-removed UI leaves every
in-between state broken for whoever the missing half serves; one
cut at full coverage is honest).

## Consequences

- Supersedes ADR 0001's v1/v2-coexistence framing (its context-first
  architecture stands and is what makes this pivot cheap) and
  sharpens ADR 0012: the PWA is not the pre-native stopgap, it is
  the product.
- Every PWA surface arc includes its missing API endpoints — API
  parity is part of each rung, not a separate project.
- LiveView freeze policy: bugfix-only, no new features, no polish
  passes. Recorded in AGENTS.md so future sessions don't drift.
- Open LiveView-only audit findings (cosmetic/template-level) are
  deprioritized — noted on the issues themselves, not just here.
- SPEC.md §1, §16, and §21 are corrected to stop describing LiveView
  as the product UI.

## Update — removal cut landed (2026-07-13, issue #187)

The one-cut removal in this ADR's Decision is **done**. The entire
`lib/kammer_web/live/` tree, the LiveView-only web layer (components,
layouts, the CSP-nonce plug, the server `assets/` esbuild/Tailwind
pipeline), and the LiveView-supporting controllers whose capability had
already reached the JSON API were deleted; the `phoenix_live_view`,
`phoenix_live_dashboard`, `phoenix_live_reload`, `heroicons`, `esbuild`,
`tailwind`, and `lazy_html` dependencies went with them. The PWA base
flipped from `/app` to `/` (`:pwa_base_path`, `paths.base`, the web
manifest, and every email/redirect producer), and the router's PWA
catch-all moved to the end so it shadows neither the API nor the feeds.
A data migration rehomed the community file space (a LiveView-only
surface) onto each community's oldest group. `KammerWeb.UserAuth` shrank
to a session reader, since browser sign-in was already an API
device-token flow. What remains server-rendered: the JSON API, the
ICS/RSS/Atom feeds, `/healthz`, newsletter unsubscribe, and the PWA
document itself (`PwaController`).
