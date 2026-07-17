# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- The newsletter unsubscribe link no longer deletes on GET (issue
  #239). GET is a safe method, and non-RFC-8058 mail scanners and
  corporate link-checkers prefetch every URL in an email with no human
  involved — so following the `List-Unsubscribe` URL in a browser now
  renders a small confirmation page (instance default locale, both
  themes) whose button fires the RFC 8058 POST, and only the POST
  unsubscribes. Mail clients' one-click POST behaves exactly as
  before; both endpoints still answer the same neutral 200 for valid
  and garbage tokens alike. The issue's second item — the email body's
  manage link carrying the full token in the URL path — had already
  been fixed in the #187 cut (the link rides the URL fragment), so
  this closes the issue. Alongside: the instance-locale wrapper the
  guest and newsletter notifiers each carried a private copy of moved
  to `KammerWeb.Gettext.with_instance_locale/1`, now shared by the
  notifiers, the decision-poll texts, and the new pages.

### Added

- Step-up re-authentication before credential changes (issue #294, ADR
  0029). Adding or removing a passkey, revoking a device other than
  your own, and starting an email change now require the calling
  device to have recently re-asserted a root of trust — either a
  passkey confirmation or a single-use emailed link — within a short
  window (`STEP_UP_VALIDITY_MINUTES`, default 10). This closes the gap
  where a transiently stolen device token could mint persistence (add
  a passkey that survives revocation, lock the owner out, or repoint
  the account email); signing out, including revoking your own device,
  stays ungated. Gated endpoints answer 401 with the new
  `step_up_required` code; the PWA opens a confirmation dialog (passkey
  or "email me a link" with a check-your-inbox step), then retries the
  original action. The emailed link lands on a new `/step-up/{token}`
  page that works in any browser and elevates only the device that
  asked. This supersedes the #258-era decision to ship the API
  email-change flow without a re-auth gate, and resolves ADR 0018's
  open sudo-mode note.

- Per-community accent re-tint in the PWA (issue #321, SPEC §21).
  Community-owned surfaces — the authed community tree and the public
  community pages — now re-tint the interface with that community's
  configured `accent_color`, delivering §21's "branding is structural"
  promise: switching communities switches the accent. The accent and
  its foreground are derived per theme from the stored color with a
  WCAG AA floor (≥ 4.5:1 against paper/surface in the light _and_ dark
  palettes, and for text on the accent), darkening or lightening only
  as far as safety requires, so any admin-chosen color ships readable
  in both themes; an invalid stored color falls back to the default
  accent. Merged, multi-community surfaces (Home, cross-instance
  lists) and the app chrome keep the neutral default.

- Per-event capacity limit with an automatic ordered waitlist (issue
  #318). An event can now cap its attending RSVPs (`capacity`, empty =
  unlimited, set from the event form): once full, further "yes"
  answers — member and confirmed-guest alike, one cap over the whole
  RSVP set — land on a waitlist in arrival order, shown to the caller
  ("You're #3 on the waitlist") and to members on the event page as an
  ordered waitlist section (the public event read carries counts only,
  never queued identities). A freed seat (an attendee cancelling, the
  organizer raising or removing the cap) promotes from the front of the
  queue atomically — concurrent writes serialize on a row lock, so a
  seat is never double-filled — and the promoted member is notified
  through the notification machinery at their level (new
  `event_promoted` kind); a promoted guest gets an email, and a guest
  whose RSVP queued is told so in their confirmation email. Lowering
  the capacity never demotes anyone already attending. Deliberately
  decoupled from ticketing (#133): capacity is a small delta on the
  existing RSVP machinery.

- Newsletter subscription form on the PWA's public group page (issue
  #185, part of #187, SPEC §8). When a group opts guests into its
  newsletter (`guest_subscribe_allowed`), its public page now offers a
  tokenless subscribe form — name, email, and a per-post / daily digest
  / weekly digest cadence picker — matching what the LiveView group page
  offered. It posts to the existing
  `POST /api/v1/communities/{slug}/groups/{slug}/newsletter` endpoint,
  always answers a neutral "check your email to confirm" (no oracle on
  whether the address is already subscribed), and lets the guest change
  cadence or unsubscribe later from the management link the confirmation
  email carries. This closes the last unbuilt guest surface before the
  LiveView removal cut.

- Passkey enrollment in the PWA (issue #260 port 5b, part of #187, ADR
  0018). Four new authenticated endpoints under `/api/v1/me/passkeys` —
  `POST /challenge` (WebAuthn registration options), `POST` (verify the
  attestation and store the credential), `GET` (list), and
  `DELETE /{passkey_id}` (remove) — let a signed-in account register a
  passkey, the authenticated twin of the usernameless sign-in ceremony
  (#287). The ceremony runs statelessly: the challenge travels to the
  browser inside a signed, short-lived token (a salt distinct from the
  sign-in challenge's, so the two are never interchangeable) and comes
  back to verify against. Enrollment failures — a stale or tampered
  token, a bad attestation, a duplicate credential — all collapse into
  one neutral 422 that never reveals which step failed. The device page
  gains a "Passkeys" section listing the account's passkeys (name, when
  added, when last used) with remove, plus an "Add a passkey" control
  shown only when the browser supports registration and the instance is
  same-origin (WebAuthn binds the ceremony to this origin's host);
  otherwise a short note explains why. The serializer never emits the
  credential id or public key.

- Recurring event-series organizer view in the PWA (issue #260 port 4,
  part of #187, SPEC §6). A new authenticated endpoint —
  `GET /api/v1/communities/{slug}/events/series/{id}` — returns a
  series' rule, every occurrence (with RSVP counts and cancel state),
  and the attendance matrix (group members × upcoming occurrences, each
  cell the member's RSVP). It is organizer-only: the series' creator or
  a group moderator, gated exactly as the LiveView organizer page was.
  The PWA gains a series page reached from a "View series" action on any
  occurrence's detail, listing every occurrence with per-occurrence
  cancel/reinstate and rendering the attendance matrix. Attendance is
  the members' RSVPs (SPEC §6 — members only; guests count toward an
  occurrence's totals but are not matrix rows), computed, never a
  separate "mark present" step.

- Calendar subscription (iCal) links in the PWA (issue #260 port 3,
  part of #187, SPEC §6). New authenticated endpoints —
  `GET /api/v1/me/calendar-token` and a group sibling — hand the
  signed-in caller their subscription URL for the secret-token iCal feeds the
  browser routes already serve: a personal merged-events feed, and any
  group's whose events they can see. The PWA gains a "Subscribe" control
  on each group's page (when its events feature is on) and on the
  personal events page (one per added instance, since each feed lives on
  one server), revealing the feed URL with a copy action and a one-tap
  `webcal://` open link. The token is minted on first fetch and is the
  whole credential; the group endpoint gates exactly as the group's own
  feed does (viewable, events feature on), and an unviewable group is
  the same 403 every group-scoped endpoint gives.

- Group creation in the PWA, with a warm new-community cold-start
  (issue #278, part of #187). The PWA could edit a group's settings but
  had no way to _create_ one — a fresh community dead-ended with no
  first group (the LiveView was the only surface that could make a
  group). Adds a new-group form (name / URL / description / visibility /
  join, posting, and comment policy / approval queue / the create-only
  sealed flag) at parity with the LiveView's, and a `create_group`-gated
  "New group" affordance. A community with no groups now shows a warm
  empty state ("Create your first group") instead of a blank card — a
  new community starts empty by design (no auto-created default group,
  SPEC §3). The new-group form offers optional named suggestions
  (Everyone / Announcements / Public page) that pre-fill a sensible
  starting shape the operator renames and adjusts — suggestions, never a
  furnished room. SPEC §3 clarified: groups are the sole container (no
  community-wide file space), and cold-start is UX, not a data-model
  default.

- Passkey sign-in in the PWA (issue #260 port 5a, part of #187, ADR
  0018), driving the usernameless WebAuthn assertion the API already
  served (`/auth/passkey/challenge` → `/auth/passkey/verify`). The
  sign-in screen's email step gains a "Sign in with a passkey" option
  that runs the ceremony and lands on the same added-instance state as
  the magic link — no email typed, no password. The affordance is shown
  only where it can actually succeed — the browser can run WebAuthn and
  the instance is same-origin (a passkey is bound to its serving origin,
  so a cross-origin community couldn't sign in with one) — never a
  button that can only fail. Every failure (an unusable challenge, a
  dismissed prompt, a rejected assertion) collapses to one neutral
  message, giving no oracle for which passkeys or accounts exist.

- Custom profile-field management over the API and PWA (issue #259,
  part of #187, ADR 0020) — the last buildable #259 item, porting the
  LiveView community-settings surface and going past it. Managers get
  list, add, edit, and delete under
  `/api/v1/communities/{slug}/custom-fields`, all gated on
  `:manage_community` in the context. A manager can add a field (text
  or single-select with options), edit an existing field's label,
  visibility, or required flag, and delete one. A field's type and its
  options are frozen once it exists (changing them after members answer
  would orphan values); everything else stays editable — the LiveView
  only toggled required. Making a field required after the fact nudges
  already-joined members rather than locking them out (ADR 0020). The
  PWA community settings page gains a "Profile fields" section for all
  of it; a field id from another community answers a neutral 404
  through this community's path.

- Anonymous instance landing and community directory over the API and
  PWA (issue #260, part of #187), porting the signed-out
  `InstanceLive.Home`: a tokenless `GET /api/v1/public/communities`
  listing the communities that opted into the landing page
  (`listed_on_instance`, SPEC §3 — unlisted communities never appear,
  pinned by test), and a public `/welcome` page with the product-ethos
  blurb, a sign-in affordance, and the directory linking into the
  existing public community pages. Visitors without a signed-in
  instance now land there rather than straight on the sign-in form,
  taking over from the signed-out LiveView root.

- The four remaining admin-parity surfaces over the API and PWA
  (issue #259, part of #187), each mirroring its LiveView semantics.
  Group deletion:
  `DELETE /api/v1/communities/{slug}/groups/{slug}` — group owners
  and community admins (their sole power over sealed groups, ADR
  0005), audit-logged by the context — with a confirm-guarded delete
  button in the PWA group settings danger area, gated on a new
  `delete_group` entry in the group's `viewer_can`. Instance-wide
  email bans (the `InstanceLive.Moderation` twin): operator-only
  list/create/lift under `/api/v1/instance/moderation/bans`, keyed on
  the email itself so an address without an account can be blocked,
  and a PWA instance-moderation page under the account area with the
  ban form, active-ban list, and 422 field names mapped to our own
  copy (#253). Legal-page editing (`PUT /api/v1/legal/{key}`,
  operator-only, the `LegalLive.Edit` twin) with a PWA legal-pages
  overview — including the LiveView nag's equivalent, a
  "still showing the built-in template" hint per unpublished page —
  and a markdown editor linking the public page as preview reference.
  And a per-viewer `instance_operator` flag on `GET /api/v1/instance`
  (the `can_create_community` precedent), which the You page now
  reads from the capability-doc fetch it already made for the version
  line — replacing the per-instance settings-read 403 probe (#271's
  review note) and gating the new operator links.

- The PWA profile page now exposes the account's language, timezone,
  and email-digest frequency (issue #260, part of #187) — three
  settings `PUT /api/v1/me` already accepted and digest/notification
  emails already read, but which had no edit surface outside the
  LiveView settings screen. Language and digest mirror the LiveView
  option lists (English/Danish; off/daily/weekly Mondays); the
  timezone upgrades LiveView's free-text input to a select over the
  browser's IANA zone list, and the hints spell out that this
  language governs emails from the server while the app's own display
  language stays a device-local choice on the You tab. A 422 on save
  now maps the changeset's field names onto our own copy instead of
  rendering the server's message string (#253).
- Ban creation and an audit-log page in the PWA's moderation surface
  (issue #259, part of #187), both over API endpoints that already
  existed with no PWA caller. The moderation page gained a "ban a
  member" form (admins only): pick a plain member from the roster —
  the server refuses admins, owners, and self-bans, mirroring the
  LiveView semantics — with an optional reason the LiveView flow
  never exposed, and a 422's field names map to our own copy
  (already-banned email, over-long reason). A new audit-log page
  under `moderation/audit`, linked from the moderation page like the
  LiveView's inline audit section, lists the community's append-only
  admin actions (summary, action code, relative timestamp) for
  community admins.

- Community and instance-operator settings pages in the PWA (issue
  #259, part of #187), both over API surfaces that already existed —
  no new server endpoints. The community settings page gained the
  controls the update endpoint already accepted: web address (slug),
  default language, "list on the instance landing page", and the
  real-names request — previously only name, description, and accent
  were editable, and a 422 now maps the changeset's field names to
  our own copy (`name`/`slug`) rather than showing a generic error.
  A new operator-only instance settings page under the account area
  edits instance name, default language, who may create communities,
  the storage policy, and content-minimized email mode — reachable
  only where this account operates the instance (gated on the
  settings read itself, since there is no operator capability on the
  client). The LiveView instance settings screen only ever exposed
  the email toggle; the other four fields had no edit surface before
  now.
- Community creation over the API and PWA (issue #259, part of #187):
  a new `POST /api/v1/communities` endpoint, gated by the same
  instance community-creation policy (SPEC §3: operators only / any
  user) the LiveView flow honors — the creator becomes the
  community's owner — plus a `communities/new` PWA screen reachable
  from the groups tab. The instance capability doc
  (`GET /api/v1/instance`) now reports a per-viewer
  `can_create_community` boolean so the client gates its "new
  community" entry point instead of guessing the policy.
- The PWA group settings page now covers the full settings surface
  the API already accepted (issue #259, part of #187): visibility,
  join/posting/comment policy, web address (slug), approval queue,
  and file-version retention — previously only name, description,
  features, and archive were editable. The page also lists pending
  join requests with approve/deny, and links to a new group invites
  screen (mirroring the community invites page). The group serializer
  and its OpenAPI `Group` schema now expose `posting_policy`,
  `comment_policy`, `approval_queue`, and `version_retention` so the
  form can pre-fill them — emitted only to a viewer who can manage the
  group (`viewer_can` includes `manage_group`), so a public group's
  moderation posture and retention config never ride the tokenless
  public shape; no new server capability was added — the update
  endpoint already accepted every one of these fields.

### Changed

- Expelling a sealed **private** group from outside is now recorded as
  an operator-level action (console/DB), not an API power
  (owner-decided on issue #347, ADR 0005 amendment): the no-oracle
  gate (#224/#339) hides such a group from a community admin before
  the delete authorization could run, and restoring an admin-reachable
  delete would itself be an existence oracle. The group's own owner
  keeps the ordinary delete; sealed non-private groups keep the API
  path for admins too.
- The default community accent now matches the design-system accent
  (issue #328). A community that never customized its accent used to
  carry a green (`#3E6B48`) distinct from the app chrome's `#8a4b24`,
  so untouched communities rendered two-tone out of the box; the
  server default (schema and column) flips to `#8a4b24` and a
  migration moves existing rows still on the old default (matched
  case-insensitively — the untouched wizard default could be stored in
  either case), so a tint is always a deliberate admin choice. The
  data migration is one-way: rolling back restores the old column
  default but cannot tell a migrated row from one whose admin chose
  `#8a4b24` on purpose. The setup wizard, new-community form, and
  community-settings placeholder pre-fill the same value.

- Single-account display collapse in the PWA (issue #322, SPEC §21).
  With exactly one instance added — the overwhelmingly common case, and
  the entire pilot — the chrome now hides the multi-instance
  abstraction instead of presenting a one-item federation: Home,
  Groups, and Search drop the instance-name provenance labels, the You
  tab presents one plain account (no instance-named card header, no
  several-servers explainer, "Your account" instead of "Your
  communities"), the You sub-pages (profile, devices, push
  notifications, data & account) drop "on <instance>" from their
  descriptions, and the failed-instance banners say "your community"
  rather than naming the only server there is. Everything derives from
  a shared `instances.solo` flag, so adding a second account restores
  the current multi-account presentation unchanged — and URLs keep
  their `[instance]` segment either way (deep-link stability; this is
  presentation-only, the data model and routes are untouched).

- PWA API error handling collapsed into one shared `ApiError` (issue
  #270, part of #187). The ~10 near-identical per-module error classes —
  each carrying its own copy of the status→kind mapping, envelope
  parsing, and `fetch`-rejection guard — are gone; every client API
  surface (authenticated and tokenless alike) now throws the single
  `ApiError` from `$lib/api/errors`, and the two duck-typing bridges that
  existed only to reconcile the separate classes (`manage`'s
  `loadErrorKind`, `tools`' `toolsErrorKind`) collapse into one shared
  `errorKind` collapser. The duplicated status-to-kind mapping tests are
  retired in favor of one canonical spec. Net −600 lines. No user-visible
  behavior change beyond one first-run-setup network-error string now
  reading the shared "Could not reach this community." wording (converged
  with the other raw-`.message` render sites by the #253 field-error
  follow-up). A few internal mappings also unify — a swallowed `push`
  network string, `400` no longer aliased to the `validation` kind on the
  four tokenless surfaces that did so, and `too_large` now preserved
  through the collapsed bridges — but no current consumer distinguishes
  them. This is the shared mechanism the inline 422 field-error work
  (#253) builds on.

- Inline 422 field errors on the PWA's group and community create and
  update forms (issue #253, part of #270). A validation failure now
  highlights the specific input that caused it — a taken or reserved web
  address lands on the slug field, a blank-or-too-long name on the name
  field (and, on group settings, a bad version-retention value on that
  field) — with localized copy, instead of one generic banner. Two
  shared mappers, `groupParamsErrorKeys` and `communityParamsErrorKeys`,
  turn an `ApiError`'s 422 `details` (Ecto changeset field names, via
  `traverse_errors`) into per-field i18n keys, reusing the
  `registerErrorKeys` pattern and the shared `Input` `error` prop; any
  unmapped field or non-validation failure falls through to the shared
  `ErrorBanner`. Server-English message strings are still never rendered.

- Inline 422 field errors on the PWA's remaining forms — event
  create/edit and profile update (issue #253, part of #270). The event
  form now lands a non-http(s) location link on the location-link field
  (issue #247), an end-before-start on the end-time field, an
  over-length title/location on their fields, and a too-narrow
  repeat-until window on that date; the profile form lands a
  blank-or-too-long display name and an over-length pronouns value on
  their inputs. Two new mappers, `eventParamsErrorKeys` and
  `profileParamsErrorKeys`, turn the 422 `details` (Ecto changeset field
  names, verified against `Kammer.Events.Event`/`EventSeries` and
  `Kammer.Accounts.User.settings_changeset`) into per-field i18n keys;
  the event form's inputs moved onto the shared `Input` component to
  carry the `error` prop. `Select`-constrained fields and any unmapped
  field fall through to the shared `ErrorBanner`, and the event pages no
  longer render the raw server `ApiError.message`. First-run setup keeps
  its banner for now: its `with`-chained sub-changesets yield flat but
  cross-entity-ambiguous detail keys (`name`/`slug` for both community
  and group) split across two wizard steps, so field mapping is deferred
  — but its raw-`.message` render was replaced with localized copy too.
  The community/group invite and instance-settings forms need no change:
  their endpoints emit no field-level 422 (the invite changeset doesn't
  validate `invited_email`; `instance_name` is unvalidated), so they
  correctly stay on the banner.

### Removed

- The gettext catalogs dropped the 661 msgids whose only consumers
  were the LiveView templates deleted in the #187 cut (issue #325, the
  cleanup #294's build deliberately deferred): `mix gettext.extract
--merge` on a clean tree, verified lossless — every surviving msgid
  keeps its EN and DA translation, `errors.po` untouched.

- **LiveView is gone — the Svelte PWA is now the only web UI** (issue
  #187, closes #165; ADR 0024). The entire `lib/kammer_web/live/` tree,
  the LiveView-only web layer (core/feed/Kammer components, layouts, the
  CSP-nonce plug, the server `assets/` esbuild/Tailwind/daisyUI
  pipeline), and every LiveView-supporting controller whose capability
  had already moved to the JSON API (`GdprController` → `GET /me/export` +
  `DELETE /me`; `UserSessionController` → `/api/v1/auth/*`; the browser
  invite-accept and guest/newsletter confirm landings → their PWA + API
  twins; the browser file-download controller → the Bearer and public
  `/api/v1/files` routes) were deleted in one atomic cut, along with the
  `phoenix_live_view`, `phoenix_live_dashboard`, `phoenix_live_reload`,
  `heroicons`, `esbuild`, `tailwind`, and `lazy_html` dependencies, the
  dev LiveDashboard route (the Swoosh mailbox preview is retained for the
  e2e sign-in flows), and the LiveView smoke-test CI job.
  The `KammerWeb.UserAuth` plug shrank to a session _reader_ (browser
  sign-in was already an API device-token flow), and the browser
  pipeline dropped its LiveView flash / root-layout / CSP-nonce plugs.
- **The PWA moved from `/app` to the site root.** `:pwa_base_path`,
  the client's `paths.base`, the web manifest, and every email/redirect
  producer now target `/` — a magic link is `/sign-in/{token}`, a public
  group is `/c/{slug}/g/{slug}`, and the guest-manage link carries its
  token in the URL fragment. The router's PWA catch-all moved to the very
  end so it shadows neither the JSON API, `/healthz`, the ICS/RSS feeds,
  nor the newsletter-unsubscribe routes.
- The community-level file space (a LiveView-only surface with no API
  twin) was removed; a data migration rehomes any community-space
  folders, file entries, and stored files onto a group so nothing becomes
  unreachable. The target is the oldest group that can actually surface
  them — not archived, not `:private`, `:files` enabled — falling back to
  the oldest group overall (communities with no group are left
  untouched).

### Fixed

- Every tokenless public surface now draws one "public" line (issue
  #345, expanded by its review round): `publicly_readable?/1` gates
  the RSS/Atom feeds (an archived or sealed `public_listed` group
  used to keep serving a live feed whose every link landed on the SPA
  error state), the guest RSVP/comment gates (a sealed public group
  accepted whole guest flows whose confirmation links 404), the
  newsletter subscribe gate, and — the review round's sharpest catch —
  newsletter _delivery_: per-post and digest sends now re-check the
  gate, so a group flipped off the public presets stops emailing post
  excerpts to guest subscribers instead of leaking content across the
  visibility boundary indefinitely. The anonymous subscribe, guest
  comment, and guest RSVP requests all resolve through the shared
  public fetches now, folding sealed/archived public groups into the
  same 404 their pages give (the old answers confirmed existence to
  slug probers: 403 for archived, and for sealed a 202 acceptance of
  a flow whose confirm link then died). The single-post newsletter email links to the post itself
  (the digest's roundup link was correct and stays; the misnamed
  `post_url/1` helper is renamed, and all email links now build
  through `PublicLinks`, sharing the confirm links' base handling),
  and a confirmed guest comment redirects to the commented post — with
  the confirm pages growing the "go to the page" link that makes the
  redirect visible (the field previously had no client consumer).

- Leaving or being removed from a group no longer leaves an ex-member's
  RSVP sitting on that group's future events (issue #329, owner-decided
  option 1). Before #318 added capacity and a waitlist, a stale RSVP
  after removal was cosmetic; afterwards it was consequential — an
  ex-member could keep an attending seat or a promotable waitlist spot
  on an event they could no longer even view. `Kammer.Events` gains
  `drop_member_future_rsvps/2` (and the bulk
  `drop_member_future_rsvps_in_groups/2` for callers ending a
  membership across several groups at once): it deletes the user's RSVP
  — any status, including waitlisted — on the group's future events,
  then runs the same locked promotion pass a member's own cancellation
  triggers, so a freed seat or a removed waitlist row promotes the next
  waitlisted member in order. Past-event RSVPs are untouched, staying as
  attendance history. Wired into every path that ends a group
  membership: `Groups.leave_group/2`, `Groups.remove_member/3`,
  `Groups.remove_memberships_in_community/2` (the community-wide
  removal `Communities.remove_member/3` already delegates to),
  `Moderation`'s community and instance bans, and — added by the
  pre-merge review, which caught it as the sixth door — account
  deletion (`Gdpr.delete_account/1`), where the FK cascade already
  deleted the rows but nothing promoted the freed seats.

- Community audit log cursor pagination (issue #340, 2026-07-17
  dismissal audit). `Audit.list_events` hard-capped at 50 rows with no
  way to see anything older, the API took no pagination params, and
  the PWA audit page fetched once — an append-only accountability log
  that silently dropped history for any active community. Originally
  dismissed as "parity with the LiveView ceiling," which is exactly
  the limitation-carry-forward this file's process section bars.
  `GET /api/v1/communities/{slug}/audit-log` now takes the same
  `after`/`limit` cursor params as the notification center and group
  feed (`Kammer.Audit.list_events_page/4`, same `{events, next_cursor}`
  contract; default page size stays 50, `Pagination.limit/2` gained an
  optional default override for it); the PWA audit page grows a "Show
  older" button matching the notification center's, appending pages
  and hiding once `next_cursor` is `nil` — a failed page keeps the
  loaded log on screen and stays retryable, mirroring the group feed's
  load-more error handling.

- RSS/Atom group feed items now link to the post itself instead of the
  group page (issue #341). Feeds shipped in #54 before any per-post
  page existed, so every item's `<link>` (RSS) / `<link href>` (Atom)
  pointed at the group page — the best available target at the time.
  #246 later added the public post page at
  `/c/{community_slug}/g/{group_slug}/p/{post_id}`, but nothing
  circled back to point feed items at it, so a reader following an
  item from their feed reader landed on the group's whole feed rather
  than the post they clicked. Each item's link now resolves through a
  `post_link_fun` the controller passes to `Kammer.Feed.Syndication`
  (an `unverified_url/2` build of the post's public page, the same
  convention as the feed's other links); the feed-level `<link>`
  correctly stays the group page. The RSS `<guid isPermaLink="false">`
  is unaffected — it was never a URL.

- An explicit JSON `accent_color: null` on community create, community
  settings, or the setup wizard no longer escapes as a 500. The request
  bodies declare the field nullable, but the column is `NOT NULL`, so
  the cast nil died at Postgres. A null now means "no choice": the
  changeset drops it, keeping the stored value on update and the
  schema default on create — which is what `nullable: true` honestly
  means for a defaulted setting. Pinned by an API test driving null
  through both create and update.

- Three previously-dismissed review findings, remediated after the
  owner overruled the dismissals (2026-07-17). The invite landing page
  now re-tints with the invited community's accent once the token
  resolves — the community is known from that moment, so the page
  carries its branding like every other community-owned surface (the
  invite preview payload gains the community's `accent_color`; the
  guest confirm and manage pages stay untinted — their payloads carry
  no single community, and a guest's inventory can span several). The
  single-account failure banners no longer presume one community:
  "your community" copy is now count-agnostic in English and Danish
  (one instance can host several communities, so the old wording was
  wrong for multi-community accounts). Internally, waitlist-promotion
  notification jobs are enqueued with one `Oban.insert_all` instead of
  a per-promotion insert loop — same in-transaction atomicity, one
  statement per promotion burst.

- Invite creation now validates `invited_email` (issue #305). The
  changeset cast the address with no format check, so an admin could
  invite `jhon@` or `alice@example ` — the API answered 201 and the
  invitation email silently bounced. A malformed address now fails with
  the standard 422 envelope (`details.invited_email`) via the shared
  email rule every other email field uses
  (`Kammer.Validation.validate_email_format/3`); valid addresses are
  stored downcased like the guest and newsletter email writes (the
  column is citext, so comparisons were already case-insensitive).
  Validation also runs before the per-admin email-invite throttle, so a
  refused address no longer consumes email budget. The PWA invite forms
  (community and group) surface the 422 inline on the email field
  through the #253 field-error mapper, in English and Danish. This
  supersedes the #253-era note earlier in this release that the
  invite forms "correctly
  stay on the banner" — that held only while the server emitted no
  field-level 422 for them.

- "Add to calendar" on an event page no longer fails with a silent 404
  for members-only groups (issue #307). The signed-in event page linked
  the tokenless browser ICS route (`/c/{slug}/events/{id}/ics`), which a
  plain `<a href>` navigation reaches without the device token — so any
  event the anonymous public couldn't see (every `private`/`community`
  group, i.e. most of them) answered 404 to exactly the members it
  belongs to. A new Bearer-authenticated endpoint —
  `GET /api/v1/communities/{slug}/events/{id}/ics`, serving the same
  `text/calendar` attachment behind the events surface's no-oracle 404 —
  replaces the link with an authenticated download (the same
  object-URL anchor pattern as the account export), with pending state
  and the shared `ErrorBanner` on failure. The browser route stays for
  public events and calendar apps.

- Client resilience floor (part of #270). Relative timestamps ("2 min.
  ago") now keep aging while a screen stays open — a shared minute
  ticker (`createSubscriber`) re-renders every `RelativeTime` and the
  offline stale-data banner on the minute and runs only while one is
  mounted, so a long-lived installed PWA no longer shows fossilized
  times. The SPA also gains its error floor: a branded, localized root
  `+error.svelte` (distinct copy for 404 vs other failures, always a
  link home) replaces SvelteKit's unstyled English fallback on stale
  or mistyped URLs; a `hooks.client.ts` `handleError` logs unexpected
  client errors to the console (the only sink there is — expected 404s
  excluded) and keeps raw error detail out of the UI; and a
  `<svelte:boundary>` around the app shell's content column degrades
  one crashed screen render (a single bad post, say) to an inline
  retry card instead of white-screening the shell — the navigation
  stays outside the boundary, and the card resets the boundary on
  navigation, so leaving the broken screen always works. And removing
  an instance now tears down its realtime socket on every removal
  path — sign-out and re-sign-in-replacement alike: previously the
  manager lingered until a reconnect happened to 401, and re-signing
  in (a fresh instance id) orphaned the old manager entirely. `Button`
  gained the audit's `href` story along the way (renders a real link
  with the button look), replacing the error page's hand-rolled copy
  of that recipe.

- PWA action surfaces no longer render the raw server-English
  `ApiError.message` (issue #253, part of #270). A shared
  `ui/ErrorBanner` renders localized `errors.<kind>` copy instead, so a
  Danish user sees Danish rather than an English server string, and no
  server-internal message leaks to the UI. Converted the post composer,
  the join/leave and invite actions, device/passkey management, and the
  feed/event/series/files/roster stores' action-error surfaces (each
  store's action-error state now carries the `ApiErrorKind`, not a
  message string). Field-bearing forms — inline per-field 422 errors —
  follow in the next slice.

- `Moderation.list_open_reports/2` no longer authorizes the report
  queue one report at a time (issue #342, audit finding). For a
  non-community-admin caller, every open report ran its own
  `Authorization.can?(actor, :moderate_group, group)` check, each
  resolving the actor's community and group roles fresh — two queries
  per report, on top of the queue load itself. It now collects the
  distinct groups the loaded reports belong to and resolves all of
  them in one batched `Authorization.group_relationships/3` call
  (#206) — the same shape `CommunityController.groups/2` already
  uses — then filters in memory, dropping the per-report cost to a
  fixed few queries regardless of queue size. Community admins still
  see the whole queue; group moderators still see only reports whose
  subject lives in a group they moderate, and only that group's.

### Security

- The web client's transitive `cookie` dependency is force-resolved to
  0.7.2 via a pnpm override (GHSA-pxg6-pf52-xh8x, low): SvelteKit still
  declares `^0.6.0`, whose parser accepts out-of-bounds characters in
  cookie names/paths/domains. The vulnerable path only runs in
  dev/SSR — the shipped client is a static build — but the override
  clears the advisory at zero API cost (0.7 is compatible) rather than
  leaving the alert to explain forever.

- Account deletion and the data export now require step-up
  re-authentication (issue #323, updating ADR 0029). `DELETE /me` and
  `GET /me/export` answer 401 `step_up_required` until the calling
  device has recently re-asserted a root of trust, closing the two
  gaps the original step-up scope (issue #294) deliberately left open:
  a transiently stolen device token could irreversibly destroy the
  account in one request (destruction needs no persistence), or pull
  every stored byte of the account's data as one zip (one-shot bulk
  exfiltration). The deletion flow's typed-back-email confirmation
  stays, layered after the gate — accidental-click protection on top
  of, not instead of, the security control. The PWA's delete and
  export flows open the same step-up dialog and retry, like every
  other gated flow. The consent copy — the step-up email and the
  confirmation landing page — now names the widened stakes
  explicitly (deleting the account, downloading all its data)
  instead of the original "security settings" phrasing, so a user
  approving a step-up knows the worst the action-generic grant can
  do (adversarial review of the #323 widening).

- `Event.location_url` now rejects anything but `http`/`https` on
  write (issue #247, found by the adversarial review of #246):
  previously it was only length-checked, so an event host could set
  it to `javascript:...` and have the LiveView event page render a
  raw `<a href>` — `rel="noopener noreferrer"` does not neutralize
  `javascript:` URLs, and this executed same-origin, i.e. member-facing
  stored XSS. Defense in depth, outermost first: the changeset
  validation (`Kammer.Validation.validate_http_url/3`, a new shared
  helper — `InstanceBookmark`'s near-identical private URL check now
  delegates to it too) blocks new writes; a data migration nulls any
  pre-validation row (which also keeps the ICS export's `LOCATION`
  text clean); the API serializer never emits a non-http(s)
  `location_url`, covering every current and future client at one
  choke point; and the render sites — the LiveView anchor
  (`EventLive.Show`) and both PWA event pages (the anonymous public
  one already guarded in #246, plus the authenticated member page
  which had the same gap, both via a shared `safeHttpUrl` helper) —
  still guard independently. Both sides enforce the same anchored
  scheme-allowlist rule rather than full URL parsing: RFC-3986
  parsing over-rejected IDN hosts (`https://øl.dk`) and pasted maps
  URLs browsers accept, while diverging from the WHATWG parsing the
  client used. A repo-wide sweep for other user-entered URL fields
  rendered as a raw href found none unguarded: `InstanceBookmark.url`
  already validated the scheme (from its original commit), and the
  two other raw `href={...}` sites in the LiveView app (`file_href/1`
  in the file browser and search results, `latest_known_release_url`)
  are either server-generated paths or sourced from GitHub's release
  API, not user input.

- Slug-addressed group sub-endpoints no longer leak private/sealed
  group existence through a 403-vs-404 split (issue #339, found by the
  2026-07-17 dismissal audit). #224 folded a view-denied group into
  the same neutral 404 a missing one gets on the group management
  endpoint itself; eight private `with_group`/`with_feature_group`/
  `with_files_group` copies in the post, event, calendar, assignment,
  availability, decision, file-library, and group-member controllers
  didn't make the same fold, so an outsider probing a slug could tell
  a real hidden group from a typo by whether the group's feed,
  calendar token, assignment/availability/decision list-or-create,
  file library, or membership surface answered 403 or 404 — a live
  existence oracle the #224 fix was supposed to close everywhere.
  Extracted the fold into one shared `KammerWeb.Api.GroupGate.fetch/4`
  (optionally folding a disabled feature toggle too, ADR 0016) that
  all nine controllers — the original included — now call; only the
  `:view_group` resolution folds to 404, so a group a viewer can see
  but isn't allowed to write to, join, or manage still answers an
  honest 403. A review pass over the fix then caught and closed four
  more of the same oracle — uploads, group invites, and the anonymous
  newsletter-subscribe and guest-comment surfaces (the anonymous two
  the worst, being tokenless probes) — plus a latent 500 in the
  assignment/availability/decision create actions, where a denied
  write or invalid changeset in a _visible_ group escaped
  `with_feature_group` unhandled instead of answering the honest
  403/422. Flipped the tests that had pinned the wrong 403, tightened
  the `ResourcesTest` and `FeedWritesTest` parity properties (each
  previously accepted 403 _or_ 404 for an invisible group, which is
  exactly how this got past them), and pinned every gated surface with
  a deterministic invisible-group 404 test — added for create on the
  assignment/availability/decision suites, index and create on the
  feed and invite suites, and the single write each of the upload,
  newsletter, and guest-comment surfaces exposes — alongside new
  403/422 pins for the formerly-crashing denied and invalid creates.
  The independent pre-merge review then caught the final member of the
  class on the event-addressed twin: the anonymous guest-RSVP and
  guest-claim requests answered 403 for an event in a hidden group but
  404 for a missing one (disagreeing with the public read of the same
  event, which already folded). Folded those too, with a pin asserting
  the hidden-event and missing-event responses are byte-identical —
  status alone being what let every earlier oracle hide.

### Added

- The `GET /api/v1/instance` `features` object now carries
  `vapid_public_key` (issue #251, part of #186): the raw VAPID public
  key the PWA needs for `PushManager.subscribe`, `null` when push
  isn't configured server-side (and `web_push` now reflects real
  server config rather than a hardcoded `true`). The notifications
  settings page reads it and enables the push toggle — the last piece
  the #186 client work was blocked on.

- Account lifecycle over the API and PWA (issue #258, part of #187):
  the three flows that were LiveView/browser-only — email change,
  account deletion, and the GDPR export — now exist on the API, so
  SPEC §12's data rights survive the LiveView cut. `POST
/me/email-change` emails the new address a single-use confirmation
  link landing in the PWA (same notify-the-new-address-only semantics
  and per-user rate limit as the web flow); `POST
/me/email-change/confirm` consumes the token and — because device
  tokens are bound to the address they were issued under — answers
  with a rotated `device_token` for the confirming device while every
  other device signs out. `DELETE /me` deletes the account via
  `Kammer.Gdpr.delete_account` after the caller types their own email
  back (`confirm_email`, 422 on mismatch — possession of the device
  token is the re-auth, the typed address confirms intent); `GET
/me/export` streams the same export zip as the browser route. The
  PWA grows the matching surfaces: an email-change section on the
  profile page, the `/confirm-email/{token}` landing (which updates
  the stored instance's email and swaps in the rotated token), and a
  "Data & account" page per instance with export-to-download and the
  typed-email delete flow that removes the instance locally on
  success. EN+DA strings, OpenAPI operations + conformance taps, and
  API tests covering the full round-trip, deletion semantics, and the
  export payload.
- Report intake for event and assignment comments (issue #262, part
  of #187): `POST .../events/{event_id}/comments/{comment_id}/report`
  and `POST .../assignments/{assignment_id}/comments/{comment_id}/report`
  close the gap #263's contract trace found — the shared comment
  engine (ADR 0007) already let members report these comments in
  LiveView, but the API only exposed the post/post-comment intake, so
  the moderation queue would have lost event/assignment-comment
  reports at the LiveView cut. Same `Moderation.report_comment/3`
  behind both: neutral `201 {status: "reported"}`, a repeat report
  answers identically, an invisible subject 404s byte-identically
  (no-oracle, #156/#161), and filing draws from the same 20/h
  per-reporter budget as every other report (the shared acknowledgement
  now lives in `KammerWeb.Api.ReportIntake`, one definition for all
  four intake endpoints). PWA: the Report action now shows on event
  comments and on assignment-discussion comments, reusing the feed's
  inline reason form + confirmation idiom and existing EN/DA strings;
  `schema.d.ts` regenerated.
- PWA join flow (issue #255, part of #187): the invite link admins
  share (`/invite/{token}`) now lands on a real page in the Svelte
  client — until now the PWA had no invite landing and no registration
  form, so post-cut no new member could have joined. The landing
  previews what the invite opens (community/group, real-names note)
  via the until-now-unused public preview endpoint, with dead tokens
  collapsing into one calm "no longer valid" state; a visitor already
  signed in to this instance gets a one-tap accept, everyone else
  branches into sign-in or a new registration form (display name +
  email → magic link, `POST /auth/register`'s first client). The
  invite token rides sessionStorage through the email round-trip, so
  arriving back via the magic link accepts automatically and lands in
  the joined community/group; the sign-in screen also gains a
  create-account branch when the probed instance reports open
  registration. EN+DA strings, and a new e2e spec
  (`04-join.spec.ts`) drives the whole newcomer path — invite link →
  register → magic link → joined.
- Report creation over the API and the PWA report flow (issue #256,
  part of #187): `POST .../posts/{post_id}/report` and
  `POST .../posts/{post_id}/comments/{comment_id}/report` file a
  moderation report through the same `Kammer.Moderation` functions
  the LiveView flow uses — the group-feed slice of the gap where the
  moderation queue would have had no intake once LiveView goes
  (event- and assignment-comment reporting still needs its API
  sibling; tracked separately). The answer is a neutral
  `{status: "reported"}` (201) — a repeat report of the same subject
  answers identically, and an invisible post/comment 404s like every
  other feed write (no oracle, #156/#161). Filing is rate-limited to
  20 reports per reporter per hour — a fixed anti-abuse backstop (ADR
  0027 tier 3), enforced in the context so every surface shares it.
  The PWA's member group feed gains the matching UI: a Report action
  in the post menu and on every comment, an inline reason form, and a
  confirmation once it's sent (EN + DA).
- PWA notification center (issue #257, part of #187): the
  Notifications tab, previously a pure empty-state stub, is now the
  real in-app list — `NotificationLive.Index` parity over the #173
  API. Notifications merge newest-first across every added account
  (same multi-instance shape as Home/Events, per-instance #159
  failure kinds surfaced without blanking the rest), with unread
  emphasis, optimistic mark-read on tap, mark-all-read fanned out per
  instance, and tap-through into the right account's group feed or
  event page. EN + DA strings; store merge/mark-read logic covered by
  Vitest specs.
- Operator-configurable tier-2 deployment settings (issue #234, ADR
  0027): the throughput/policy rate limits, token lifetimes, and
  retention windows an operator legitimately tunes now read from
  `Kammer.Config`, each with a bounds-validated env override that
  fails the boot (naming the offending var) on an invalid value
  instead of silently clamping or being dropped — new vars
  `RATE_LIMIT_POSTS_PER_5MIN`, `RATE_LIMIT_COMMENTS_PER_5MIN`,
  `RATE_LIMIT_UPLOADS_PER_10MIN`, `RATE_LIMIT_EVERYONE_MENTIONS_PER_HOUR`,
  `SESSION_VALIDITY_DAYS`, `API_DEVICE_VALIDITY_DAYS`,
  `CHANGE_EMAIL_VALIDITY_DAYS`, `CONTENT_RETENTION_DAYS`,
  `TRANSIENT_UPLOAD_DAYS`, `GUEST_CONFIRM_LINK_HOURS`, and
  `GUEST_MANAGE_LINK_DAYS` (documented in `.env.example`). Every
  default is unchanged — the anti-abuse/security rate limits
  (magic-link, login-code, signup, setup, email-change, invite
  issuance) deliberately stay fixed constants, per ADR 0027.
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
- Tokenless public content-read endpoints over the JSON API (issue
  #185 slice B, the server half of the last #187 rung before the
  LiveView cut): `GET /api/v1/public/communities/:community_slug`
  (public face plus its `public_listed` groups), `.../groups/:slug`
  and `.../groups/:slug/posts` (cursor-paginated feed) and
  `.../posts/:post_id`, and `.../events/:event_id` — enough for the
  PWA to host the guest RSVP/signup-claim/comment request forms
  (above) on public content pages without an account. Every read is
  scoped through the new `Authorization.publicly_readable?/1` — the
  same `public_link`/`public_listed`-and-not-archived boundary the
  RSS/Atom feeds and the guest request endpoints already expose,
  additionally hardened against sealed groups since this is a
  newly-browsable JSON surface; a community/group/event/post that
  exists but isn't publicly readable answers the identical neutral
  404 a nonexistent one does — no oracle (#156/#161). The group feed
  and single-post read exclude soft-deleted posts entirely (not shown
  as tombstones, unlike the authenticated feed) since a guest has
  nothing to comment on there and the guest-comment request endpoint
  already refuses one. The `Group` serializer gained
  `guest_rsvp_allowed`/`guest_comment_allowed`/
  `guest_subscribe_allowed` so a client can decide whether to render
  those forms without guessing from `visibility`/`archived`/`sealed`
  or trying a request and handling the refusal. OpenAPI operations,
  schemas, and conformance taps included.
- Tokenless public reads of post attachments (issue #185 slice B):
  `GET /api/v1/public/files/:file_id` and its `/thumbnail`/`/download`
  twins serve the same bytes and hardening headers as the
  Bearer-authenticated `/api/v1/files/:file_id` (`KammerWeb.FileServing`
  shared between them), so an anonymous PWA visitor browsing a public
  post can load its image/file attachments — previously every
  attachment URL pointed at the Bearer-protected route, so a guest
  hit a 401 on every image in a public post's feed. Authorization is
  a new `Kammer.Files.fetch_public_file/1`, strictly narrower than the
  actor-based scope check `fetch_accessible_file/2` uses: a file is
  public only when it's an attachment on a post an anonymous visitor
  can already read through `PublicController.post/2` (published, not
  pending approval, not deleted) whose group additionally passes
  `Authorization.publicly_readable?/1` — never merely because its
  owning scope (a group/community file space) is publicly viewable,
  so library files not attached to any visible post stay 404. The
  `Serializer.post/4` shape gained a `public: true` option so posts
  read through the `/public` surface emit attachment URLs pointing at
  the new route instead, without changing the Bearer-authenticated
  shape any existing client already depends on. OpenAPI operations
  and conformance included.
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
- Public community/group/post/event browse screens in the PWA, hosting
  the guest RSVP/signup-claim/comment request forms (issue #185 slice
  B, the client half of the last #187 rung before the LiveView cut —
  this is the guest-parity surface #187 was gated on). Four new
  top-level, tokenless routes consume the public content-read
  endpoints above: `/c/:community` (public face plus its
  `public_listed` groups), `/c/:community/g/:group` (description plus
  a cursor-paginated feed with load-more), a post page nested under
  the group (body, attachments, comments, and the guest comment form),
  and `/c/:community/events/:event` (details, RSVP counts, signup
  slots, and the guest RSVP/claim forms). Every guest form honors the
  `guest_rsvp_allowed`/`guest_comment_allowed` flags the group
  serializer now exposes — hidden entirely rather than shown and
  refused — and answers with the same neutral "check your email to
  confirm" state the request endpoints already guarantee (rate-limited,
  no oracle on whether an email is already known). The RSVP and
  signup-claim forms share `guest_rsvp_allowed` (one flag governs
  both, matching `Authorization.can_guest_rsvp?/1` server-side); each
  open signup slot reveals its own claim form rather than one shared
  one, since a claim is scoped to a specific slot. Post/event bodies
  render through the same sanitized Markdown component the
  authenticated feed uses; comments render read-only (no reactions,
  edit, or reply — none are guest capabilities). Attachments link
  straight to the serializer's plain URLs rather than the authenticated
  feed's Bearer-fetched object URLs (a guest holds no device token) —
  today that means an anonymous visitor's image request can 404 until
  the public-file-serving path lands in a parallel PR, so each image
  degrades to a neutral placeholder on load failure instead of a
  broken-image icon. `schema.d.ts` regenerated from the merged spec to
  pick up the five new `/api/v1/public/...` operations. EN + DA
  throughout.
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
- End-to-end Playwright coverage of the Svelte PWA (issue #235): the
  client-side counterpart to the LiveView smoke test
  (`scripts/screenshots.sh`), and the piece of test coverage the
  LiveView removal (#187) needs before it can proceed without losing
  browser-level assurance. `clients/web/e2e/global-setup.ts` builds
  and stages the client at `priv/static/app` (exactly where the
  Dockerfile's client stage puts it) and boots a real `mix phx.server`
  against a throwaway `kammer_dev` database — same-origin, so the
  suite exercises the deep-link sign-in flow's actual
  `window.location.origin` assumption rather than working around it
  with a second dev-server port. Three serial spec files cover what a
  first-time operator and a later anonymous visitor both do: the
  first-run setup wizard through to a magic-link sign-in
  (`01-onboarding.spec.ts`); posting with a file attachment, seeing it
  in the feed, creating an event, and RSVPing (`02-content.spec.ts`);
  and the tokenless public surface — anonymous browse of a public
  community/group/post/event, plus the guest comment and RSVP request
  forms landing on a neutral "sent" state (`03-guest.spec.ts`). A new
  `e2e` CI job runs the suite headless on every PR, structured like
  `smoke` (same Postgres service, Nix/Mix caching, and
  runner-provided Chrome) but skipping the LiveView asset-build step
  the Svelte client doesn't need. `scripts/e2e.sh` runs the same suite
  locally.
- Service worker, offline reading, and Web Push registration for the
  Svelte PWA (issue #186, the final parity-ladder rung before the
  LiveView removal cut, #187). `clients/web/src/service-worker.ts`
  uses SvelteKit's native `$service-worker` build support (no workbox
  dependency): it precaches the hashed build bundle, the static
  files, and the SPA shell (fetched explicitly — it isn't part of
  either, since `KammerWeb.PwaController` renders it per-request) into
  a version-named cache, serves precached assets cache-first and
  everything else network-first, and falls back to the cached shell
  only on a failed navigation (offline). New versions install silently
  and take over on reconnect/next-visible rather than mid-session
  (`$lib/pwa/register-service-worker.ts`), matching the LiveView
  side's "clients pick up new versions on reconnect" (SPEC §13).
  `endpoint.ex`'s `Plug.Static` `only:` allowlist gained
  `service-worker.js` (the one server-side touch this client work
  needed — the file wasn't in the allowlist, so it fell through to the
  SPA fallback and served HTML instead of the worker script) with a
  `no-cache` header so an HTTP cache can't mask a new build from
  `registration.update()`.
  Last-fetched-data offline reading (SPEC §14, full write queue stays
  #137) is a small `localStorage` snapshot per view
  (`$lib/offline/snapshot-cache.ts`) — the leanest option that
  satisfies "last data readable offline with a stale indicator"
  without an offline database or a service-worker-level HTTP response
  cache (which would also have to reason about auth headers and
  multi-instance CORS invalidation). Home, the Events tab, and a
  group's feed each fall back to their last snapshot when every added
  instance is unreachable, and show a calm `StaleBanner` while doing
  so.
  Web Push registration lives on a new per-instance You page
  (`you/[instance]/notifications`), wired to the existing
  `POST`/`DELETE /api/v1/push-subscriptions` endpoints (#173) via
  `$lib/push/api.ts`, and unregisters best-effort on sign-out
  (`revokeAndRemoveInstance`). Because a browser holds one push
  subscription per _origin_, and the PWA is instance-served (one
  origin per instance), push is only manageable from the instance
  actually serving the page — the settings page detects a mismatch and
  points elsewhere rather than offering a dead control.
  `service-worker.ts`'s `push`/`notificationclick` handlers and
  `$lib/push/notification-routing.ts` translate a notification's
  server-sent link (`Kammer.Notifications.push_payload/4`'s
  `{title, body, url}`) into the right in-PWA account/community route,
  landing on an already-open window via `postMessage` or a cold-opened
  one via a `notify` query param the root layout resolves (a service
  worker has no `localStorage` access, so it can't resolve instances
  itself). Actually subscribing is currently blocked on issue #251:
  `GET /api/v1/instance` exposes whether a server has push configured
  (`features.web_push`, unchanged) but not the VAPID public key
  `PushManager.subscribe()` needs — the settings page shows an honest
  "almost there" state instead of a non-functional button; the client
  plumbing (`subscribeToPush`/`unsubscribeFromPush`) already takes the
  key as a parameter and needs no further change once #251 lands.
  Manifest/icons (shipped earlier) were manually re-verified against
  an installability checklist: `start_url`/`scope` within the service
  worker's scope, 192/512/maskable icons, `standalone` display — no
  Lighthouse available in this container.

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

- Configuration-layer hygiene, the no-decision "clear fixes" slice of
  the ADR 0027 audit (issue #234). `MIN_CLIENT_VERSION` now actually
  wires the advertised minimum-client-version knob to an env var
  (`config/runtime.exs`, documented in `.env.example`) — previously
  `Kammer.min_client_version/0` read a config key nothing ever set, so
  the advisory floor could never be raised without hand-editing
  source. The `"Kammer"` product-name default, previously re-typed at
  ten `Application.get_env(:kammer, :product_name, "Kammer")` call
  sites across the notifiers, digests, newsletters, and templates, now
  has one accessor (`Kammer.product_name/0`, mirroring
  `min_client_version/0`) that every call site uses instead. The
  endpoint's request-body length ceiling (previously a hardcoded
  `128_000_000`) now derives from `UPLOAD_MAX_MB` plus fixed multipart
  headroom via a small wrapper plug (`KammerWeb.Plugs.BodyParsers`),
  so raising `UPLOAD_MAX_MB` no longer requires the source edit
  `.env.example` used to ask operators for — `Plug.Parsers` bakes its
  options in at compile time, before `config/runtime.exs` runs, so the
  wrapper recomputes them per request instead. Several bare magic
  `limit:` literals (`Digests`, `Newsletters`, `Feed.list_home_feed/3`,
  `Events` past-events) are now named module attributes with a
  one-line rationale, and the duplicated 24-hour event-reminder lead
  time (`Kammer.Events` and `Kammer.Workers.EventReminderWorker` each
  hardcoded `-24, :hour`) is now a single `Kammer.Events.reminder_lead_hours/0`
  accessor both read, so they can't drift apart.

- Documentation drift between the spec/README/moduledocs and the
  shipped code (issue #93, round-2 quality audit). `SPEC.md` cited a
  nonexistent `RESTORE.md` (the restore walkthrough lives in
  `docs/backups.md`) and still called the cross-community **Home**
  feed "roadmap" though it shipped (`Kammer.Home`, ADR 0015); the
  README still listed passkeys as roadmap though they shipped (ADR
  0018). Four moduledocs cited the wrong SPEC section (Search →
  §10, digests → §9, not §16 "Architecture strategy"), `Notifications`
  implied digests were unbuilt, and `Kammer.Repo`/`Kammer.Mailer` had
  no `@moduledoc` despite CONVENTIONS requiring one on every module.

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

### Security

- Bumped `plug` (1.20.2 → 1.20.3) and `postgrex` (0.22.2 → 0.22.3,
  plus `db_connection` 2.10.1 → 2.10.2) to clear two newly-published
  advisories against the pinned versions: CVE-2026-56814 (plug's
  multipart `:length` limit not charged for part headers → unbounded
  temp-file creation, a DoS) and CVE-2026-58225 (Postgrex dollar-quote
  injection in the reconnect notification replay → notification DoS).
  Both had started failing `mix deps.audit` in CI on every branch.

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
