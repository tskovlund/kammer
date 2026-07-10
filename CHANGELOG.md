# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Account-less guest surfaces, newsletter, legal pages, and first-run
  setup over the JSON API (issue #185, the server half of the last
  #165 parity rung before the LiveView cut). These flows stay tokenless
  by design (ADR 0024): a guest holds no device token, so the signed
  link in the URL is the whole credential (ADR 0013) and the endpoints
  live in the public API, never behind Bearer auth. Guests may RSVP to
  a public event, claim a signup slot, and comment (each a request →
  emailed confirm link → record two-step flow), then reach one
  management page — behind their signed management link — that lists
  and changes every RSVP, claim, comment, and newsletter subscription
  they created, or erases all of it (SPEC §6/§8/§12). Newsletter
  subscribe/confirm mirror the same shape; the RFC 8058 one-click
  unsubscribe stays a plain-HTTP endpoint (mail clients POST the exact
  header URL) and is deliberately not duplicated. A public read
  endpoint serves the privacy and imprint legal pages (operator text or
  the built-in template). First-run setup is exposed over the API using
  the _existing_ operator-bootstrap credential — the setup token
  printed to the server logs — with no new secret: a status probe, a
  token check, and a one-shot complete that creates the operator,
  instance settings, first community and group, and invite link, then
  locks setup permanently. Every flow runs the same context function,
  authorization, and rate limit the LiveView flows use; an invalid,
  expired, or used token gets one neutral answer, never an oracle.
  OpenAPI operations, schemas, and conformance taps included; PWA
  screens follow as the client half.
- Guest, newsletter, legal, and first-run setup screens in the PWA
  (issue #185, the client half of the surfaces above): every route the
  guest/newsletter emails and the setup flow link to, all top-level and
  unauthenticated since these guests and operators hold no device
  token (ADR 0024). The RSVP, signup-claim, comment, and newsletter
  confirm links each POST their token once and show a neutral
  confirmed/error state (a full slot on claim confirm gets its own
  message rather than the generic "link invalid," since the API
  already distinguishes it). The guest management page lists RSVPs,
  claims, comments, and subscriptions behind a signed management link,
  lets a guest change an RSVP or subscription cadence, release a claim,
  unsubscribe, or erase everything — erasure requires an explicit
  in-page confirm step with focus moved to it and returned to the
  trigger on cancel, given how irreversible it is. Unlike the
  single-use confirm links, the management token is long-lived (issue
  #230, ADR 0026), so the emailed link carries it in the URL
  _fragment_ rather than a path segment — the page reads it from
  `window.location.hash` and sends it as an `Authorization: Bearer`
  header, never a URL, so it never lands in access logs, proxy logs,
  or `Referer`. Legal pages (privacy/imprint) render through the same
  sanitized Markdown component the feed uses. The first-run setup
  wizard mirrors `SetupLive.Wizard`'s field set (operator/instance →
  community/group → done) so the two stay interchangeable while
  LiveView setup still exists; there is no separate token-verification
  step (issue #230) — the setup token rides the operator step's form
  and is only actually checked on the final `POST /setup`, with a bad
  or expired one surfaced as a neutral error on that step rather than
  a pre-flight yes/no. EN + DA throughout; public event/group/post
  browsing and the initial guest RSVP/claim/comment _request_ forms
  are out of scope here — they need tokenless content-read endpoints
  for `public_listed` events/groups/posts that don't exist yet, left
  as remaining #185 scope rather than a new issue.
- Collaborative tools and global search in the PWA (issue #184, the
  client half of the #165 parity rung): the Svelte screens over the
  API above. Each group surfaces the tools it has turned on (ADR 0016)
  — Availability polls (list, create, answer a candidate date, close or
  convert the winning date into an event), Assignments (the task list:
  create, claim/release, complete/reopen, delete, and per-task
  discussion), and the Decisions register (browse, raise a motion,
  record its outcome). A global search entry queries every community
  across all signed-in accounts and presents hits community-first (SPEC
  §10) over posts, comments, events, and files. Every control is gated
  on the resource's `viewer_can` so a button that would 403 is never
  shown; per-action failures surface inline without discarding the
  screen. EN + DA throughout.
- Collaborative tools and global search over the JSON API (issue #184,
  the #165 parity rung): the per-group tools the client previously had
  no way to reach, each behind its group feature toggle (ADR 0016) so a
  disabled tool is unreachable. Availability polls — list the open
  polls, create one, answer a candidate date, and close it plainly or
  by converting the winning date into an event. Assignments — the group
  task list, create/edit/delete, claim/release, complete/reopen, and
  the shared comment engine (ADR 0007). The decisions register — browse
  it, raise a motion (a feed post carrying the default For/Against/
  Abstain vote), and record the outcome. Global search — one
  community-scoped endpoint over posts, comments, events, and files,
  applying the exact listing-visibility and folder-permission narrowing
  the context already enforces, so a result never surfaces what the
  viewer couldn't already see. Every endpoint enforces authorization in
  the context, hides a resource the caller may not see behind a 404 (no
  oracle), carries a `viewer_can` capability list, and ships OpenAPI
  operations with inline conformance taps.
- Management and moderation over the JSON API (issue #183, the #165
  parity rung): the community-admin and instance-operator surfaces the
  client previously had no way to reach. Moderation — the open report
  queue, resolve (removes the content) or dismiss a report, community
  email bans (list/add/lift), and the append-only audit log. Community
  settings updates (name, slug, branding, locale, listing and
  real-name policy). Group management — create, edit settings, toggle
  features (ADR 0016), and archive/unarchive. Instance operator
  settings — read and update the singleton (community-creation policy,
  storage policy, default locale, instance name, content-minimized
  emails). Every endpoint enforces authorization in the context, hides
  rows the caller may not act on behind a 404 (no oracle), and ships
  OpenAPI operations with inline conformance taps.
- Management and moderation screens in the PWA (issue #183): the client
  side of the management rung — a moderation queue (resolve or dismiss
  reports, lift bans), community-settings and group-settings screens,
  and capability-gated entry links on the group page. Every control is
  shown only when `viewer_can` says it would succeed, so a stale
  capability degrades to a graceful "not allowed" rather than a broken
  button. EN + DA.
- Invite issuance is now rate-limited (issue #97): a community/group
  admin may send at most 20 email invites per hour, enforced in
  `Kammer.Invitations` before any row is written or mail delivered, so
  the invite endpoint can't be turned into an arbitrary-recipient
  email relay. A refused invite returns the `rate_limited` code (HTTP
  429). Link invites, which send nothing, are never limited.
- The last owner of a community can no longer demote themselves into
  an unrecoverable ownerless state (found by the #182 people-API
  review): `PUT .../members/{id}/role` refuses it with `422 last_owner`.

- Membership, profiles, and the member directory over the API (#182,
  part of the #165 parity ladder): invite issue/list/revoke and a
  public preview + accept flow that reports required custom profile
  fields still missing (ADR 0020); community and group membership
  lifecycle (leave, policy-aware group join, join-request queue, role
  changes, removals); the member directory with per-viewer field
  redaction and custom-field filters; own profile and per-community
  custom-field answers read/update; per-group notification levels; and
  device management — listing and revoking browser sessions and API
  device tokens by id, with revocation severing the device's live
  sockets (closes #174: API device tokens were invisible to their
  owner, and the devices page now lists and revokes them too). Group
  and community payloads gained `my_role`, `join_policy`, and
  join/request-to-join capabilities in `viewer_can`. In the PWA: the
  Groups tab became a per-community directory hub (visible groups with
  roles, plus Members/Invites links gated by `viewer_can`); a member
  roster screen with custom-field filters and admin role/removal
  controls; an admin invite screen (shareable links, email invites,
  revocation); the group page gained join/request-to-join, leave, and
  a per-group notification-level selector; and the You tab gained
  per-account Profile (base profile, contact visibilities, and each
  community's custom fields with the required-fields nag) and Devices
  (list + revoke) screens. EN+DA throughout.

### Changed

- Test-suite prune (T2 of the #208 overhaul, per the #207 standard):
  ~30 ceremony/duplicate tests removed or merged across the LiveView,
  core-context, worker, and API suites — presentation trivia on the
  feature-frozen LiveView UI (empty states, link-visibility checks,
  "renders page" smokes, nav-click tests, `layouts_test.exs` and
  `error_html_test.exs` wholesale), phx.gen.auth Ecto boilerplate, the
  third/fourth duplicates of the #167 provenance rule, and the
  unfalsifiable `update_check_worker_test`. Defused the #187 coverage
  time bomb: tests for surviving HTTP endpoints (ICS calendar feeds,
  file download incl. anonymous denial, RFC 8058 one-click
  unsubscribe) moved out of death-row LiveView flow files into new
  `calendar_controller_test.exs`, `file_controller_test.exs`, and
  `newsletter_controller_test.exs`. The API conformance suite was
  restructured to the inline-tap idiom: `assert_operation_response`
  now taps the real interaction tests (posts/comments, events,
  notifications, push subscriptions, auth incl. the passkey ceremony —
  adding previously missing taps for `auth_register`,
  `auth_request_link`, and `auth_revoke`), and
  `schema_conformance_test.exs` shrank to the read-only operations
  with no other home. Several half-asserted tests were sharpened
  rather than deleted: the event-reminder test now proves the no-RSVP
  member got nothing, the reschedule test proves the new job carries
  the new start time and no stale email went out, the guest-RSVP token
  test now exercises a genuinely expired token, the recurrence
  cancel-authz test probes a fellow member instead of a stranger, and
  the User inspect test now actually sets the redacted `ics_token`.

### Fixed

- Guest/setup public API hardening (issue #230, refining #185/#229 —
  the owner asked for a "do it properly" pass rather than matching the
  LiveView precedent). `POST /api/v1/setup/verify-token` is removed:
  it was a boolean oracle over the setup credential, and `complete`
  already validates the token itself before doing any work. `POST
/api/v1/setup` is now rate-limited per IP (10/hour, fixed — no
  config knob, same stance as every other security limit in
  `Kammer.RateLimit`), defense-in-depth for the one window in an
  instance's life with no operator around to notice abuse. The guest
  **management** link's token — long-lived, unlike the single-use
  confirm tokens — moved from a URL path segment
  (`/guest/manage/{token}`) to an `Authorization: Bearer` header
  (`/guest/manage`, read via `GuestController.fetch_manage_token/1`):
  a path segment for a credential that stays valid indefinitely was
  leaking into server/proxy access logs, browser history, and
  `Referer`. The emailed management link now carries the token in the
  URL fragment instead, which browsers never send to any server; a
  missing, malformed, or forged Authorization header answers the same
  neutral 404 an invalid token already did — checked before any
  request-shape validation, so the request body can never be probed
  without an authentic token. This covers the API surface; the
  recurring newsletter emails still carry a manage token in their URL
  and `List-Unsubscribe` header and are hardened separately. See ADR
  0026 for the full reasoning, including why the setup token and the
  single-use guest confirm links deliberately keep their current
  transport.
- Email-change confirmation is now rate-limited (issue #97,
  security-hardening pass): any signed-in user in sudo mode could loop
  the account-settings email form to send the branded confirmation to
  arbitrary addresses (an email-flooding relay) and pile up
  never-cleaned token rows. Issuance is now capped per acting user
  (five per hour) in the `Accounts` context, checked before any token
  is written or mail sent — a refused request does neither.
- The test suite no longer deadlocks intermittently on the
  instance-settings singleton (issue #215): the row is seeded once in
  the test bootstrap, so concurrent sandboxed transactions never race
  the lazy unique-index insert (production was already safe — the
  insert is an idempotent upsert).
- Deleting a folder that contained files crashed (a foreign-key
  cascade interplay deleted the folder's file entries out from under
  their stored files) instead of honoring the documented semantics —
  files fall back to the space root and outlive their folders. A
  migration releases folder contents on delete, and the same-name
  entry lookup now tolerates the sibling entries a release can create.
  Found by the new API folder-deletion success test (part of #208).

### Added

- Trusted reverse-proxy support (issue #162, security-hardening pass):
  a new `TRUSTED_PROXIES` env var (comma-separated IPs/CIDRs) names
  the proxies allowed to speak for clients. When the TCP peer is on
  the list, the real client IP is recovered from `X-Forwarded-For`
  (rightmost address that isn't itself a trusted proxy) and rate
  limits key on it — signup, magic-link, sign-in-code, and guest
  budgets become per-client again instead of instance-wide behind a
  proxy. From anyone else the header is ignored entirely, so a client
  that reaches the port directly can't spoof its way past the limiter;
  unset (the default) ignores the header everywhere, and an invalid
  entry fails the boot. Applied on both the plug pipeline
  (`conn.remote_ip`) and the LiveView socket path (`peer_data` +
  `x_headers` connect info). Hand-rolled rather than the `remote_ip`
  hex package (SPEC §22's minimal-internal-version rule): that
  library honors forwarding headers without ever checking the peer
  and treats all private/loopback ranges as implicit proxies — the
  two defaults #162 exists to close.
- Product-version surface (issue #204, implementing the ratified
  versioning strategy #203): `mix.exs` is now the explicit single
  source of truth (`0.1.0-dev` until the first tagged release),
  exposed at runtime through `Kammer.version/0` so no code hardcodes
  it, and the public `GET /api/v1/instance` capability endpoint —
  already the RFC 0001 discovery surface carrying `version` and
  `api_versions` — additionally reports `min_client_version` (null
  until a release needs to fence out old clients), the foundation the
  future native-app handshake (#131) negotiates against. The PWA's
  You screen shows each signed-in instance's server version as a
  small about line (EN + DA).
- Client test additions from the test-suite audit (#208): XSS
  assertions for `renderInlineMarkdown` — the comment-body route into
  the PWA's single `{@html}` sink previously had zero sanitization
  tests (raw-HTML escape, `javascript:`/`data:` link refusal, image
  downgrade, no block elements); the untested rollback mirrors —
  `feed-store.reactComment`'s conditional rollback (clean and
  echo-intervened branches) and the event store's optimistic RSVP
  snapshot rollback (new `event-store.spec.ts`); the feed store's
  load-401 → `noteInstanceAuthFailure` socket bridge (mock was wired
  but never asserted); and the one no-observable-assertion test
  (`requestLink` "resolves on success") strengthened to assert the
  POSTed endpoint, method, and body.
- Per-viewer capabilities on the API (issue #199, groundwork for the
  #165 parity ladder): serialized posts, groups, and communities now
  carry a `viewer_can` array naming the action-oriented rights the
  calling viewer actually has — `edit`/`delete`/`pin`/`moderate` on a
  post; `post`/`moderate`/`manage_group`/`manage_members`/`create_event`/
  `upload_file` on a group; `manage_community`/`create_group`/
  `view_member_directory` on a community — so clients can hide controls
  a viewer would only be `403`ed on click, instead of offering them to
  everyone. Each capability is computed from the same pure
  `Kammer.Authorization` decision the controllers enforce (present IFF
  the action would succeed) and adds no queries: controllers thread the
  viewer's already-loaded relationship into the serializer. Consumed by
  the #179/#182/#183 client screens (client wiring is a follow-up; the
  API field is the enabler).
- Test-suite audit follow-up, security & correctness batch (part of
  #208, per the #207 standard): domain-level authorization negatives
  that were the only gate on their function (`Feed.approve_post/2`,
  `Files.delete_file/2`); an archived-groups property extension over
  the membership/admin actions (`join`, `request_to_join`,
  `create_group_invite`, `approve_group_members`) whose archived
  guards no test protected; a home-feed test pinning that pending and
  scheduled posts never leak into other members' home feeds; four
  promise-breaking tests made real (the decisions register-entry
  rollback is now actually induced, the `User` inspect test now sets
  the one redacted field, the ADR 0016 gate test now queries the
  unauthorized viewer and the nonexistent-event surface, the passkey
  stale-sign-count test is named for the bookkeeping rule it pins);
  GDPR coverage for the export controller route and for
  comments/uploaded files in the export zip plus comment anonymization
  on erasure; API coverage for folder-deletion success and
  `DELETE /events/{e}/slots/{slot_id}` with their conformance taps;
  pagination edge-contract assertions (garbage cursor, absurd limit);
  an events-write leg on the transport-parity property; and
  `file_versions_test.exs` no longer runs async while swapping the
  global uploads path.
- Files over the API and in the Svelte PWA (issue #181, part of the
  #165 parity ladder): a group's file library — browse folders and
  files with breadcrumb navigation, upload new files, re-upload the
  same name as a new version (ADR 0017), view version history and
  download any version, and — for managers — create/delete folders,
  set the read/write preset overrides (ADR 0009), and delete files and
  versions. New `/api/v1/communities/{c}/groups/{g}/files` and
  `/folders` endpoints (list/detail/upload/version-upload/delete plus
  folder create/override/delete), all through the existing
  `Kammer.Files` context so the folder-permission invariant is enforced
  in one place; genuinely no-oracle (a folder or file the caller can't
  see 404s to every verb, never 403), the per-file size/quota 413 is
  honored on this path too, and the group file space stays behind the
  files feature toggle (ADR 0016). A files screen inside each group in
  the PWA — folder browsing, upload, version history, download — with
  EN + DA, dark mode, reduced-motion, and AA contrast.
- Events over the API and in the Svelte PWA (issue #180, part of the
  #165 parity ladder). API: full write parity under `/api/v1` —
  create an event or a bounded recurring series
  (`POST .../groups/{group}/events`, ADR 0019; the response is the
  first occurrence carrying its `series_id`), edit this occurrence and
  delete (creator/moderator), per-occurrence cancel/reinstate
  (`.../cancellation`), signup slots (add/delete for managers, claim
  and release for members — a full slot refuses with `422 slot_full`,
  never overbooking), and the shared comment engine on events
  (create/edit/delete/react). The `Event` serializer now carries
  `series_id`, `cancelled`, `comments_locked`, and its `comments`. PWA:
  an Events tab (merged upcoming events across every account, bucketed
  by community with filter chips and a calm agenda view) and an
  addressable event detail screen (RSVP with counts, signup slots,
  comments, an "add to calendar" ICS link) with a create/edit form for
  authorized roles. EN + DA, dark mode, reduced-motion, AA. Every event
  write is genuinely no-oracle (issues #156/#161): an event the caller
  can't see answers `404` to every verb, never `403`, so a hidden event
  is indistinguishable from a nonexistent one.
- Reacting to a comment that hangs off an event or an assignment no
  longer crashes (`Kammer.Feed.toggle_reaction/3` resolved the host
  group only for post comments); it now resolves the group for every
  comment kind via `comment_context/1`, and only post reactions
  broadcast a feed update.
- Home and group feed screens in the Svelte PWA (issue #179, part of
  the #165 parity ladder): the merged, community-first Home (recent
  activity and upcoming events across every added account, bucketed by
  community with filter chips and per-instance failure banners) and the
  group feed — chronological/activity sort, pinned-first, cursor
  pagination, and live updates over the #173 realtime channels. Full
  write parity on the #178 endpoints: a composer with Markdown (safely
  rendered — `html: false`, link-validated, the one audited sink),
  poll builder, attachment upload, and acknowledgment-required toggle;
  reactions and poll votes are optimistic, post creation is
  post-then-insert (id-keyed against the channel echo); one-level
  comment threads with compose/reply/react/edit/delete. Per-instance
  realtime sockets with manager-owned exponential-backoff reconnect
  that surfaces auth failure for re-sign-in. EN + DA, dark mode,
  reduced-motion, AA contrast throughout.
- Feed write parity over the API (issue #178, part of the #165 parity
  ladder): reaction toggles on posts and comments; poll voting
  (`PUT .../poll/votes` sets the whole selection — single-choice keeps
  the first id, empty list unvotes) with the poll's `my_votes` in the
  response; post create takes a real, documented `poll` object
  (options in list order) and `stored_file_ids`; acknowledgments
  (`PUT .../acknowledgment`, idempotent) plus the author/admin
  acked-vs-pending view (`GET .../acknowledgments`); post edit
  (author), delete (author soft-deletes to a tombstone, moderators
  hard-delete via `?hard=true`), pin/unpin (moderators); comment edit
  (author, new `Feed.edit_comment/3` — comments now carry an
  `edited_at` marker) and delete; multipart feed-attachment uploads
  (`POST .../uploads`, same context path as the LiveView composer) and
  Bearer-authorized file serving (`GET /api/v1/files/{id}`,
  `/thumbnail`, `/download` — the browser file routes' logic extracted
  into a shared `FileServing` module). Serializer/schema growth: post
  `attachments`/`my_reactions`/`my_acknowledged`/`acknowledged_count`,
  comment `edited_at`/`reactions`/`my_reactions`, poll `my_votes`
  (issue #81). Every write goes through the same context functions and
  authorization as LiveView; writes address posts via
  `fetch_visible_post`, so an invisible post answers 404 to every verb
  (issue #156's no-oracle rule extended to writes per issue #161,
  covered by a write-parity property test). Context hardening the raw
  transport demanded: feed uploads now require posting rights in the
  context, `stored_file_ids` must be the author's own uploads into the
  group (422 otherwise), and locked-comment/closed-poll refusals carry
  stable `comments_locked`/`poll_closed` error codes (422, previously
  a generic 400).
- PWA-native sign-in, server side (issue #177, ADR 0024): API-initiated
  sign-in emails now deep-link into the instance-served PWA
  (`/app/sign-in/{token}`) and carry a short single-use sign-in code
  (8 characters, Crockford base32 without lookalikes, 15-minute
  lifetime, hashed at rest) for cross-device sign-in —
  `POST /api/v1/auth/exchange` accepts `email` + `code` as an
  alternative to `magic_token`, with per-email and per-IP attempt
  rate limits so the short code cannot be brute-forced. Passkey
  sign-in lands in the API too: `POST /api/v1/auth/passkey/challenge`
  (usernameless WebAuthn assertion options with a signed, short-lived
  challenge token — no account-enumeration surface) and
  `POST /api/v1/auth/passkey/verify` (assertion → device token, same
  response shape as exchange). The web-initiated LiveView flow is
  unchanged (bugfix-frozen per ADR 0024); passkey _registration_
  stays web-only until the You-tab arc (#182). All new operations are
  in the OpenAPI document with conformance tests; sign-in emails are
  localized EN + DA.
- Instance-served PWA (issue #176, ADR 0024): the release image now
  builds the Svelte client (new Dockerfile client stage — node/pnpm,
  `pnpm build`) and serves it at `/app` on the instance's own domain,
  from `priv/static/app`. Real files come off `Plug.Static`; everything
  else under `/app` falls back to the client's `index.html`, so
  client-side routes — most importantly the magic-link landing
  `/app/sign-in/{token}` — deep-link straight into the SPA. LiveView
  keeps `/` until the removal cut (#187); the mount point is a single
  config key (`:pwa_base_path`) matched by the client's `paths.base`.
  A dev server without a built bundle answers `/app` with a plain-text
  pointer to the client dev workflow instead of a 500, and the Docker
  workflow's boot check now asserts the shipped image serves the PWA
  (base path and deep link both).
- Svelte client foundation (issue #32, ADR 0024): the design system in
  SPEC §21's language (warm neutral palette, hairline borders, typed
  UI primitives) with first-class light/dark themes (system-following
  plus a persisted manual override, no flash on load) and global
  `prefers-reduced-motion` support; the app shell — bottom tab bar on
  mobile, sidebar on desktop, five tabs with calm empty states and a
  route guard back to sign-in; EN + DA i18n from day one (typed
  message catalogs — a missing Danish key is a compile error); the
  full sign-in flow (instance URL probe → request link → paste the
  link/token or follow a `/sign-in/{token}` deep link → exchange),
  per-account sign-out from the You tab, plus theme and language
  controls. Hardening from review findings: the instance store gets a
  versioned envelope with per-element validation and v0 migration
  (issue #158), merged-home failures carry an `auth`/`network`/
  `server` kind so screens can tell "sign in again" from "retry"
  (issue #159), and the vacuous client tests were replaced with real
  ones — including Authorization-header and store-migration coverage
  (issue #160). Installability lands too: a geometric "K" mark (any +
  maskable SVG) and a completed manifest close issue #145.

- Realtime and notifications for the JSON API (issue #30, ADR 0014):
  Phoenix Channels at `/api/socket` authenticated with the same device
  token as REST — `feed:group:<id>` re-exposes the live feed events
  LiveViews already react to (join gated by the same `:view_group`
  decision, every payload re-fetched per viewer so pending/scheduled
  posts never leak) and `notifications:user:<id>` streams the owner's
  notifications, both shaped by the one REST serializer. New endpoints:
  `GET /api/v1/notifications` (cursor-paginated, newest first),
  `PUT .../notifications/{id}/read` and `.../notifications/read-all`
  (foreign ids answer 404 — no existence oracle), and
  `POST`/`DELETE /api/v1/push-subscriptions` mirroring the browser's
  Web Push registration flow, upsert semantics included. All operations
  documented in the OpenAPI contract with response-conformance tests.
- OpenAPI schema-conformance tests (issue #151, audit-driven): every
  API operation's real response is now validated against its
  documented schema (`schema_conformance_test.exs`), closing the gap
  where the route-level drift test couldn't see field-level lies —
  which is exactly how #154 went unnoticed. Also extracts the shared
  `api_conn/1` test helper (`KammerWeb.ApiHelpers`).
- CORS on the JSON API (issue #150): `/api/v1` now answers cross-origin
  requests and preflights with `Access-Control-Allow-Origin: *` by
  default — required for the multi-instance Svelte client (any web
  client at any domain) and safe because API auth is a Bearer device
  token, never a cookie. Instances that want a tighter policy can set
  `API_ALLOWED_ORIGINS` to a comma-separated origin allow-list. The
  browser-facing LiveView app keeps the same-origin default.
- Svelte PWA client scaffold at `clients/web/` (issue #32, ADR 0001):
  SvelteKit + TypeScript, static adapter in SPA mode (`ssr = false` —
  the client is a pure session-holder talking to remote instances,
  nothing server-rendered), Tailwind CSS, Prettier/ESLint, Vitest, and
  a minimal PWA manifest. Own CI job (`web-client`, node/pnpm), not
  inside the Elixir gate; root Prettier excludes `clients/web/` since
  it owns its own config/plugins (Svelte, Tailwind class sorting).
  Screens (sign-in, merged home, community list, group feed, events)
  land in follow-up PRs — this is tooling-only, verified to
  lint/typecheck/test/build clean.

- Generated TypeScript API client for the Svelte PWA (issue #32):
  `openapi-typescript` types generated from `/api/v1/openapi.json`
  (`clients/web/src/lib/api/schema.d.ts`, regenerated via
  `pnpm run generate:api`, never hand-edited) plus a thin
  `openapi-fetch`-based wrapper (`client.ts`) creating one typed
  client per added instance, per ADR 0001's multi-instance model.

- Multi-instance session-holder core for the Svelte PWA (issue #32, ADR
  0001): `clients/web/src/lib/instances/` — `instanceStore` (localStorage-
  backed, dedupes by instance+account so re-authenticating replaces
  rather than duplicates), `probeInstance`/`requestLink`/
  `exchangeAndAddInstance`/`revokeAndRemoveInstance` (the sign-in and
  device-token lifecycle), and `fetchMergedHome` (client-side merging of
  `GET /home` across every added instance, timing out per-instance so one
  unresponsive server can't hang the whole merged view). No screens yet —
  this is the session/data layer they'll be built on.

- OpenAPI response schemas for `/api/v1/instance`, `/api/v1/auth/*`, and
  `/api/v1/home` (previously untyped `object()` placeholders generating
  `Record<string, never>` in the TypeScript client — silently defeating
  the "generated, not hand-written" client for exactly the endpoints a
  multi-instance client needs first). New `Schemas.Instance`,
  `Schemas.AuthUser`, `Schemas.AuthRegisterResponse`,
  `Schemas.AuthExchangeResponse`, `Schemas.StatusResponse`,
  `Schemas.HomeGroupSummary`, `Schemas.HomeResponse`.

- `POST /api/v1/auth/register` (issue #30): the API can now create
  accounts, not just authenticate existing ones — mirrors
  `UserLive.Registration` exactly (same changeset, same per-IP rate
  limit, same confirmation-email step). Registration decision
  resolved: open, not web-only — the Svelte PWA and native apps need
  full sign-up parity with the web UI. `/api/v1/instance`'s
  `features.registration` flag flipped from `"web_only"` to `"open"`
  accordingly.

- File search + text extraction (SPEC §10/§16): the last piece of
  global search — files now surface by filename and by extracted text
  (PDF via `pdftotext`, plaintext read directly), alongside posts,
  comments, and events. Text extraction runs off the request path in
  an Oban job after upload, with a graceful skip for unsupported
  content types. File search rides the folder-permission invariant
  (ADR 0009) exactly: a loose SQL/full-text candidate query is
  narrowed in Elixir with the same `Authorization.can_read_folder?/4`
  decision `Kammer.Files.list_files/3` uses, so a file in an
  `admins_only` folder never surfaces regardless of its group's
  visibility.
- Newsletter subscriptions (SPEC §8, ADR 0013 extended): anonymous
  visitors on a public group's page can subscribe by email — no
  account, double opt-in through a signed confirm link, choice of
  every-post or a daily/weekly digest. Delivery reuses
  `Kammer.Digests`' cadence math (own Oban worker, offset cron tick)
  and every email carries a one-click `List-Unsubscribe` header (RFC 8058) alongside a signed management link that reuses the existing
  guest-manage page — change cadence or unsubscribe, same as changing
  a guest RSVP.
- Report surfaces on event and assignment pages (SPEC §11): the
  "Report to the moderators" flow the group feed already had for
  posts and comments now covers comments on events and assignments
  too — `Kammer.Moderation.report_comment/3` already handled any
  comment regardless of subject, only the UI was missing. The modal
  and its handlers moved into a shared
  `KammerWeb.KammerComponents.report_modal/1` /
  `KammerWeb.ReportHandlers` pair, so all three pages use the
  identical code path instead of three copies. Closes out HANDOFF's
  Moderation gaps backlog.
- Instance-wide bans (SPEC §11): operators get a second, broader ban
  list at `/instance/moderation` — ban an email instance-wide and it
  can't rejoin _any_ community on the instance, not just one. Same
  choke-point as the existing community ban
  (`Communities.add_member/3`), same email-keyed design (blocks a
  future signup too, not just an existing account), same two-step
  "demote before you ban" rule for other operators. Banning an
  existing account strips its memberships everywhere at once; each
  affected community's own admins see the removal in their audit log.
- Activity-sort feed view (SPEC §5, ADR 0006): an opt-in "Activity"
  ordering next to the default "Newest" on every group feed and the
  Home feed — posts bump to the top on their newest comment,
  forum-style, while pins still sort first. Chronological stays the
  default everywhere; no ranking, no algorithm, exactly the one
  alternate ordering ADR 0006 always reserved. Persists per user,
  toggled from a small dropdown right on the feed.
- Custom profile fields and the member roster (SPEC §4, ADR 0020):
  community admins define fields (text or single-choice) from
  `/c/:slug/settings` — "Instrument", "Section", "Dietary needs" —
  each with members/admins-only visibility and an optional `required`
  flag. Required fields hard-block at invite acceptance (a small
  "before you continue" step collects them); making an existing field
  required only nags already-joined members with a banner and a link,
  never a lockout. The member directory shows each person's visible
  answers and gains filter dropdowns for single-choice fields — the
  roster. Also added personal profile fields (bio, pronouns, and
  phone/email/other contact info, each independently
  hidden/members/admins-only, hidden by default) under Account
  settings.
- Content-minimized email mode (SPEC §9, ADR 0011): an operator-only
  instance toggle at `/instance/settings` — new, linked from the
  instance home — that strips digest emails down to a per-group post
  count and a link, dropping author names and post excerpts.
  Per-event notification emails never carried post content in the
  first place, so they're unaffected; auth and RSVP emails stay
  exempt by construction.
- RSS and Atom feeds for public groups (SPEC §8): every `public_link`
  and `public_listed` group exposes `/feed.rss` and `/feed.atom` —
  no account, no secret token, gated by the same visibility check the
  group page itself already uses. A feed reader can follow a group's
  posts without ever creating a Kammer account. Linked from the group
  page for anyone who can see it.
- Admin update notice (HANDOFF §5.6): a daily, privacy-respecting
  check against this project's GitHub releases surfaces "a newer
  Kammer exists" to instance operators on the home page — no payload
  beyond the version fetch, and `DISABLE_UPDATE_CHECK` turns it off
  entirely.
- Recurring events (SPEC §6, ADR 0019): weekly, biweekly, or monthly
  series bounded by an end date, up to 52 occurrences. Each occurrence
  is a real, independent event — RSVP, comment, and add it to your
  calendar exactly like a one-off — so cancelling or moving a single
  date needs no special handling. A new series page lists every
  occurrence with cancel/restore and shows the organizer attendance
  matrix (members × upcoming instances).
- Passkeys (SPEC §16, ADR 0018): register a WebAuthn credential from
  the Devices page after your first magic-link login, then sign in
  usernameless — your device's fingerprint, face, or screen lock, no
  email hop. Built on Wax; registration and sign-in verify entirely
  server-side, with a hand-crafted-ceremony test suite exercising the
  real cryptographic path (no browser required). Losing every passkey
  still leaves magic-link sign-in as the fallback.
- Audit log (SPEC §11): every role change, ban/unban, content removal
  via moderation, settings update, and group deletion — plus
  community-admin overrides into groups, flagged as such — writes a
  plain-language entry to an append-only log, visible to community
  admins from the moderation page. Entries stay readable even after
  the row they describe is gone; the log is deliberately not itself
  audited and never blocks the action it records.
- GDPR data rights (SPEC §12): download everything the instance
  stores about you — profile, posts, comments, reactions, poll
  votes, RSVPs, signup and assignment claims, availability answers,
  and every file you uploaded — as one zip, and delete your account
  self-serve. Deletion removes your identity and personal records
  immediately; your posts and comments stay so group history isn't
  broken, shown as "Deleted user". Both live under Account settings.
- Moderation: a Report action on every post and comment (one open
  report per person per subject — signal, not spam), a queue for
  community admins and group moderators with dismiss /
  remove-content actions, and community bans — banning removes the
  member everywhere and blocks their email from rejoining through
  any invite until the ban is lifted.
- Email digests, strictly opt-in: choose daily or weekly (Mondays)
  under Account settings and get one calm summary — new posts across
  your groups and the coming week's events, in your language and
  timezone. Quiet periods send nothing: no email is better than a
  hollow one.
- Backups (SPEC §14): `mix kammer.backup` /
  `Kammer.Release.backup/1` write a restorable snapshot — pg_dump
  custom-format database dump plus an uploads tarball — with optional
  age encryption and per-kind retention pruning. Setting `BACKUP_DIR`
  turns on a nightly scheduled backup. Restore guide (both
  directions, verified steps) in docs/backups.md.
- Global search within a community: one box over posts, comments, and
  events (Postgres full-text, mixed-language friendly), filtered by
  the same listing visibility as everything else — property-tested so
  search can never surface content from a group you couldn't see
  listed. Anonymous visitors search exactly the public face. File
  search follows once it can ride the folder-permission invariant.
- Decisions register (per-group toggle, off by default): raise a
  motion — it lands in the feed as a post with a For / Against /
  Abstain vote — then record the outcome (adopted, rejected, noted,
  with a note for the record). The register lists every motion and
  outcome chronologically: minutes-grade institutional memory, built
  for board groups.
- Assignments (per-group toggle, off by default): a flat task list —
  open, claimed, done, nothing else. "Who takes this?" is one tap,
  several people can hold the same assignment, anyone can mark it
  done (the record shows who), and each assignment carries a
  discussion thread through the same comment engine as posts and
  events. No boards, no sprints — associations run on lists.
- Availability polls ("Date finding", per-group toggle, off by
  default): propose candidate dates, members answer yes / if needed /
  no on a shared grid, and closing the poll turns the winning date
  into a real event with one click. Open polls appear on the events
  page under "Finding a date".
- Signup slots on events: "bring cake ×2, drive ×4" — event managers
  add capacity-bounded slots, members claim with one tap (never
  overbooked, enforced in the database), and on public events guests
  sign up through the same email-confirm flow as guest RSVPs. The
  guest management page lists signups next to RSVPs and comments; the
  API event detail now includes slots.
- Guest comments on posts in public groups that opt in
  (`members_and_guests` comment policy): name + email + comment, a
  signed confirm link (nothing stored until followed — the comment
  travels inside the link), then a moderator approval queue inline in
  the feed. Pending comments are invisible to everyone but moderators.
  The guest management page now lists everything a guest created —
  RSVPs (changeable) and comments — with one-click full erasure, and
  signing in with the guest's email claims comments too.
- OpenAPI document at `GET /api/v1/openapi.json` — the machine-readable
  API contract clients generate from, drift-guarded against the router
  by a test.
- Versioned files: uploading a file with the same name into the same
  folder now creates a new version instead of a duplicate. Every file
  has a browsable version history (uploader, time, size, download);
  single versions can be deleted (never the last); deleting the file
  removes all versions. Admins can cap history per space ("versions to
  keep"); default is unlimited.
- JSON API v1 (`/api/v1`): passwordless device-token auth (request
  link → exchange → revoke, tokens hashed at rest and revocable from
  the devices page), instance capability discovery, communities and
  groups, cursor-paginated group feeds with post and comment creation,
  events with RSVP, and the merged Home — every route through the same
  authorization module as the UI, with a property test guaranteeing
  API/UI visibility parity.
- Home: the instance start page now merges upcoming events and recent
  activity across all communities and groups you belong to — strictly
  chronological, read-only, with a per-group "Show in Home" switch on
  every group page (on by default, sealed groups included).
- Per-group feature toggles: group admins choose which tools the group
  shows (events, files; the feed is always on). Turning a feature off
  hides it everywhere — navigation, listings, ICS feeds, guest RSVP —
  without deleting anything; turning it back on restores everything.
- Guest RSVP on public events (no account needed): name + email, a signed
  confirm link that records nothing until followed, a confirmation email
  with calendar file, and a management link to change the answer or erase
  all guest data. Signing in with the same email claims guest history
  automatically. Event pages in public groups are now viewable without an
  account.
- Passwordless authentication: magic-link sign-in, revocable sessions with
  device overview, rate limiting on link requests.
- Communities and groups: multi-tenant instance, community switcher, four
  group visibility presets, join/posting/comment policies, roles, invite
  links, post-as-group, irreversible sealed groups, archiving.
- Central authorization module (`Kammer.Authorization`) with property-based
  test suites for the permission matrix, sealed-group semantics, and the
  file-visibility invariant.
- Feed: Markdown posts, image uploads (re-encoded, metadata stripped,
  thumbnailed), polls, attachments, emoji reactions, single-level comments,
  mentions (@everyone/@admins/display names), pinned + scheduled +
  acknowledgment-required posts, edit history, soft-delete with 30-day
  purge, live updates.
- Events: timezone-aware single/all-day/multi-day events, RSVP, comments,
  email reminders with ICS attachments, secret-token ICS feeds per group
  and per user.
- Files: community and group spaces, shallow folder trees, permission
  presets under a centrally enforced visibility invariant, auto-collections,
  local-disk and S3-compatible storage, optional quotas.
- Notifications: in-app center, email, and Web Push behind a pure §9
  channel matrix ("highlights" defaults; broadcast groups default to
  everything); per-group levels.
- Hybrid first-run setup: env-always-wins boot initialization, token-gated
  /setup wizard (operator, instance settings, first community/group,
  invite link, SMTP-testing magic link), permanent lock, optional
  one-click-removable demo community.
- Legal pages (privacy policy, imprint) with built-in templates, public
  routes, operator editing, and an operator nag until published.
- `/healthz` endpoint; Docker/compose deployment (app + Postgres +
  optional MinIO) with migrations on boot.
- English and Danish translations throughout, including emails.
- Repository automation: Dependabot with gated auto-merge, CodeQL,
  dependency review, Gitleaks, Docker image CI publishing to GHCR, an
  importable branch-protection ruleset, CODEOWNERS.
- Reproducible dev environment: Nix flake (canonical), direnv `.envrc`,
  `devbox.json` — one toolset, three entry paths, reused by CI.
- Phoenix 1.8 application scaffold (LiveView, Tailwind, UUID primary keys).
- Engineering-standards toolchain: mix format, Credo strict (incl. custom
  single-letter-variable ban), Dialyzer, Sobelow, ExCoveralls with coverage
  floor, mix_audit/hex.audit, lefthook hooks, commitlint, GitHub Actions CI,
  warnings-as-errors.

### Changed

- Strategic pivot recorded (ADR 0024): the Svelte PWA —
  instance-served by the Phoenix release at each instance's own
  domain — is the product UI, and LiveView is a first-build stepping
  stone to be removed from the repo entirely, not a permanent
  companion (LiveView can't do offline mode or multi-instance
  session-holding/merging, the two capabilities the product depends
  on). LiveView is feature-frozen as of now (bugfixes only) while
  the PWA climbs a surface-by-surface parity ladder — each surface
  ships with full write parity, including its missing API
  endpoints — with removal in one cut at full member+admin+guest
  coverage. SPEC.md §1/§16/§21 corrected to stop describing LiveView
  as the product UI (and §21 gains the community-first IA
  principle); AGENTS.md now carries the freeze policy so future
  sessions don't add LiveView features. Transition umbrella: #165.
- SPEC.md §16's "explicit non-goals" list corrected: native apps,
  offline support (beyond v1 app-shell caching), chat/DMs, E2EE, event
  ticketing/capacity/waitlists, collaborative document editing, video
  upload, storage billing, and group type templates were listed as
  permanently excluded when they're actually owner-confirmed future
  roadmap — several (native apps, offline support, group type
  templates) were oversold exclusions even by the ADRs that originally
  scoped them narrower. Each now has a tracking issue (#131–#138, #22)
  and the list itself is corrected so it stops reading as settled
  product philosophy. ActivityPub was considered directly and stays
  excluded, now with documented reasoning (ADR 0023) instead of a bare
  mention. Native apps' and offline support's re-scoping is recorded
  in ADR 0022, amending ADR 0012. See AGENTS.md's new "Product scope
  changes" section for the process fix this prompted.

### Removed

- 10 unused "valid values" accessor functions with zero call sites
  anywhere in the codebase (`Folder.overrides/0`,
  `Notification.kinds/0`, `NotificationPreference.levels/0`,
  `EventSeries.frequencies/0`, `CustomField.field_types/0`,
  `CustomField.visibilities/0`,
  `InstanceSettings.community_creation_policies/0`,
  `Decision.outcomes/0`, `AvailabilityResponse.answers/0`,
  `User.visibilities/0`), and trimmed two `phx.new`/`phx.gen.auth`
  generator boilerplate example comments (`user_auth.ex`,
  `error_json.ex`) down to their essential guidance. Found by the
  full-codebase audit (#78).

### Fixed

- Config and env-var errors now fail the boot loudly instead of being
  silently absorbed (issue #98, security-hardening pass): `PHX_HOST`
  is enforced in prod like `SECRET_KEY_BASE` (a forgotten value used
  to silently ship `example.com` sign-in links in real emails);
  env-provided instance settings go through the same
  `InstanceSettings.changeset/2` validation as the setup wizard, so a
  `DEFAULT_LOCALE` typo can no longer be persisted unvalidated and
  fed to Gettext; unrecognized `COMMUNITY_CREATION_POLICY` /
  `STORAGE_POLICY` values raise exactly like `MAILER_ADAPTER` /
  `STORAGE_ADAPTER` typos always have (they used to be dropped with
  no log at all); an `OPERATOR_EMAIL` that can't become an account
  raises instead of vanishing; and the boot-time settings application
  now runs synchronously, so those raises actually stop the boot
  rather than crashing a background task the supervisor shrugs off.
  Also from #98: `OPERATOR_EMAIL` (with its auto-promote side effect
  called out) and `STORAGE_POLICY` are documented in `.env.example`
  at last, and `Kammer.Backups` asks `Kammer.Storage.adapter/0`
  instead of reading the raw config key — an unset adapter means
  local storage there too, so `mix kammer.backup` outside a prod
  release archives the uploads tarball instead of skipping it with a
  misleading "S3" message.
- Group-authored posts no longer leak the human author's identity on
  the remaining web surfaces (issue #167, found by independent review
  of #166) — completing #153's closure across all transports: search
  results and the signed-in home's recent activity now dispatch on
  `author_type` like the feed does, and notifications for as-group
  posts render the group as actor everywhere the fanout's
  `actor_user_id` used to surface — the in-app notification center
  (name and avatar), the JSON API's notification serializer, and the
  email/push summary line ("Board posted", not "Alice posted").
  Rendering-side dispatch keeps `post.author_type` the single source
  of truth (matching digests and newsletters) and retroactively fixes
  already-stored notification rows. Regression tests per surface.
- Three residual holes in the ban enforcement family #129 hardened
  (issues #170, #171, #172, found by independent review of #169):
  `Communities.add_member/3` re-checks the community and instance ban
  lists inside its own transaction against the row-locked
  (`FOR UPDATE`) user — the same lock the ban paths take first — so a
  concurrent ban and invite redemption serialize instead of leaving a
  banned email holding a live membership; `Moderation.ban_member/4`
  re-reads the target's email from that locked user row, so the ban
  records the current address rather than a stale struct snapshot the
  target could sidestep by having changed their email; and
  `Communities.create_community/2` now consults the instance-ban list
  (under the same lock) and refuses with `:unauthorized`, closing the
  path where a banned account's surviving session could create — and
  own, unpurgeably — a fresh community. All membership-writing
  transactions now share one lock order (user row → community
  membership → group memberships), so none can deadlock another. The
  races themselves aren't reproducible under the test sandbox; new
  context tests pin the observable contract (current-email bans,
  banned-email refusals against stale structs, banned-creator
  refusal).
- The moderation ban guards checked the target's protected status
  (admin/owner role for `Moderation.ban_member/4`, operator flag and
  community ownership for `Moderation.ban_instance/3`) before their
  transactions rather than inside them (issue #129, found by
  independent review of #128) — a concurrent promotion or ownership
  transfer landing in that window could let a ban proceed against a
  freshly protected target, in the instance-ban case reintroducing
  the owner-purge bug #122 fixed, via a race instead of a stale
  guard. Both guards now run inside the ban transaction against
  row-locked (`FOR UPDATE`) user/membership rows, making check and
  act atomic, and `Communities.remove_member/3` now deletes the
  community-membership row before the group rows so every
  membership-removing transaction acquires locks in the same order
  (the reverse order could deadlock a concurrent ban + remove of the
  same member). The race window itself isn't reproducible under the
  test sandbox; the new context tests cover the observable contract
  around it (current-role reads, no-partial-purge refusal, rollback
  of the membership removal when the ban insert fails).
- Group-authored posts no longer leak the human author's identity
  through the API (issue #153): the feed queries never preloaded
  `:group`, so the serializer fell through to the user clause and
  exposed the real name/id that posting "as the group" exists to
  hide. `/home` and the group feed now serialize the same author.
- The OpenAPI document no longer misdescribes single-object responses
  as arrays (issue #154): `posts_create`, `comments_create`, and
  `events_show` now use a single-object envelope, the RSVP response
  documents its actual `{event_id, status}` shape, and
  `acknowledgment_required` is a boolean, not a string. Error
  documentation is also truthful now: every operation documents
  401/403/404, and writes additionally 422/429 — previously only
  401/404 appeared despite 403s being designed behavior. The generated
  TypeScript client (`clients/web/src/lib/api/schema.d.ts`) is
  regenerated — its types were actively wrong for these operations.
- A malformed post id in API comment creation is a 404, not a 500
  (issue #155): the id is UUID-cast before querying instead of raising
  `Ecto.Query.CastError`.
- Comments can no longer target unpublished posts (issue #156):
  `Feed.create_comment` now enforces the same visibility rule as the
  feed queries — a pending-approval post takes comments only from its
  author or a moderator, a scheduled post only from its author, and
  the refusal is a 404 (an invisible post answers exactly like a
  nonexistent one, no existence oracle). Previously any member who
  learned a post UUID could comment on a moderation-queued post
  through the API before it was visible. The created comment also
  returns its author populated instead of `"author": null`.
- Posts now serialize `pending_approval` (issue #157), so a member's
  own moderation-queued post is distinguishable from a published one
  in API clients — the field existed on comments but not posts.
- `.prettierignore` excluded `SPEC.md`, `BUILDLOG.md`, and
  `CHANGELOG.md` from formatting with no real reason — they're
  ordinary markdown, not legal text like `LICENSE` (the one entry
  that's actually justified). Reformatted all three; only `LICENSE`
  stays ignored now.
- `priv/gettext/da/LC_MESSAGES/default.po` had an empty `msgstr` for
  the setup wizard's SMTP-failure message (issue #101) — the only
  untranslated string in an otherwise fully-translated file. A
  Danish-locale operator hitting an SMTP failure during first-run
  setup saw a blank error instead of the guidance to check SMTP
  settings and request a new sign-in link. Filled in the translation.
- The OpenAPI document's `operation/4` helper hardcoded every
  operation's success response to `200`, wrongly documenting
  `posts_create`, `comments_create`, and the new `auth_register`
  (all real `201 Created` responses) — caught by independent review
  on #141. Added a `status` option, defaulting to `200`, set to `201`
  on the three creation endpoints.

- Closed the last 3 of 7 Repo-bypass gaps found by the architecture
  audit (#121, closes #123): `Files.list_feed_collection/2` queried
  `Kammer.Feed.PostAttachment` directly instead of asking `Feed` for
  it (new composable `Feed.attached_stored_file_ids_query/0`);
  `DecisionLive.Index`'s "record outcome" handler bypassed
  `Decisions.fetch_viewable_decision/2` for a raw `Repo.get/2` (also
  picks up its UUID-cast guard for free); `AssignmentEventHandlers`'
  unclaim handler queried `AssignmentClaim` directly instead of
  through `Assignments` (new `Assignments.get_claim/2`, matching the
  existing bare-accessor convention).
- `Feed.comment_context/1`'s assignment branch raised `MatchError`
  (generic 500) instead of `Ecto.NoResultsError` (proper 404) for a
  comment on a since-deleted assignment — reachable via
  `Moderation.report_comment/3`. Introduced by the #123 fix above,
  caught by independent review before merge. Renamed the existing
  private `Assignments.get_assignment!/1` (heavy preloads, one
  internal caller) to `get_assignment_with_details!/1` and added a
  proper bare `get_assignment!/1` (matching `Events.get_event!/1`'s
  pattern) so `comment_context/1`'s assignment and event branches now
  raise identically. Added regression tests for both branches.

- `Moderation.ban_instance/3` (instance-wide bans) could silently strip
  a community owner's ownership membership, with none of the
  protections the normal removal path enforces — no ownership
  transfer, not even a block. Found by the architecture audit (#121,
  closes #122). `ban_member/4` (single-community bans) already refuses
  to ban an admin/owner, and `Communities.remove_member/3` already
  refuses to remove an owner's membership at all; `ban_instance/3` now
  gets the same guard, refusing the ban outright when the target owns
  any community (a bulk instance-wide purge has no single community to
  ask "who's the new owner?" of, unlike the single-community path).
- `test/kammer_web/live/decision_flows_test.exs`, `legal_live_test.exs`,
  and `search_flows_test.exs` asserted exclusively via raw HTML
  substring matching (`html =~ "..."`), contrary to
  CONVENTIONS.md/CLAUDE.md's guidance to use `element/2`/`has_element?/2`.
  Found by the full-codebase audit (#79), closing it. Added DOM ids to
  the elements these tests needed to target that didn't have one yet
  (`LegalLive.Show`'s content article and edit link,
  `InstanceLive.Home`'s imprint-nag link and demo-purge button,
  `SearchLive.Index`'s per-result links), then rewrote every assertion
  to `has_element?/2,3` scoped to those ids. No behavior changed.
- `Moderation.ban_instance/3` ran two separate `CommunityMembership`
  queries against the same target user (an ownership check, then a
  second query for the communities to audit-log) — self-review on
  #122 flagged this and it was waved off as not worth fixing; it was.
  Folded into one `community_memberships_for/1` query that serves
  both the guard and the audit list.
- `Kammer.Media.process_image/1` — the libvips pipeline SPEC §11
  credits with stripping EXIF/GPS metadata via re-encoding — had no
  test. Found by the full-codebase audit (#79). Added
  `test/kammer/media_test.exs`, verifying the metadata-stripping claim
  directly (embeds real EXIF data via `Vix.Vips.MutableImage.set/4`,
  confirms it survives an unstripped save and is gone after
  `process_image/1`), plus dimension math (unscaled below the display
  max, downscaled and aspect-preserved above it), the WebP thumbnail's
  format and width, and the error path for an unreadable source file.
- `Kammer.Storage.S3` (the S3-compatible storage adapter — MinIO,
  Hetzner Object Storage, or any S3 API, SPEC §1's alternative to
  local disk) had zero test coverage of any kind. Found by the
  full-codebase audit (#79). Added tests for `put/2`, `put_binary/2`,
  `path_for/1`, and `delete/1` against a fake S3 endpoint
  (`Req.Test`), covering the round trip, the local-cache short
  circuit, `:not_found`, and unexpected-status errors. Each function
  gained an optional third `opts` argument (default `[]`, merged into
  the underlying `Req.new/1` call) purely as a test seam for injecting
  `plug: {Req.Test, name}` — behavior is unchanged for every existing
  caller, which never passes it.
- Six Oban workers with real branching logic — no-op vs. configured,
  scheduled vs. approval-held, empty vs. due recipients, vanished vs.
  live records — had zero `perform_job/2` coverage, unlike their
  tested siblings. Found by the full-codebase audit (#79). Added
  worker-level tests for `DigestWorker`, `BackupWorker`,
  `PublishScheduledPostWorker`, `PurgeDeletedContentWorker`,
  `NewsletterDigestWorker`, and `UpdateCheckWorker` that exercise each
  worker's own branches via `perform_job/2`; the underlying context
  functions each delegates to remain covered in depth by their own
  context test suites. No production code changed.
- The guest-confirm controllers resolved a post/event/group's
  community by walking `Kammer.Repo.get(Community, ...)` chains
  themselves instead of asking the owning context for it. Found by
  the round-2 audit (#91), closing it. `Feed.confirm_guest_comment/2`,
  `Events.confirm_guest_rsvp/2`, `Events.confirm_guest_claim/2`, and
  `Newsletters.confirm_subscription/2` now return the post/event/group
  with `:group`/`:community` preloaded, so `GuestCommentController`,
  `GuestPaths.event_path/1`, and `NewsletterController` build their
  redirect paths from the preloaded association instead of a second
  `Repo` lookup. Added `Communities.get_community/1` for
  `InstanceLive.Home`'s demo-community lookup, the one remaining
  direct `Repo`/schema reference in the web layer this issue covered.
- The web layer fetched Assignment/AvailabilityOption/EventSlot/
  SlotClaim/Report/CommunityBan/InstanceBan entities directly via
  `Kammer.Repo` and their schema modules instead of through the owning
  context. Found by the round-2 audit (#91). Added bare-id accessors
  (`Assignments.get_assignment/1`, `Availability.get_option/1`,
  `Events.get_slot/1`, `Events.get_slot_claim/2`,
  `Moderation.get_report/1`, `Moderation.get_community_ban/1`,
  `Moderation.get_instance_ban/1`); the affected LiveViews call them
  instead of naming `Kammer.Repo` or a schema module directly.
- The web layer fetched `Feed` entities (posts, comments, polls)
  directly via `Kammer.Repo` and the schema modules instead of through
  `Kammer.Feed`, and hand-rolled the poll-vote-toggle selection logic
  (`FeedEventHandlers.toggle_option/3`) — Feed domain logic living in
  `KammerWeb`. Found by the round-2 audit (#91). `Kammer.Feed` now
  exposes `get_post/1`, `get_comment/1`, `get_poll/1`, and
  `toggle_poll_option/3`; `FeedEventHandlers`, `ReportHandlers`,
  `GroupLive.Show`, `AssignmentLive.Show`, and `EventLive.Show` call
  them instead of naming `Kammer.Repo`/`Kammer.Feed.Post`/
  `Kammer.Feed.Comment` directly (one exception, documented inline:
  `FeedEventHandlers`'s `create_comment` handler keeps a direct
  `Repo.get/2` — narrowing that one call site's type triggers an
  unrelated Dialyzer false positive on `Feed.create_comment/3`'s
  `:comments_locked` branch, confirmed real via `feed_test.exs`).
  Remaining bypasses in Assignments/Availability/Events/Moderation and
  the guest-controller redirect-path chains are tracked as follow-up
  work under the same issue.
- The passkey sign-in and passkey-registration colocated JS hooks
  (`user_live/login.ex`, `user_live/devices.ex`) each defined
  identical `b64urlToBytes`/`bytesToB64url` WebAuthn base64url
  helpers. Found by the full-codebase audit (#77), which is now fully
  addressed. Extracted `assets/js/webauthn.js`; both hooks import from
  it instead of maintaining their own copy.
- `GuestClaimController` and `GuestRsvpController` each had a
  byte-for-byte identical private path helper (`event_path/1` and
  `confirmed_path/1`) resolving a guest-confirmed event's
  community-scoped URL. Found by the full-codebase audit (#77). Now
  both call the shared `KammerWeb.GuestPaths.event_path/1`.
- Community and instance moderation each hand-rolled their own
  ban-row list markup and `unban` `handle_event` body. Found by the
  full-codebase audit (#77). Now both call the shared
  `KammerComponents.ban_row/1` and `KammerWeb.BanEventHandlers`,
  parameterized on the DOM id prefix, confirmation text, and the
  scope-specific unban function, so the two can no longer drift.
- The group assignment list and the single-assignment page each
  hand-rolled their own `claim`/`unclaim`/`complete`/`reopen`
  `handle_event` bodies, including a byte-for-byte identical manual
  `AssignmentClaim` lookup before calling `Assignments.unclaim/2` in
  both places. Found by the full-codebase audit (#77). Now both call
  the shared `KammerWeb.AssignmentEventHandlers`, so the two can no
  longer drift. Added a regression test for the single-assignment
  page's full claim/unclaim/complete/reopen cycle, which had no prior
  test coverage.
- The community home feed hardcoded a post's `edit`, `pin`,
  `lock_comments`, and `approve` permissions to `false`, unlike the
  group feed's `post_permissions` which computed all of them via
  `Kammer.Authorization` from the exact same inputs (post, group,
  relationship, current user). A group admin or post author browsing
  their Home screen instead of the group page couldn't edit, pin,
  lock, or approve a post they were fully entitled to act on — the
  moderation menu simply didn't show those options. Found by the
  full-codebase audit (#77). Both feeds now share
  `KammerWeb.PostPermissions.for_post/4`, so the two can no longer
  drift.
- The group feed and the aggregated community home feed each
  hand-rolled their own feed-sort (Newest/Activity) control markup and
  `set_feed_sort` `handle_event` body, near-verbatim. Found by the
  full-codebase audit (#77). Now both share
  `FeedComponents.feed_sort_form/1` and route `set_feed_sort` through
  the existing `FeedEventHandlers` (already used for the rest of their
  feed interactions), so the two can no longer drift.
- Group and community settings each hand-rolled their own invite-link
  list markup and create/revoke `handle_event` bodies, near-verbatim.
  The community copy also displayed a bare `invite.use_count` instead
  of the group copy's `used/max_uses` label — so a single-use email
  invite (`max_uses: 1`) showed as a plain "0" or "1" in the list
  instead of "0/1", losing the cap information. Found by the
  full-codebase audit (#77). Now both call a shared
  `KammerComponents.invite_list/1` component and
  `KammerWeb.InviteEventHandlers`, so the two scopes can no longer
  drift.
- `Kammer.Moderation.report_comment/3` and `report_group/1` (via a
  private `comment_group/1` helper) re-derived a comment's owning
  group by branching on which of `post_id`/`event_id`/`assignment_id`
  was set — the exact same resolution `Kammer.Feed.comment_context/1`
  already did, reaching directly into `Events`/`Assignments` schemas
  instead of asking `Feed`. Found by the full-codebase audit (#76).
  Now `Moderation` calls the newly-public `Feed.comment_context/1`
  instead of re-deriving the branch itself.
- `Layouts.community_shell/1`, `CommunityLive.Home`, and
  `GroupLive.Show` each re-derived community membership/admin status
  with a private `member?/1`/`admin?/1`/`member_of_community?/1`
  helper that pattern-matched `community_relationship.community_role`
  directly, duplicating logic that already lives in
  `Kammer.Authorization` — the codebase's sole authorization
  choke-point. Harmless today since the helpers matched
  `Authorization.can?/4`'s `:view_community`/`:manage_community`
  clauses exactly, but a future change to either without noticing the
  other would have silently diverged. Found by the full-codebase
  audit (#75). Now all three call `Authorization.can?/4` directly.
- `Kammer.Files.fetch_accessible_file/2` only checked coarse
  group/community visibility — it never loaded the file's folder
  chain or checked an `admins_only` read override, unlike
  `list_files/3` which correctly does. A file placed in an
  `admins_only` folder was correctly hidden from folder listings for
  non-admins, but still directly downloadable via `/files/:id`,
  `/files/:id/thumbnail`, and `/files/:id/download` by anyone who
  could see the owning group or community, if the file's ID was known
  or guessed — the folder-level restriction was silently bypassed on
  the direct-fetch path. Now applies the same folder-permission
  invariant (ADR 0009) as `list_files/3`.

- `Kammer.Files.fetch_accessible_file/2` skipped the `Ecto.UUID.cast`
  guard its sibling `fetch_viewable_*` functions use, so a malformed
  file ID raised `Ecto.Query.CastError` instead of returning
  `{:error, :not_found}`. This broke `FileController.serve/4`'s
  deliberate 404 branch (the exception aborted the `with` before it
  could run) and crashed the `FileLive.Index` delete handler's
  LiveView process on a tampered `id` param. Found by the round-2
  audit. Now guards the same way its siblings do.
- `Kammer.Feed.create_engine_comment/5`'s reply-flattening
  (`normalize_parent/1`, now `/2`) accepted any `parent_comment_id`
  the client sent and looked it up globally, with no check that the
  candidate parent belonged to the same post/event/assignment as the
  comment being created. Since replies render via a
  `has_many :replies` preload keyed purely on `parent_comment_id`,
  this let any member with comment access anywhere on the instance
  inject a comment that would render nested inside an unrelated
  thread they had no visibility into at all — including a
  comment-locked or archived thread, or one in a sealed group. Found
  by a second, more thorough full-codebase audit (round 2). Now
  verifies the candidate parent shares the same subject before
  adopting it; a cross-subject `parent_comment_id` is silently
  treated the same as a missing one (becomes a root comment),
  matching the existing not-found fallback.
- Extracted `Kammer.Validation.validate_email_format/3` and
  `validate_display_name_length/3`, replacing six duplicated copies of
  the same email-format/length and display-name-length rules across
  `Kammer.Newsletters`, `Kammer.Events` (two guest-request
  changesets), `Kammer.Feed`, `Kammer.Guests.GuestIdentity`, and
  `Kammer.Accounts.User` — the last of the DRY violations from the
  full-codebase audit (#74). Deliberately narrow: normalization (e.g.
  downcasing email) stays with each caller since not everyone wants it
  — `User`'s email notably never has. Behavior-preserving at every
  site, including `User`'s 100-character display-name bound (the
  other five use 120) via the shared helper's `max` parameter.
- Added direct test coverage for two previously-untested
  security-relevant boundaries flagged by the full-codebase audit:
  `Kammer.Storage.Local`'s path-traversal guard (every key reaching
  disk goes through it — uploads, thumbnails, extracted text) and
  `Kammer.Markdown.to_html/1` (the sanitization boundary for every
  post, comment, and event body in the product). No production code
  changed; both were already correct, just unverified by the suite.
- Consolidated comment creation for posts, events, and assignments
  into one `Kammer.Feed.create_engine_comment/5` (ADR 0007's "one
  comment engine," which had drifted into three near-identical
  copies). Fixes two real bugs the drift had caused: event and
  assignment comments skipped the `@everyone`-mention rate limit that
  post comments already enforced, and — activated for the first time
  by this same fix, since event/assignment comments were never
  previously enqueued for fan-out — `Kammer.Notifications.fanout_comment/1`
  assumed every comment belonged to a post and would raise
  `Ecto.NoResultsError` for any event or assignment comment. Fan-out
  now resolves the comment's host (post, event, or assignment)
  polymorphically, with regression tests covering all three subjects.
- Consolidated the instance-operator check (`user.instance_operator`)
  into `Kammer.Authorization.instance_operator?/1`, replacing raw
  struct-field checks scattered across three context modules
  (`Kammer.Legal`, `Kammer.Communities`, `Kammer.Moderation`,
  `Kammer.Setup.DemoData`) and four LiveViews (legal page edit/show,
  instance settings, instance moderation, instance home) — the third
  and final authorization-consolidation fix from the same audit.
  Behavior-preserving; existing tests for all eight sites pass
  unmodified.
- `KammerWeb.CommunityScope`'s `:require_member` `on_mount` hook — the
  route-level gate for most of the app's community-scoped LiveViews
  (groups, files, members, moderation, settings, events, assignments,
  decisions, availability) — checked community membership with an
  inline `if socket.assigns.community_relationship.community_role`
  instead of going through `Kammer.Authorization`, another violation
  found by the same audit. Now calls `Authorization.can?/4` with
  `:view_community` (the same predicate, `community_role != nil`),
  with a dedicated test for the gate itself rather than only the
  indirect coverage every other community-scoped test already gave it.
- Consolidated the "creator or group moderator" access-control rule
  (who may edit/cancel/close/record-an-outcome-for a resource) into
  `Kammer.Authorization.can_manage_own_resource?/3,4`, replacing five
  independent copies of the identical logic across `Kammer.Events`,
  `Kammer.Availability`, `Kammer.Assignments`, and `Kammer.Decisions`
  — a direct violation of CONVENTIONS.md's "one authorization module"
  rule found by a full-codebase audit. Now property-tested alongside
  the rest of the authorization decision core instead of five separate
  unit tests that never covered the rule as a shared invariant.

### Security

- Full rate-limit coverage (SPEC §11): every item on the spec's
  rate-limit list now has a real `Kammer.RateLimit` bucket — account
  creation (per IP), posting, commenting, and file uploads (per
  author/uploader), on top of the magic-link and guest-endpoint limits
  that already existed. While auditing coverage, `@everyone` inside a
  **comment** turned out to bypass the broadcast-rights gate
  entirely — `Notifications.fanout_comment/1` already escalated it to
  a full-group broadcast for any commenter, since only post creation
  ran the gate. Comments now get the same gate and rate limit posts
  already had.
- Nonce-based CSP (SPEC §11, ADR 0021): `script-src` drops
  `'unsafe-inline'` for a fresh per-request nonce, closing the one
  remaining gap that would have let a successful XSS run arbitrary
  inline script. The app's one inline script (the light/dark theme
  bootstrap) carries the nonce; colocated LiveView hooks were never
  affected — they compile into the external `app.js` bundle.
- Newsletter one-click unsubscribe no longer embeds the full-power,
  60-day guest manage token in the RFC 8058 `List-Unsubscribe` header
  (issue #233) — a URL mail gateways auto-fetch with no human in the
  loop, so that token was a live, wide credential sitting in every
  delivered email. `Kammer.Guests.Token` gained a third,
  single-purpose salt (`sign_unsubscribe/1`/`verify_unsubscribe/1`,
  180-day max-age): the payload carries only the one
  `subscription_id` it authorizes, never an identity, so a leaked or
  auto-fetched copy can unsubscribe exactly that one subscription and
  nothing else — it fails `Guests.manage_token_valid?/1` outright
  (different salt), so it's powerless against every manage endpoint.
  The `/newsletter/unsubscribe/:token` route (GET and the RFC
  8058 POST) dropped its separate `:subscription_id` segment — the
  token names its own subscription, so there's no longer a
  caller-supplied id to tamper with. The body "manage or unsubscribe
  anytime" link is deliberately left carrying the full manage token
  for now (it's a link a human must click, not an auto-fetched
  header) pending the #185/#187 PWA transition.
