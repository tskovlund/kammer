# HANDOFF — process, environment, and the backlog

Operating notes for continued work on Kammer. This is not a shipped-
feature log — that's CHANGELOG.md and git history. It's not the
product spec — that's SPEC.md, kept current in place. This file holds
what those two can't: process rules, environment gotchas, reusable
patterns, and the backlog of what's left, detailed enough to start
without re-deriving it. Update it when the backlog changes; don't let
shipped-feature narrative creep back in here.

Read order for picking this up cold: SPEC.md (what the product is),
this file (how to work on it, what's left), `docs/decisions/` (why
past calls were made), then open GitHub issues — owner comments there
override everything below.

## 1. Process (non-negotiable)

1. **One coherent PR at a time** into `main`; merge commits (squash
   only for noise); required checks: Conventional Commits, the
   quality gate, Docker image, Smoke test.
2. **`mix precommit` green before every push.** Hooks run it partly;
   CI fully. Never weaken a check to pass it.
3. **Authorization changes live in `lib/kammer/authorization.ex`
   only**, with context-level tests — property-based (StreamData)
   whenever an invariant is involved. The transport-parity property
   (`test/kammer_web/api/resources_test.exs`) must keep passing.
4. **Every user-facing string through Gettext, English AND Danish**
   (`mix gettext.extract --merge`, then fill `priv/gettext/da/`).
   API error messages are deliberately English-only (clients localize).
5. **Docs move with the change**: SPEC.md when a decision changes what
   the product is, CHANGELOG.md (`## [Unreleased]`) for what shipped,
   this file's backlog when scope moves. Issues too: close what's
   settled, comment status deltas, no stale debt.
6. **Decisions**: implementation choices are yours; product-shaping
   choices (pricing, naming, UX philosophy, new scope) go to a GitHub
   issue assigned to `tskovlund` with concrete options and a
   recommendation. Owner comments on issues override everything —
   read open issues at the start of every session.
7. **Architecture decisions get a one-page ADR** in `docs/decisions/`
   (context → decision → consequences) — only for calls a contributor
   would relitigate, not routine feature work.
8. **No hacks** (CONVENTIONS.md): a workaround needs a comment naming
   the external cause, a tracked completion path, and removal when the
   cause dies. When pressed, shrink scope, not quality.
9. Migration churn is welcome pre-0.1.0: design schemas properly
   rather than adding compatibility warts.

## 2. Environment traps (the ones that cost hours)

- The remote container: run `export PATH=/nix/var/nix/profiles/default/bin:$PATH`
  in every shell; `pg_ctlcluster 16 main start` after container
  restarts (stale pid is normal — Postgres also drops mid-session
  sometimes, same fix); commit/push inside `nix develop --command`
  (hooks need mix); committer identity must be
  `Claude <noreply@anthropic.com>`.
- **CSS cannot be built in the container** (the proxy blocks the
  Tailwind standalone binary; the npm CLI chokes on the vendored
  daisyUI bundle). CI builds assets; the **Screenshots workflow**
  (manually dispatched, never on `main`) regenerates
  `docs/screenshots/` on a PR branch and its commits trigger CI
  (pushes with `SCREENSHOTS_PUSH_TOKEN`).
- LiveView forms must be **fully driven by `to_form`** — any field not
  round-tripped through the change event resets on re-render.
- Swoosh test assertions pop the _next_ mailbox message — drain
  fixture-generated emails first (`drain_delivered_emails` helper).
- Route order matters: literal segments (`/events/new`) must be
  defined before wildcards (`/events/:event_id`) across live_sessions.
- ETS rate limiter is global across async tests — use unique emails
  per test (`System.unique_integer`).
- `phx-value-*` attributes are **not** merged into a native
  `change`/`submit` event's payload for bare `<input>`/`<select>`
  elements (only for click-type events, and for elements inside an
  actual `<form>`). A per-field control that needs to identify itself
  needs a real `<form>` wrapper with a hidden input, not a bare
  element with `phx-value-*`.
- If GitHub tool access shows as disconnected, it needs
  re-authorization from the owner (`claude mcp` / `/mcp` — cannot be
  done from an agent session); local git still works without it.

## 3. Patterns to reuse (don't reinvent)

- **Guest identities** (`Kammer.Guests`) are the substrate for any
  account-less interaction: guest comments, signup slots, newsletter
  subscriptions. Nullable FK + `num_nonnulls(...) = 1` check, cascade
  erasure, claim on sign-in.
- **Feature gate**: anything new that's per-group-toggleable adds a
  feature atom in `Group @features` (ships OFF by default) and calls
  `Authorization.feature_gate/2` at context entry points.
- **API**: `KammerWeb.Api.Serializer` is the only wire-shaping layer;
  `ApiError` the only error shape; `Pagination` the only cursor code.
  New endpoints follow the existing controller pattern — thin, all
  policy in contexts/authorization.
- **Comments/reactions** are one engine (ADR 0007) — reuse for any
  new commentable/reactable thing.
- **Non-access-control visibility redaction** (e.g. which profile
  fields a viewer sees) doesn't need to route through
  `Kammer.Authorization` — a small local predicate fed by
  `Authorization.relationship/2`'s role is fine (ADR 0020). Reserve
  the central module for actual access control (can this person reach
  this group/file/post at all).

## 4. Backlog

Roughly descending priority; owner has said to use judgment on
ordering within this list.

### Moderation gaps

Report surfaces beyond the group feed (event pages, assignment pages —
reuse the existing `Kammer.Moderation.report_post/comment` shape).
Full rate-limit coverage of posting/commenting/uploads (today's
`Hammer` usage covers magic-link issuance and a few guest endpoints;
audit `Kammer.RateLimit` call sites against SPEC §11's full list).

### Newsletter subscriptions

Guest identities subscribing to a public group's feed (ADR 0013's
email-only-identity pattern again): double opt-in, per-post or
daily/weekly digest choice, one-click unsubscribe
(`List-Unsubscribe` header), signed management link reusing the guest
manage page. Digest delivery can likely share `Kammer.Digests`'
cadence logic once the subscriber isn't a `User`.

### File search + text extraction

Remaining half of global search (posts/comments/events already ship).
Must ride the existing folder-permission invariant — a file's search
visibility can never exceed its folder's. Extracted text (PDF,
plaintext) via an Oban job, graceful skip on unsupported types, same
FTS index pattern as `Kammer.Search`.

### Rotations

Recurring duty rosters (SPEC §23): a roster of members + a rotation
rule (weekly/monthly), an Oban tick advances whose turn it is,
notification when it becomes your week. Needs its own schema (not a
fit for `Kammer.Assignments`, which is claim-based, not
rotation-based). Spec the exact rotation semantics in an issue before
building — "whose turn" gets ambiguous fast around skips/vacations.

### Branding UI

SPEC §13: instance name, logo, accent color, and default language
editable from settings, not just the first-run wizard.
`Kammer.Communities.update_instance_settings/2` already exists and is
already authorization-gated on `instance_operator: true` — this is
UI-only work on `/instance/settings` (already exists, ships the
content-minimized-email toggle) plus a logo upload (reuse the existing
upload-hardening pipeline). Per-community branding (name/accent
already editable at `/c/:slug/settings`) is unaffected — this item is
the instance-level fields only.

### Observability: Prometheus

SPEC §13: optional `/metrics` (Telemetry-backed, PromEx is the
obvious library — verify current maintenance status first per SPEC
§22's "boring, maintained" rule). Off by default; docs should be
explicit about what's exposed (no per-user data).

### ClamAV option

SPEC §11: optional AV sidecar for uploads, config-flag gated,
documentation explicit that signature-based AV is imperfect (don't
oversell it). `docker-compose.yml` gets an optional service; the
upload pipeline gets a scan-hook call point that no-ops when disabled.

### NixOS module

SPEC §14: the flake already provides the canonical dev shell; a
packaged NixOS module (systemd service, Postgres, reverse proxy
example) is the piece still missing, for anyone deploying via NixOS
rather than Docker Compose.

### Svelte PWA (ADR 0001 — owner has signed off, "go now")

File a decision issue for repo placement first (recommend
`clients/web/` in this repo — shared CI, atomic API+client PRs, one
tracker; separate repo only if CI time hurts). Then:

1. SvelteKit (static adapter) + TypeScript + a generated API client
   from `/api/v1/openapi.json` (openapi-typescript).
2. Multi-instance session-holder model (ADR 0001): instance list
   (add-by-URL), one device token per instance (localStorage), the
   merged Home view built by merging `GET /home` client-side across
   instances.
3. Screens in order: sign-in (magic-link request + exchange), merged
   Home, community list, group feed (read/compose/comment), events
   (list/detail/RSVP).
4. PWA manifest + service worker (app-shell only); Web Push later via
   the existing VAPID endpoints.
5. Its own CI job (node/pnpm/typecheck/vitest/build) — not inside the
   Elixir quality gate.
6. LiveView stays fully functional throughout — parity before any
   deprecation talk (ADR 0001 never authorized retiring it early).

### API completions (additive only, as clients need them)

Phoenix Channels realtime for API clients (same PubSub topics
LiveView already subscribes to; token auth on the socket).
Notification endpoints (list, mark-read). File endpoints (entries +
versions). Push-subscription registration for native/PWA clients
(VAPID infra already exists). Open decision for the owner: enable API
registration, or keep v1 web-only (current default)? Guest RSVP stays
web-only by design regardless — guests hold no device tokens.

### Native apps (after the PWA settles, not before)

Swift + Kotlin, thin clients generated from the OpenAPI document
(swift-openapi-generator / openapi-generator kotlin). Per platform: UI
shell, push (APNs/FCM), secure token storage.

### Smaller loose ends

- No per-post permalink exists yet, so RSS/Atom items and any
  "link to this post" affordance point at the group page, not the
  specific post. Revisit once posts get individual URLs.
- `instance_name` / `community_creation_policy` / `storage_policy` are
  still wizard-only with no post-setup edit UI (branding UI above
  covers `instance_name`; the other two would need their own small
  settings additions).

## 5. Standing operations

- Babysit every open PR to green CI, merge yourself. Renovate fires
  Mondays 07:00 CPH — non-major automerges when checks pass, majors
  wait for the owner.
- Owner-court items, leave alone unless asked: #7 (real-machine test
  drive), #8 (human review pass), #9 (miles deploy), #22 (business
  model — act on answers when they arrive).
- Release: owner cuts v0.1.0 after #7, via docs/release.md. Fix
  forward, never re-tag.
- Naming (SPEC §15) and final business-model calls (issue #22) are
  owner-court — raise before acting, never decide them yourself.

## 6. Definition of done, every PR

`mix precommit` green · EN+DA strings · authorization changes in the
single module + property tests where an invariant is involved ·
ADR only if architecture-shaping · CHANGELOG `## [Unreleased]` entry ·
SPEC.md updated if a product decision changed · this file's backlog
updated if scope moved · issues updated/closed · PR description says
what and why.
