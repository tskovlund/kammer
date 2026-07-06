# BUILDLOG

Session journal and decision record for the Kammer Phase 1 build (SPEC.md §16).
Every scope trim, stub, deferral, or library substitution is recorded here —
silent stubs are forbidden by the one-shot build rule (SPEC.md §16).

Format: newest entries at the bottom. Each entry: date, what was done/decided,
why, and (for trims) precisely how to complete the cut work.

---

## 2026-07-06 — Session start, environment bring-up

**State**: empty repository, branch `claude/kammer-phase-1-g0wnzc`.

**Build container**: Ubuntu 24.04, no Nix/Elixir preinstalled. Installed
Determinate Nix 3.21.1 (Nix 2.34.7) with `--init none` (no systemd in
container); `nix-daemon` started manually in the background. Verified binary
cache fetch + build work through the outbound proxy. PostgreSQL 16 runs
locally in the container for dev/test (the flake provides the client; CI and
compose provide their own server).

**Decision — flake is canonical** (SPEC §14): `flake.nix` defines the dev
toolset; `.envrc` (`use flake`) and `devbox.json` wrap the same set. CI enters
the environment with `nix develop --command` so the toolchain in CI is
byte-identical to local dev.

**Decision — toolchain pin**: Elixir 1.18 on Erlang/OTP 27 from a pinned
nixpkgs-unstable revision (flake.lock). Boring, current stable pair; Phoenix
1.8 supports both. devbox.json pins the same major versions via the devbox
package index.

**Decision — nixpkgs pinned via releases.nixos.org tarball, not `github:`**:
this build container's egress proxy blocks GitHub fetches outside the session
repo scope, so `github:NixOS/nixpkgs/...` flake inputs cannot be fetched here.
The flake instead pins the immutable channel-release tarball
`https://releases.nixos.org/nixpkgs/nixpkgs-26.11pre1027958.c4013e501c04/nixexprs.tar.xz`
(locked with narHash in flake.lock). This is equally reproducible — the URL is
versioned and immutable — and avoids the GitHub API rate limit for anonymous
users as a bonus. `flake-utils` was dropped (hand-rolled `forAllSystems`) to
keep the input set to exactly one. If a maintainer prefers `github:` inputs
later, swap the URL and re-lock; nothing else changes.

**Verified** (inside `nix develop`): Elixir 1.18.4 (OTP 27), Mix 1.18.4,
Node v22.23.1, psql 16.14, vips 8.18.3, lefthook 2.1.5.

**Note — devbox path not runtime-verified in this container**: devbox is not
installable here (its installer fetches from GitHub, blocked by the egress
proxy). `devbox.json` mirrors the flake package set and uses standard devbox
schema; a contributor with devbox should run `devbox shell` + `mix setup` to
confirm. Risk is low (same nixpkgs underneath). To complete: run
`devbox shell` on an unrestricted machine and fix any package-name drift.

## 2026-07-06 — §17 toolchain wired (SPEC §16.1, §17)

- mix format, **Credo 1.7 strict** (+ `Readability.Specs` for @spec-on-every-
  public-function, `Readability.ModuleDoc`, and a custom check
  `Kammer.CredoChecks.NoSingleLetterVariables` in `tooling/credo_checks/` —
  Credo has no built-in single-letter ban), **Dialyzer** (dialyxir, PLT in
  `priv/plts/`), **Sobelow** (`.sobelow-conf`; `Config.HTTPS` ignored because
  TLS terminates at the reverse proxy per the deployment model), **ExCoveralls**
  with an 80% floor (`coveralls.json`; scaffold's vendored
  `core_components.ex` excluded from coverage as vendored library code),
  **mix_audit/hex.audit**, **warnings-as-errors** project-wide, **lefthook**
  hooks (commit-msg: commitlint; pre-commit: format+credo+compile; pre-push:
  tests) auto-installed via `mix hooks.install` in `mix setup`, **commitlint**
  (config + npm tooling under `tooling/commitlint/`), **GitHub Actions CI**
  running every check inside `nix develop --command`.
- Added `@spec`/`@moduledoc` to all scaffold modules to satisfy strict Credo.
- Removed the scaffold's unused `:api` router pipeline (JSON API is v2).
- Dialyzer: clean. Tests: 9 passing, coverage 97.1%.

**Dependency verification (Hex, 2026-07-06)** — all §22 picks current:
credo 1.7.19, dialyxir 1.4.7, sobelow 0.14.1, excoveralls 0.18.5,
mix_audit 2.1.5, oban 2.23.0, swoosh 1.26.3 (scaffolded), wax_ 0.7.0
(Phase 2), vix 0.40.0, hammer 7.4.0, icalendar 1.1.3, stream_data 1.3.0.
**Markdown: chose MDEx 0.13.3 over Earmark** — Earmark's latest is a 1.5
pre-release and it has no built-in sanitization; MDEx is actively maintained
(2026-07 release) with sanitized output. **Web push: web_push_ex 0.2.0** is
the only maintained option (web_push_encryption abandoned 2021); final call
recorded at step 7 when wired.

## 2026-07-06 — Step 2: magic-link auth, sessions, devices (SPEC §2, §16.2)

Base: `mix phx.gen.auth` (Phoenix 1.8.8, magic-link-first) — boring and
battle-tested — then stripped to passwordless-only per SPEC §2:

- Removed all password paths (bcrypt dep, hashed_password column, password
  forms/flows/tests). Magic links are single-use, 15-minute, confirmed by an
  explicit button (prevents email-scanner bots consuming links).
- `users`: added `display_name` (the only required base field, SPEC §4),
  `locale` (en/da), `timezone` (validated against the tz database).
- **Rate limiting** (SPEC §11): `Kammer.RateLimit` (Hammer 7, ETS backend) —
  magic-link issuance capped 3/15min per email, 10/15min per IP, enforced in
  the Accounts context so any future caller (API v2) inherits it. Context
  tests cover both limits.
- **Devices page** (`/users/settings/devices`): sessions listed with parsed
  user agent + sign-in time, current-session marker, individual revocation
  (scoped so users can't revoke others' sessions — tested).
- Settings: display name, language, timezone; email change via confirmed
  link (unchanged from generator); sudo-mode gating kept.
- Localized auth emails per user locale; all auth surfaces gettext'ed, DA
  complete (69 strings).
- **tz 0.28 instead of tzdata**: tzdata's hackney dependency conflicts with
  gen_smtp's idna 7; `tz` is maintained, pure-Elixir, embeds IANA data.

**Deferred (how to complete)**:
- *Passkeys/WebAuthn*: Phase 2 per SPEC §16.2. Add `wax_ 0.7`, a
  `user_credentials` table, registration in settings (behind sudo mode), and
  a discoverable-credential login button on the sign-in page.
- *Guest identity upgrade* (claiming RSVP/subscriber history on first login,
  SPEC §2): implemented when guest artifacts exist (events step): on magic-
  link confirmation, look up guest records by email and re-own them.
- *Locale/timezone auto-detection* (SPEC §4): currently defaults en/UTC,
  editable in settings. Complete by reading Accept-Language in a plug and a
  JS hook posting `Intl.DateTimeFormat().resolvedOptions().timeZone` once
  after login.
- *Session IP recording*: user_agent is stored per session; adding the
  client IP column is trivial if wanted, but was left out deliberately
  (privacy-first: don't store more than needed).

## 2026-07-06 — Step 3: communities, groups, authorization (SPEC §3, §16.3, §17)

**Authorization module** (`Kammer.Authorization`) — the product core:
pure decision function `can?/4` taking the actor's relationship
(instance-operator flag, community role, group role) explicitly; the
Repo-backed `can?/3` and `listable_groups_query/2` are the only DB-aware
surfaces. Property suites (StreamData) cover: anonymous actors, archived
read-only, operator-flag inertness, role monotonicity, and a dedicated
sealed-group suite. The property tests sharpened ADR 0005's wording:
sealing reduces community admins to plain-member rights (a sealed
`community`-visibility group is still visible to them *as members*), plus
whole-group deletion.

**Domain**: communities (slug-namespaced, accent color, per-community
default locale, real-names statement toggle, instance-listing opt-in),
memberships with Owner/Admin/Member, groups with the four visibility
presets + join/posting/comment policies + approval-queue toggle +
irreversible sealed flag (never cast on update) + archive state, join
requests, invites (community or group; expiry, max-use with row-locked
atomic redemption, revocation, email-bound with delivery), instance
settings singleton, cross-instance bookmarks.

**Web**: §21 shell — mobile bottom tab bar (Home·Events·Groups·
Notifications·You), desktop sidebar with avatar-stack switcher, top-bar
switcher dropdown on mobile; paper/ink daisyUI themes (light+dark twins);
runtime accent re-tinting via CSS custom properties fed by
`Kammer.Design.AccentColor` (`.community-accent` maps them onto daisyUI
primary slots; dark mode swaps the dark-surface variants). Pages:
instance landing, community home (member + public variants), groups
directory with archived section, group create/show/settings (join
requests, invites, archive, delete), member directory with role
management, community settings (branding retints live, invite links,
email invites), invite landing + accept endpoint (signed-out flow rides
the existing return-to mechanism through magic-link sign-in), events and
notifications tabs with designed empty states (filled by their build
steps), "My other servers" bookmarks page.

**Decisions where SPEC is silent** (boring defaults):
- Any community member may create a group (becomes Owner). Rationale:
  communities are invite-gated trusted spaces; sealed groups exist for
  private circles. Revisit if pilot feedback demands an admin gate.
- Community slugs are immutable in settings UI (stable public URLs §3).
- No open "join community" flow: communities are entered by invitation
  only (public page says so). SPEC describes invite links + guest flows;
  nothing describes open community joining.
- Group members are always community members (invariant enforced in
  `Groups.add_member/3`; group invites also join the community).
- Owner-role transitions require the actor to hold Owner (community) or
  owner-equivalent powers (group).

**Coverage note**: suite at 89.1% with 205 tests / 10 properties.

## 2026-07-06 — Step 4: feed (SPEC §5, §16.4)

**Domain** (`Kammer.Feed`): Markdown posts (MDEx, raw HTML stripped, one
rendering config in `Kammer.Markdown`), polls (single/multi, close date,
anonymity toggle, single-choice replaces vote), reactions (curated emoji
set on posts and comments, DB-constrained one-subject), comments with
exactly one reply level (replies-to-replies reparent to the top-level
comment — ADR 0007), per-post comment locks, pins (pinned first, then
strictly chronological — ADR 0006), scheduled publishing (future
`published_at` + Oban job for live appearance), acknowledgment-required
posts with author/admin-only status, edit history (author-only editing;
admins moderate but never rewrite), soft-delete stubs with 30-day content
purge (daily Oban cron), approval queue (holds non-moderator posts),
`@everyone` gated to broadcast rights + rate limited (2/group/hour),
per-user new-since-last-visit markers (private, no "seen-by"), PubSub
live updates on a per-group topic.

**Files/media slice** (shared infra, completed in files step):
`Kammer.Storage` behaviour + Local adapter (traversal-guarded),
`Kammer.Media` (libvips): every image re-encoded to JPEG (destroys
payloads §11, strips EXIF §19, auto-rotates), WebP thumbnails, HEIC in
the accepted set; non-images stored as-is and always served as downloads
with nosniff (SVG never inline). Transient attachments auto-expire after
30 days (daily cron). File access enforces the visibility baseline
(group files ⇒ `:view_group`, community files ⇒ `:view_community`).

**Authorization additions**: pure post-level rules (`can_edit_post?`,
`can_soft_delete_post?`, `can_hard_delete_post?`, `can_pin_post?`,
`can_lock_post_comments?`, `can_view_acknowledgments?`,
`can_view_edit_history?`, `can_react?`).

**Web**: shared `FeedEventHandlers` so group feed and aggregated home
feed behave identically; composer (Markdown textarea, ack toggle,
post-as-group, datetime-local scheduling in the user's timezone, poll
builder, multi-file uploads with transient toggle); post cards with
image grids/file rows/live polls/reaction picker/collapsible replies/
ack modal; CSP added (Sobelow caught the §11 requirement).

**Decisions / trims (with completion paths)**:
- *S3 storage adapter*: deferred to the files step — behaviour is in
  place; implement `Kammer.Storage.S3` (req-based, SigV4 or a small
  S3 lib) reading `S3_*` env, register in runtime.exs.
- *Rich-text toolbar*: composer is a Markdown textarea (placeholder says
  so). Complete: small JS hook wrapping selection in Markdown markers +
  toolbar buttons; no editor dependency planned.
- *User @mentions*: `@everyone`/`@admins` extracted (`Feed.Mentions`);
  per-user `@Display Name` mentions resolve at notification time
  (step 7) — no stable usernames exist by design.
- *Lightbox*: images open the re-encoded display file in a new tab;
  a JS lightbox is cosmetic follow-up.
- *Home feed*: aggregates the groups the user is a member of (SPEC says
  "aggregated home feed scoped to the active community" — membership is
  the boring reading; community-visible non-member groups are browsable
  via the directory instead).
- *MDEx NIF in restricted build environments*: precompiled NIF downloads
  from GitHub releases; this container's proxy blocks that, so the NIF
  was built from source (optional `rustler` dep added; set
  `MDEX_NATIVE_BUILD=1` + Rust toolchain). Normal contributors and CI
  fetch the precompiled binary; nothing to complete.
- *Oban in tests*: `testing: :manual` — the scheduled-post worker is unit-
  invisible; its behavior (hidden until published_at) is tested via the
  feed query.
