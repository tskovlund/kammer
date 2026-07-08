# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

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

### Added

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
  and every email carries a one-click `List-Unsubscribe` header (RFC
  8058) alongside a signed management link that reuses the existing
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
  can't rejoin *any* community on the instance, not just one. Same
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
