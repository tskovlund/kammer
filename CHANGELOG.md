# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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
