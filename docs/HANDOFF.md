# HANDOFF — state, process, and the executable roadmap

Written 2026-07-06 at the end of the Fable-5 build run, for the agent
(and humans) picking the work up. Everything here is current as of
the guest-comments PR. **Keep this document true**: every PR that changes the state
of the roadmap updates it — a stale handoff is worse than none.

## 1. Where the product stands

Phase 1 (SPEC.md, the authoritative product spec) is complete and
merged, plus, from Phase 2 and the decided roadmap:

- **Guest RSVP on public events** (ADR 0013) — email-only guest
  identities, signed confirm/management links, ICS attachment, full
  guest erasure, automatic history claim on sign-in.
- **Guest comments with approval queue** (§5.3) — the
  `members_and_guests` comment policy is now real: confirm-by-email,
  pending-until-approved, inline moderation, general guest manage
  page at `/guest/manage/:token`.
- **Versioned files** (ADR 0017) and the **OpenAPI document** with
  its router drift guard (§5.1, §5.2).
- **Per-group feature toggles** (ADR 0016) — `features` on groups;
  one gate (`Authorization.feature_gate/2`); disabled == not-found.
- **Cross-community Home** (ADR 0015) — merged chronological lens on
  the start page; `show_in_home` on memberships (default ON, sealed
  included, prominent toggle on the group page).
- **JSON API v1 core** (ADR 0014) — device-token auth, one error
  envelope, cursor pagination, instance discovery, communities/
  groups/feeds/posts/comments/events/RSVP/Home endpoints, and the
  **transport-parity property test** (API hides exactly what the UI
  hides).

Suite at handoff: **390 tests + 17 properties, zero failures**, ~83%
coverage with an 80% one-way tripwire (never ratchet it — BUILDLOG
explains). All CI required checks green on `main`.

## 2. The process (non-negotiable)

1. **One coherent PR at a time** from your designated branch to
   `main`; merge commits (squash only for noise); required checks:
   Conventional Commits, the quality gate, Docker image, Smoke test.
2. **`mix precommit` green before every push.** Hooks run it partly;
   CI fully. Never weaken a check to pass it.
3. **Authorization changes live in `lib/kammer/authorization.ex`
   only**, with context-level tests — property-based (StreamData)
   whenever an invariant is involved. The transport-parity property
   (`test/kammer_web/api/resources_test.exs`) must keep passing.
4. **Every user-facing string through Gettext, English AND Danish**
   (`mix gettext.extract --merge`, then fill `priv/gettext/da/`).
   API error messages are deliberately English-only (clients localize).
5. **Docs move with the change** — README, docs/, CHANGELOG
   (`## [Unreleased]`), this file. **Issues too**: close what's
   settled, comment status deltas, no stale debt anywhere (owner rule).
6. **Decisions**: implementation choices are yours; product-shaping
   choices (pricing, naming, UX philosophy, new scope) go to a GitHub
   issue assigned to `tskovlund` with concrete options and a
   recommendation. Owner comments on issues override everything —
   read open issues at the start of every work session.
7. **Deliberate decisions get written down**: architecture → one-page
   ADR in `docs/decisions/`; designs awaiting owner sign-off → RFC in
   `docs/rfcs/`; scope trims/tradeoffs → BUILDLOG.md entry.
8. **No hacks** (CONVENTIONS.md): a workaround needs a comment naming
   the external cause, a tracked completion path, and removal when the
   cause dies. When pressed, shrink scope, not quality.
9. Migration churn is **welcome pre-0.1.0** (owner decision): design
   schemas properly rather than adding compatibility warts.

## 3. Environment traps (the ones that cost hours)

- The remote container: run `export PATH=/nix/var/nix/profiles/default/bin:$PATH`
  in every shell; `pg_ctlcluster 16 main start` after container
  restarts (stale pid is normal); commit/push inside
  `nix develop --command` (hooks need mix); committer identity must be
  `Claude <noreply@anthropic.com>`.
- **CSS cannot be built in the container** (the proxy blocks the
  Tailwind standalone binary; the npm CLI chokes on the vendored
  daisyUI bundle). Don't fight it: CI builds assets, the **Screenshots
  workflow** (manually dispatched, never on `main`) regenerates
  `docs/screenshots/` on a PR branch and its commits trigger CI
  (pushes with `SCREENSHOTS_PUSH_TOKEN`).
- LiveView forms must be **fully driven by `to_form`** — any field not
  round-tripped through the change event resets on re-render (this bug
  shipped once; the composer fix in PR #24's history is the pattern).
- Swoosh test assertions pop the _next_ mailbox message — drain
  fixture-generated emails first (see `drain_delivered_emails` in
  existing tests).
- Route order matters: literal segments (`/events/new`) must be
  defined before wildcards (`/events/:event_id`) across live_sessions.
- ETS rate limiter is global across async tests — use unique emails
  per test (`System.unique_integer`).

## 4. Patterns to reuse (don't reinvent)

- **Guest identities** (`Kammer.Guests`) are the substrate for any
  account-less interaction: guest comments, signup slots, newsletter
  subscriptions. Nullable FK + `num_nonnulls(...) = 1` check, cascade
  erasure, claim on sign-in.
- **Feature gate**: anything new that's per-group-toggleable adds a
  feature atom in `Group @features` (ships OFF by default!) and calls
  `Authorization.feature_gate/2` at context entry points.
- **API**: `KammerWeb.Api.Serializer` is the only wire-shaping layer;
  `ApiError` the only error shape; `Pagination` the only cursor code.
  New endpoints follow the existing controller pattern — thin, all
  policy in contexts/authorization.
- **Comments/reactions** are one engine (ADR 0007) — reuse for any
  new commentable/reactable thing.

## 5. The roadmap, in order, with executable detail

### 5.1 Versioned files — ✅ SHIPPED (ADR 0017; #15 closed)

Same-name-same-place uploads append versions; listings show current
versions only; history UI in FileLive; retention on groups+
communities; `version_seq` for deterministic order. Remaining
follow-up lives in #30 (API file endpoints). Original spec kept below
for reference.

### 5.1 (original spec) Versioned files (issue #15 — all decisions made)

The schema-surgery item. Owner decisions: history visible to everyone
who can see the file; unlimited versions default with admin-configurable
retention; replacing requires write permission on the entry; proper
schema split (no `supersedes_id` chain hack).

1. Migration: `file_entries` table (id uuid, community_id NOT NULL,
   group_id nullable, folder_id nullable, name string NOT NULL,
   current_version_id nullable FK → stored_files, timestamps; index on
   (community_id, group_id, folder_id)). Add
   `stored_files.file_entry_id` (nullable FK, delete_all from entry).
2. Backfill in the same migration: every stored_file that is a
   file-space file (has `folder_id` OR (`kind = 'file'` AND no
   transient_expires_at AND not referenced by post_attachments —
   check the attachments join table name in `lib/kammer/feed/`))
   gets a file_entry (name = filename, current_version = itself).
   Feed attachments and transient files stay entry-less.
3. Context (`Kammer.Files`): `upload_to_space` creates entry+version
   for new names; **new** `upload_new_version(actor, entry, path, info)`
   requires `can_write_folder?` on the entry's folder chain, runs the
   same hardening pipeline, appends a version, moves
   `current_version_id`. `list_files` returns entries with current
   version preloaded. `list_versions(actor, entry)` (visibility = can
   see the entry). `delete_file` → deletes entry + all versions;
   `delete_version` (uploader/admins; cannot delete the only version;
   deleting current moves the pointer to the newest remaining).
   Retention: `version_retention` (int, nullable=unlimited) on
   communities+groups settings; prune oldest on upload past the limit.
4. Quota/contributions already count all stored_files — unchanged
   (each version attributes to its uploader; verify
   `contribution_stats` and `space_usage_bytes` still true in tests).
5. UI (`FileLive.Index`): file rows get an "Upload new version" action
   (write-permitted users) and a version-history disclosure (uploader,
   time, size, download per version). Downloads of old versions via
   the existing `file_controller` path (a version is a stored_file —
   `fetch_accessible_file` must resolve visibility **via the entry**).
6. API: `GET .../files` entries endpoint later (not required in this
   PR; note it in the API backlog section of this file when done).
7. Tests: context CRUD + retention pruning + permission matrix +
   property: version visibility ≡ entry visibility. Close #15 on merge.

### 5.2 OpenAPI document — ✅ SHIPPED

Served at `/api/v1/openapi.json`; schemas in `KammerWeb.Api.Schemas`
mirror the serializer; paths declared in `KammerWeb.ApiSpec`; the
drift test (`openapi_test.exs`) pins document ↔ router. Remaining #30
boxes (Channels, endpoints) still open. Original spec below.

### 5.2 (original spec) OpenAPI document (finishes ADR 0014's contract promise)

1. `open_api_spex` is already a dep. Add `KammerWeb.ApiSpec` (info,
   servers from endpoint config, bearer security scheme), schema
   modules mirroring `Serializer` output exactly, operation specs on
   the existing API controllers.
2. Serve `/api/v1/openapi.json` (public). Test: spec validates, every
   router API path appears in it (enumerate `KammerWeb.Router.__routes__/0`
   filtered on `/api/` and assert coverage — that test is the drift guard).
3. Document in `docs/development.md`: clients generate from this
   (TypeScript now; Swift/Kotlin when native starts).

### 5.2b API completions (as clients need them — additive only)

Deferred deliberately from the core: **Phoenix Channels realtime** for
API clients (same PubSub topics LiveView uses); **API registration**
(v1 is web-only — decide with the owner before enabling); notification
endpoints (list/mark-read); file endpoints (entries + versions, after
5.1); push-subscription registration for native clients. Guest RSVP
stays web-only by design (guests hold no device tokens).

### 5.3 Guest comments + approval queue — ✅ SHIPPED

Groups with `comment_policy: :members_and_guests` (public presets
only, `Authorization.can_guest_comment?/1`): guest form on the public
feed → signed confirm link (the comment travels inside the token,
gzip-compressed, capped at 2000 chars — nothing stored until the link
is followed) → pending comment → inline approve/reject for moderators
(approve fires the deferred notification fan-out; reject
hard-deletes). Pending comments are filtered out at the database for
non-moderators (`Kammer.Feed.preloads/1`). The guest manage page is
now general (`/guest/manage/:token`, `GuestLive.Manage`): all RSVPs
(changeable) + all comments + full erasure; manage tokens carry
`%{identity_id}` only. `Guests.claim_history/1` moves comments too.
Note: the author check constraint is `num_nonnulls(...) <= 1`, not
`= 1` — user deletion nilifies `author_user_id`, and that must stay
legal. Tests: `test/kammer/guest_comments_test.exs`,
`test/kammer_web/live/guest_comment_flows_test.exs`.

### 5.4 Svelte PWA (ADR 0001; owner has signed off — #20 "go now")

First: file a **decision issue** for repo placement (recommend a
`clients/web/` directory in this repo — shared CI, atomic API+client
PRs, one issue tracker; separate repo only if CI time hurts). Then:

1. Scaffold SvelteKit (static adapter) + TypeScript + generated API
   client from `/api/v1/openapi.json` (openapi-typescript).
2. Multi-instance session-holder model per ADR 0001: instance list
   (add-by-URL), one device token per instance (localStorage; the
   Home screen merges `GET /home` across instances client-side).
3. v1 screens in order: sign-in (magic-link request + exchange),
   merged Home, community list, group feed (read + compose + comment
   - react later), events (list/detail/RSVP). PWA manifest + SW
     (app-shell only), Web Push via the existing VAPID endpoints later.
4. CI: separate job (node, pnpm, typecheck, vitest, build). Don't put
   it in the Elixir quality gate.
5. Keep LiveView fully working — parity before any deprecation talk.

### 5.5 Collaborative track (issue #17 — accepted; sub-issue each)

Order: **signup slots ✅ (#37) → availability polls ✅ (#39) →
assignments ✅ (#41) → decisions log → rotations.** Design bullets
live in #17; each feature: file a sub-issue, RFC only if the design
deviates from #17's bullets, feature atom in the group toggles (OFF
by default), EN+DA, property tests on any visibility rule.

Assignments SHIPPED (#41): `Kammer.Assignments` context, flat list
(open → done, due-date ordered), multi-claimant `assignment_claims`,
`:assignments` atom. Comments got their THIRD subject: the constraint
is now `num_nonnulls(post_id, event_id, assignment_id) = 1` and
`Feed.delete_comment` routes assignment comments too. Complete/reopen
follow the RSVP rule (trust by default; `completed_by_user_id` shows
who). Due-date nudges deferred to the digests work (#33); API to #30.
Remaining in the track: decisions log, rotations (design bullets in
#17).

Availability SHIPPED (#39): `Kammer.Availability` context,
`availability_polls/options/responses`, `:availability` feature atom
(the Group schema now has `@default_features` separate from
`@features` — new atoms join `@features`/`@toggleable_features` only,
so they're OFF everywhere until a group opts in). Create follows
`post_in_group`, answering follows the RSVP rule, close/convert is
creator-or-moderator; convert calls `Events.create_event` (fan-out
included) and stamps `converted_event_id`. UI: "Find a date" on the
group page, grid at `/c/:slug/availability/:poll_id`, open polls
listed on the events page. Members-only in v1 — guest availability is
a follow-up if asked for. API deferred to #30.

Slots SHIPPED (#37): `event_slots` + `slot_claims` (user XOR guest,
exactly-one — claims die with their person, delete_all both ways),
capacity under a `FOR UPDATE` row lock (race-tested), guest claims
via the ADR 0013 two-link flow on the `can_guest_rsvp?` policy,
manage page + claim-on-sign-in + erasure extended, slots in the API
event serializer. No new feature atom — slots live inside `events`
(an event without slots shows nothing); assignments WILL get its own
atom. Danish register: a slot is "en tjans".

### 5.6 Remaining Phase 2 (SPEC §16 list, descending priority)

- **Global search**: Postgres FTS; `tsvector` columns + GIN on posts,
  comments, events, file entries (+ file text extraction deferred);
  searcher must filter through `listable_groups_query` — add a
  property test (search never returns invisible content).
- **Email digests + newsletter subscriptions**: Oban cron; per-user
  digest frequency; newsletter = guest_identities subscribing to
  public groups (ADR 0013 again); content-minimized email mode.
- **Backups**: `mix kammer.backup` (pg_dump + uploads tar, optional
  age encryption) + restore doc + Oban schedule; SPEC §14.
- **Moderation**: report button → queue for moderators; bans
  (community + instance level); full rate-limit coverage.
- **GDPR export/erasure**: per-user JSON+files zip export (Oban job,
  download link) + account erasure (soft-delete content per SPEC §12).
- **Audit log**: append-only `audit_events` for admin/operator actions,
  visible to community owners / instance operator.
- **Passkeys**: `webauthn_components` or `wax`; register after first
  magic-link login; device page lists them.
- **Recurrence + attendance matrix**: RRULE-lite (weekly/biweekly/
  monthly), materialized occurrences, per-occurrence RSVP grid.
- **Admin update notice** (SPEC Phase 2): the instance surfaces
  "a newer Kammer exists" to operators — version check against GitHub
  releases, privacy-respecting (opt-out env flag, no phone-home
  payload beyond the version fetch).
- Then: RSS/Atom for public groups, content-minimized email mode,
  custom profile fields + roster, activity-sort view (opt-in,
  chronological stays default — values!), branding UI, Prometheus
  (PromEx), ClamAV option, NixOS module.
- **Security hardening, pre-1.0**: replace the CSP's
  `'unsafe-inline'` script allowance with LiveView nonce-based CSP
  (documented posture in the router; real work, tracked here so it
  cannot be forgotten).
- **Far-future path already decided** (SPEC v1 non-goals): group type
  templates ("Announcement channel", "Discussion forum", …) are the
  sanctioned route to configurable comment mechanics — never raw
  per-group threading switches.

### 5.7 Native apps (after the PWA settles — not before)

Swift + Kotlin, thin clients generated from the OpenAPI document
(swift-openapi-generator / openapi-generator kotlin). Per-platform:
UI shell, push (APNs/FCM), secure token storage. LiveView freezes at
Svelte parity, retired later (ADR 0001) — plan, don't rush it.

### 5.8 Standing operations

- Babysit every PR to green; Renovate fires Mondays 07:00 CPH —
  non-major automerges when checks pass, majors wait for the owner.
- Owner-court items to leave alone: #7 (test-drive), #8 (human review),
  #9 (miles deploy — assemble the nix-config PR when asked), #22
  (business model — act on answers when they arrive).
- Release: owner cuts v0.1.0 after #7 via docs/release.md. Fix
  forward, never re-tag.
- **Naming** (SPEC §15): "Kammer" is a working title; the display name
  is one config constant. Final-name verification is owner-court —
  raise it before any public marketing, never decide it.
- **Business model implications** (issue #22, when the owner answers):
  per-community active-member stats, billing integration, DPA
  template, instance-admin tooling for shared-instance hosting.

## 6. Definition of done, every PR

`mix precommit` green · EN+DA strings · authorization single-module +
property tests where invariants · ADR/RFC/BUILDLOG as applicable ·
CHANGELOG Unreleased entry · issues updated/closed · this file updated
if the roadmap moved · PR description says what and why, checklist
filled honestly.

## 7. Successor pickup prompt (verbatim — works with zero chat context)

Give a fresh agent session on `tskovlund/kammer` exactly this:

> You are taking over autonomous development of **Kammer**, a
> self-hosted community platform (Elixir/Phoenix/LiveView + JSON API).
> The owner is tskovlund; he is often away — you work autonomously and
> he decides asynchronously through GitHub issues.
>
> **Read first, in order:** `docs/HANDOFF.md` (your operating manual —
> state, process, environment traps, patterns, and the full roadmap;
> update it with every PR), then `CONVENTIONS.md` and `CLAUDE.md`
> (binding standards, including the no-hacks rule), then `SPEC.md`
> (the owner's original product prompt; its status note explains what
> is live), then skim `docs/decisions/` and **all open issues** —
> owner comments on issues override every plan; check them first,
> every session.
>
> **Process, non-negotiable:** develop on your designated branch; one
> coherent PR at a time into `main`; merge commits; `mix precommit`
> green before every push (never weaken a check); every user-facing
> string in English AND Danish via Gettext; all permission/visibility
> logic in `lib/kammer/authorization.ex` only, property-tested when an
> invariant is involved — the transport-parity property must never
> break. Update CHANGELOG, docs, issues, and HANDOFF.md with every
> change; close issues when settled; no stale debt. Architecture
> decisions get an ADR; product-shaping questions (pricing, naming, UX
> philosophy, scope) become issues assigned to tskovlund with options
> and a recommendation — never decide those yourself. Babysit every PR
> to green CI and merge it yourself.
>
> **Environment:** read HANDOFF.md §3 before your first shell command.
>
> **Your queue:** HANDOFF.md §5, mirrored by milestone issues
> #15, #17, #30, #31, #32, #33 — work from the issues and keep their
> checklists ticked. Take the top unfinished item unless an owner
> comment redirects you.
>
> Work steadily, prove everything with tests, and when in doubt about
> quality versus speed: shrink scope, never quality. Begin with the
> reading, then confirm your understanding of the queue in one short
> message before your first PR.
