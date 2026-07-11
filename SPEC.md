# Kammer: Self-Hosted Community Platform — Product Spec

This is the living definition of what Kammer is: the product's source
of truth, kept current as decisions change it. It started as the
owner's original build prompt and is edited in place as the product
evolves — it does not stay frozen at "what we set out to build."
`docs/decisions/` records the _why_ behind a decision worth
relitigating; this file records the _current_ shape of the product.
Shipped-vs-not is tracked in CHANGELOG.md/git history and open GitHub
issues, not here — this document describes intent regardless of build
status.

You are building a production-quality, self-hostable, open-source community platform — a replacement for Facebook Groups/Pages/Events, group email threads, and the file-sharing half of Google Drive, for real-world communities (associations, bands, clubs). Founding use case: TÅGEKAMMERET, a Danish student association, and its 70-year anniversary revy band.

Design ethos: privacy-first, no ads, no algorithmic manipulation, frictionless participation for non-members, honest about limitations, a joy to self-host. This is also a portfolio-grade codebase: engineering standards (§17) and documentation (§18) are deliverables, not afterthoughts.

---

## 1. Stack (fixed decisions — do not substitute)

- **Backend/UI**: Elixir + Phoenix (latest stable). **Phoenix LiveView** is the interim UI only — feature-frozen (bugfixes only) and removed entirely once the multi-instance Svelte PWA reaches full parity (§16, ADR 0024). Domain logic in Phoenix contexts — this is non-negotiable; the contexts and the JSON API are the permanent asset, the Svelte client is the product UI.
- **Database**: PostgreSQL via Ecto. UUID primary keys everywhere. Timestamps stored UTC; rendered in the user's timezone.
- **Styling**: Tailwind CSS. Clean, warm, modern, mobile-first (most users are on phones). Designed empty/loading/error states — the app must feel finished, not scaffolded.
- **PWA**: manifest, service worker (app-shell caching only; content online-only), installable on iOS/Android. **Web Push** via VAPID. (This describes the interim LiveView shell; the instance-served Svelte client is the product PWA — §16, ADR 0024.)
- **Real-time**: LiveView sockets (interim) and Phoenix Channels with device-token auth (API/PWA clients — §16, ADR 0024) + Phoenix PubSub (live feeds, comments, RSVP counts).
- **Files/images**: `Storage` behaviour with two adapters: local disk (default) and S3-compatible (MinIO/Hetzner Object Storage). libvips (`image`/`vix`) for processing.
- **Email**: Swoosh, configurable SMTP/provider adapters.
- **i18n**: gettext from day 1; English and Danish complete for everything shipped. Per-user language; per-community default.
- **Background jobs**: Oban (digests, reminders, backups, transient expiry, media processing, scheduled publishing).
- **License**: AGPLv3.

## 2. Identity & auth

- **Passwordless only.** Magic link via email (single-use, short-lived, rate-limited per email + IP) plus **passkeys (WebAuthn)** registerable after first login.
- **Email is the universal identity primitive.** Guests (RSVPs, newsletter subscribers, approved guest commenters) are email-only identities; signing in with that email upgrades to a full account and claims guest history automatically.
- Long-lived revocable sessions; "devices" settings page.

## 3. Tenancy, communities, groups

- **Multi-community per instance in v1** (the Discord model): one instance hosts many communities; one account, one login, memberships across communities, **instant community switching**. Every scoped table carries `community_id`; scoping must be airtight and flow through the central authorization module.
- **Community switcher**: avatar-stack switcher in the top bar (mobile) / sidebar (desktop). Additionally, a per-user **cross-instance list**: users can register other instances they belong to ("My other servers"); entries are smart bookmarks — full navigation to the other origin, relying on persistent sessions there. (True merged cross-instance views are roadmap; see §16.)
- **Instance-level roles now exist above communities**: instance operator/admin (manages the deployment, SMTP, storage policy, who may create communities — instance setting: operators only / any user); community creation produces a fresh Owner.
- Stable public URLs; community slugs namespace all routes (`/c/{community}/...`).
- **Community roles**: Owner / Admin / Member. **Group roles**: Owner / Admin / Member.
- Community Admins have **full override** on all groups in their community — except sealed groups. Instance operators have no in-app content access to communities they don't belong to (honest caveat everywhere: the server operator can technically read the database).

### Group settings

- **Visibility preset** (exactly four): `private` / `community` / `public_link` (unlisted) / `public_listed` (listed on its community's public page).
- **Public pages**: each community has a public page listing its `public_listed` groups. The instance landing page lists communities that opt in (per-community `listed_on_instance` toggle, default off).
- **Join policy**: invite-only / request-with-approval / open.
- **Posting policy**: admins-only ("broadcast/page" mode) / all members; orthogonal **approval queue** toggle.
- **Comment policy**: members / members + guests (guests always email-verified and approval-queued) / off. **Per-post comment lock** available to the author and admins.
- **Post as group**: admins may publish under the group identity (`author_type: user | group`).
- **Sealed flag** (creation-time only, irreversible): no community-admin access of any kind; their sole power is whole-group deletion. UI states honestly: "Sealed: hidden from community admins. The server operator can still technically access all data."
- **Archive state**: read-only, hidden from active lists, browsable under "Archived", files remain accessible, feeds and notifications stop. Unarchivable by admins. (Bands and committees are seasonal; institutional memory is the product.)
- **Per-group feature toggles** (ADR 0016): group admins choose which optional tools a group shows (events, files, availability polls, assignments, decisions register — the feed is always on). A disabled feature is fully hidden, not just unlinked: its routes, ICS feeds, and guest surfaces all behave as not-found. Toggling back on restores everything; nothing is deleted.

### Invitations

- Invite links with optional expiry and max-use count, revocable, per group and community. Admin email invites supported.

## 4. Profiles & member directory

- **Display name — the only required base field.** Free-form. **Per-community names policy toggle**: a community may require full/real names (policy statement shown when joining that community; not technically verified).
- **Profile scope**: the base profile (display name, avatar, bio, pronouns, contact) is **global per account**; community custom fields are per-community by definition. Per-community display-name overrides (Discord-style nicknames) are roadmap.
- **Avatar — optional**, with a deterministic generated fallback (initials + stable color) so feeds stay scannable. Roadmap: personalizable generated avatars (font, color, style templates on the deterministic base).
- **Optional base fields**: bio (short), pronouns (with per-user display control), contact info (phone, visible email, other) — each contact field with **user-controlled visibility** (hidden / members / admins-only), **default hidden**.
- **Community-defined custom fields** (text / single-select), e.g. "Instrument", "Section", "Dietary needs", each with admin-set visibility (members / admins-only). Admins may mark fields **required**: required fields **hard-block** at join/onboarding; fields made required _after_ a member joined trigger a persistent nag banner, never a lockout.
- Member directory is filterable by custom fields — the directory _is_ the band roster.
- Timezone and language are auto-detected and editable in settings; never demanded at onboarding. Notification preferences live in settings, not the profile.

## 5. Feed & posts

- Per-group feeds + aggregated home feed **scoped to the active community**, plus the merged cross-community **Home** lens (ADR 0015) spanning everything you belong to. **Strictly chronological + pinned posts. No algorithmic ranking, ever** (product principle and marketing line). Optional user-selectable **activity view** (sorted by latest comment, forum-style bump). New-since-last-visit marker.
- **Content**: Markdown canonical; composer is a friendly rich-text toolbar reading/writing Markdown.
- **Attachments**: images (thumbnailed, lightbox), **polls**, files.
  - Files default into the group file space via a folder picker (default "Feed uploads"); deleting a post never deletes the file.
  - **Transient option**: no file-space home, auto-expiry (default 30 days).
- **Polls**: single/multi choice, optional close date, live results. **Per-poll anonymity toggle, default visible votes**, locked after the first vote.
- **Reactions**: emoji reactions on posts and comments.
- **Comments**: exactly one reply level (comment → replies), chronological, collapse beyond ~3 replies, live-updating. One threading model everywhere — no per-group/per-post threading variants.
- **Mentions**: `@user`, `@admins`, `@everyone` (gated to users with broadcast rights; rate-limited).
- **Announcement toolkit**: pinned posts; **scheduled publishing** (compose now, publish at time T via Oban); **acknowledgment-required posts** — members tap an explicit ✓, author/admins see who has and hasn't acknowledged. (Deliberate and consent-based — no passive "Seen by" tracking.)
- **Editing**: "edited" marker; edit history visible to admins (and the author), not the public.
- **Deletion**: author soft-delete leaves a "removed" stub preserving thread coherence; content purged after 30 days; immediate hard-delete available to admins and via GDPR erasure.
- No DMs/chat in v1 (roadmap).

## 6. Events

- Fields: title, Markdown description, start (+ optional end), **all-day and multi-day supported**, timezone-aware, location (free text + optional URL; map links derived client-side — no embedded trackers), cover image, host group.
- **RSVP** yes/no/maybe for members. **Guest RSVP** on public events: name + email, confirmation email with **ICS attachment** and signed management link. No account required.
- **Recurrence**: weekly / biweekly / monthly series (constrained RRULE; no freeform editor), per-instance overrides (cancel/move one date), **per-instance RSVP**, and an organizer **attendance matrix** (members × upcoming instances).
- **Reminders**: push + email, per-user configurable.
- **ICS feeds**: per group and per user (merged), secret-token URLs.
- Event pages use the same comment engine.
- Roadmap: capacity, waitlists, ticketing (evaluate **Pretix** integration before building), cross-group co-hosting.

## 7. Files

- **Two scopes**: community space and per-group spaces. **Shallow folder tree + search + auto-collections** ("Images", "Posted in feed", "Attached to event X").
- **Permissions — presets only, no per-user ACLs**: baseline inherits owning-scope membership; per-folder overrides: read = `inherit` | `admins_only`; write = `inherit(members)` | `admins_only`; subfolders inherit from parents.
- **Invariant (enforce centrally, test heavily)**: file/folder visibility can never exceed the owning scope's visibility preset.
- **Versioning** (ADR 0017): uploading a file with the same name into the same folder appends a version rather than duplicating; listings show the current version, with a full history (uploader, time, size) browsable and individually downloadable/deletable (never the last version). Retention (versions to keep) is admin-configurable per space, unlimited by default.
- **Storage policy, instance-level**: `unmetered` (default; usage still visible) or `quota` mode (admin sets per-space quotas; members see usage bars; uploads blocked at cap with clear messaging). Per-user contribution stats shown in either mode. Paid storage/billing is roadmap (hosted-offering era), not v1.
- Upload size limit configurable (default 100 MB). FTS over filenames + extracted text (PDF/plaintext, Oban job, graceful skip).
- No video upload v1 (embeds render). No doc editing v1 (roadmap: collaborative Markdown notes → Collabora/OnlyOffice; files are first-class DB entities so a `document` type can slot in).

## 8. Reaching people without accounts (differentiator — build well)

- **RSS/Atom** for every public group feed.
- **Email newsletter subscriptions** to public feeds: double opt-in, per-post or daily/weekly digest, one-click unsubscribe (List-Unsubscribe), signed management links.
- Guest RSVP and approval-queued guest comments — all on the same email/magic-link primitives.

## 9. Notifications

- **Layered: Web Push + email**, plus in-app notification center.
- **Defaults ("highlights")**: push+email for mentions, replies to you, acknowledgment-required posts, event invites/changes/reminders; ordinary posts appear in-app + digest only. **Broadcast (admins-only-posting) groups default to "everything"** — announcement groups should announce.
- Per-user, per-group levels: everything / highlights / mentions-only / muted; digest frequency instant/daily/weekly/off.
- **Content-minimized email mode** (instance toggle): notification emails carry no content, only "N new posts in {group}" + link. Auth/RSVP emails exempt (inherently minimal).

## 10. Search

- Global + per-group search (Postgres FTS + pg_trgm): posts, comments, events, files (names + extracted text), members. All results filtered through the central authorization module.

## 11. Moderation, abuse, security

- Report → admin queues (community-wide and per-group): dismiss, remove, warn, remove/ban member (community ban blocks rejoin by email). Instance operators additionally hold an instance-wide ban list, keyed the same way, that blocks rejoin on every community on the instance rather than one.
- **Rate limits**: magic-link issuance (per email + IP), signup, posting/commenting, guest endpoints, uploads, @everyone.
- **Upload hardening (always on)**: strict content-type validation; images re-encoded (destroys embedded payloads); SVGs sanitized or forced-download; user uploads never served executable/inline from the app origin without `Content-Disposition` protection. **Optional ClamAV sidecar** (config flag; docs honest that AV is signature-based and imperfect).
- Signed expiring tokens for all guest links. CSRF, secure cookies, CSP, sanitized Markdown rendering.
- **Audit log** (admin-visible): role changes, bans, deletions, settings changes, community-admin overrides into groups.

## 12. GDPR & data rights

- Self-serve **export** (JSON + files zip) and **account deletion** (identity erased; authored content anonymized to "Deleted user", clearly explained pre-confirmation).
- Guest records fully erasable via their management links.
- **Shipped, admin-editable legal templates**: privacy policy and imprint/contact page (EU reality); wizard nags until the contact page has a real operator address.

## 13. Instance administration & ops

- **First-run: hybrid env + wizard.** Every setup value settable via env (env always wins; fully declarative deploys); wizard collects the remainder on first boot: instance-operator email (magic link doubles as live SMTP test), **first community** (name/logo/accent color/default language), first group, invite link, and the community-creation policy (operators only / any user). Wizard protected by a setup token printed to server logs; locks permanently on completion. **Optional demo data** (example community with group, posts, poll, event) with one-click purge.
- **Branding**: name, logo, accent color, default language — in settings UI, not only env.
- **Backups built in**: Oban-scheduled pg_dump + file snapshot to local path or S3 target; retention policy; **optional `age` public-key encryption** of archives (documented hard: lose the key, lose the backups); tested restore procedure in `docs/backups.md`.
- **Observability**: structured logs, `/healthz`, optional Prometheus `/metrics` (Telemetry), optional Sentry-compatible (GlitchTip) error reporting.
- **Upgrades**: release check against GitHub shown **in the admin panel only** (toggleable off; no phone-home otherwise); never shown to regular users. Migrations run on boot; LiveView clients pick up new versions on reconnect; assets digest-versioned.
- **Email admin UX**: SMTP settings with "send test email". Docs cover providers (Postmark/Resend) and self-hosted (Stalwart) incl. SPF/DKIM/DMARC.

## 14. Packaging & repo

- **Primary**: `docker-compose.yml` (app + Postgres + optional MinIO + optional ClamAV), `.env.example`, Caddy TLS example, multi-stage Dockerfile → small Elixir release image.
- **Also**: Nix flake as the **canonical dev environment** (dev shell with Elixir/OTP, Node for tooling, Postgres client, libvips, lefthook; plus package + NixOS module). Ship `.envrc` (`use flake`) for **direnv** auto-activation and a **devbox.json** wrapping the same toolset for contributors who don't speak Nix. Every dev task (setup, test, lint, format, run) must work identically inside the flake shell, devbox shell, and CI — document the three entry paths in CONTRIBUTING ("`direnv allow`, or `devbox shell`, or `nix develop` — then `mix setup && mix phx.server`").
- Repo: README that _sells_ (ethos, screenshots, 10-minute quickstart), CONTRIBUTING, LICENSE, CHANGELOG (Keep a Changelog format; semver from 0.1.0), CONVENTIONS.md, CODE_OF_CONDUCT.md (Contributor Covenant), SECURITY.md (disclosure policy), GitHub issue templates (bug/feature) + PR template, `.editorconfig`, `docs/`, `docs/decisions/` (ADRs), seeds, `BUILDLOG.md` (frozen Phase 1 record — later scope trims live in PR descriptions and CHANGELOG.md instead).

## 15. Naming

**The name is Kammer** — settled (owner decision, 2026-07-11; exploration record on issue #209, four rounds of alternatives, none beat the incumbent). Module namespace `Kammer`; the display name stays a single config constant (`Kammer.product_name/0`) so a rename remains one commit. (Origin homage: TÅGEKAMMERET; resonances: kammermusik — small ensembles, no conductor; _kammerat_, etymologically "chamber-mate.") **Any future rename is the owner's call alone** — naming is not reopened by agents. Domains, org naming (#203), and landing-page naming (#188) proceed on Kammer.

## 16. Architecture strategy (standing decisions)

Phase 1 (pilot slice) and the original Phase 2 list (SPEC v1 complete)
are both fully shipped — see CHANGELOG.md/git history for what and
when, open GitHub issues for what's still open. What follows are the
standing architectural decisions that outlive any one build phase:

**Explicit non-goals (design constraints, not a to-do list):**
ActivityPub/federation. Kammer's cross-instance strategy (below) is a
client-side session-holder merging one user's own views across the
instances _they_ are actually a member of, not server-to-server
content distribution to strangers' servers — a community lives on
exactly one instance (§3, the Discord model) and there is no
cross-instance community concept to federate between. See ADR 0023
for the full reasoning: this isn't a lesser version of federation,
it's a better fit for what Kammer actually needs, considered and
rejected deliberately rather than left unexamined.

**V1 scope beyond the web product (owner-set, 2026-07-11; ADR 0028 —
the product is not finished in its first version without these):**
native apps — Kotlin/Android, Swift/iOS, API siblings of the Svelte
client (#131, ADR 0022/0028); the offline write queue — full offline
support beyond the shipped read-only offline reading (#137, ADR
0022/0028); chat/DMs (#136, needs its own design pass); operator
telemetry (#67, owner-set 2026-07-11) — industry-grade **operational**
observability: a Prometheus metrics endpoint (PromEx over the
`:telemetry` events Phoenix/Ecto/Oban/BEAM already emit), spans on
Kammer's own hot paths, a shipped Grafana dashboard and alerting
examples in the deploy docs. Explicitly bounded by the product ethos:
no user-behavior analytics ever, no distributed-tracing ceremony on a
single-node monolith, no hosted-APM dependencies. ADR 0012's
sequencing stands: PWA first, the LiveView cut (#187) before native
work — this sets the finish line, not the order.

**Confirmed post-V1 roadmap (owner-approved scope, not yet designed or
scheduled — each item has its own tracking issue so nothing here gets
silently dropped):** E2EE, shape depends on chat/DMs landing first
(#132); event ticketing/capacity/waitlists (#133); collaborative
document editing (#134); video upload (#135); managed hosting /
Kammer Cloud and its storage billing — **explicitly post-V1** (owner,
2026-07-11) (#22); group type templates — presets such as
"Announcement channel", "Discussion forum", "Standard group" that
bundle posting/comment policies including reply-style options like
deeper forum threading (#138; ADR 0007 already named curated templates
the sanctioned path to configurable comment mechanics, keeping raw
per-group threading switches out of the product — that constraint
still holds, only the "non-goal" framing changes).

**UI architecture strategy:** the **Svelte PWA is the product UI**
(ADR 0024); LiveView was the first-build vehicle and will be removed
from the repo entirely — it cannot do offline mode or multi-instance
session-holding/merging, the two capabilities the product depends
on. The JSON API over the same Phoenix contexts is already shipped
(ADR 0014). The PWA is **instance-served**: the Phoenix release
bundles and serves the built client at the instance's own domain, so
magic links land in the PWA (deep link to `/sign-in/{token}`, plus a
short code in the email for cross-device sign-in; passkeys in client
v1 via API challenge/verify endpoints) and multi-instance merging
works from any deployed copy via CORS (#164). It is **built
multi-instance-capable from day one** (holds sessions on N
instances, merges views client-side; foreign items resolve naturally
since the client is a session-holder, not a proxy), with
community-first IA (§21) and Phoenix Channels realtime
(device-token socket auth) from the client foundation onward.
Sequencing: **freeze + parity ladder** — LiveView is feature-frozen
(bugfixes only) while the PWA climbs surface-by-surface; each
surface ships with full write parity, including the API endpoints it
is missing; guest surfaces (guest RSVP/comment/claim links,
newsletter unsubscribe, legal pages, setup wizard) move onto new
public API endpoints as their turn comes, while RSS/iCal stay plain
HTTP feeds; LiveView is removed in one cut at full
member+admin+guest coverage (#165 is the transition umbrella). This
client-side model replaces any server-side "home instance"
aggregation scheme; no inter-instance sync protocol is required.
Native apps come strictly after PWA parity, generated from the same
OpenAPI document (#131, ADR 0022). Note: ICS and RSS already provide
standards-based cross-instance merging.

**Identity strategy:** email + synced passkeys is the identity layer
for v1–v2 (email is the existing federated identifier; the
multi-instance client supplies the felt "one identity"). v3 candidate:
**instance-as-OIDC-provider** ("sign in with your home instance") for
true single-account linking across instances. **AT Protocol / DIDs:
explicit watchlist item** — re-evaluate adoption maturity at each
major release; do not build on it yet.

**Scope-trim transparency:** a PR may trim scope to ship something
coherent, but every trim, stub, or deferral must be stated in the PR
description and, if it outlives that PR, as a GitHub issue. Silent
stubs are forbidden.

## 17. Engineering standards (non-negotiable; wire into the first commit)

- `mix format` enforced in CI; **Credo strict mode** (naming, complexity, single-letter-variable ban, doc requirements); **Dialyzer** (dialyxir) with `@spec` on every public function; `@moduledoc`/`@doc` mandatory; compile with warnings-as-errors.
- Naming: full, descriptive, unabbreviated identifiers throughout — schemas, functions, variables, assigns.
- **One authorization module**: every permission/visibility rule flows through it; no inline checks in templates. The file-visibility invariant and sealed-group rules get dedicated test suites (property-based where practical).
- Git: **lefthook** hooks auto-installed via mix task (commit: format, credo, compile; push: tests); **Conventional Commits** + commitlint.
- CI (GitHub Actions): format check, Credo, Dialyzer, tests with coverage floor, `mix hex.audit` + `mix deps.audit`, **Sobelow** (Phoenix security static analysis).
- Tests: context-level unit tests (permissions above all), LiveView tests for critical flows (auth, posting, RSVP, invite redemption), doctests where they add value.
- CONVENTIONS.md documents all of the above for contributors.

## 18. Documentation (a deliverable)

- **Diátaxis structure, reader-first pragmatism** (deviate from the framework whenever reader value says so): Tutorial ("zero to invited community in 10 minutes"), How-tos (backup/restore, email incl. self-hosted, reverse proxy, upgrades, quotas), Reference (config, permissions model, storage policy), Explanation (architecture, the visibility invariant, why LiveView, threat model incl. what "sealed" does and doesn't guarantee).
- **Tooling**: Astro **Starlight** docs site (i18n-ready EN/DA, deployed via GitHub Pages) + **ExDoc** for API reference generated from module docs.
- **ADRs**: minimal records (context → decision → consequences, ≤1 page) in `docs/decisions/`, one per decision a contributor would relitigate — architecture, not routine feature work.
- README sells the product: ethos up top, screenshots, quickstart, honest limitations section.
- Product/marketing site: separate static site, milestone after pilot and before public launch (not part of this build).

## 19. Media handling defaults

- **Strip EXIF metadata on upload** (GPS, serials; preserve orientation via re-encode).
- **Convert HEIC/HEIF to web formats** (WebP/JPEG) — iPhone uploads must render everywhere.
- Thumbnail pipeline via libvips; responsive sizes; lazy loading.

## 20. Quality bar

- Feed interactions feel instant on a mid-range phone; Lighthouse PWA installability passes.
- Danish and English complete for all shipped surfaces, including emails.
- No analytics, no tracking, no phone-home except the admin-toggleable release check.
- Every guest-facing link is signed and expiring; every list the user sees respects the authorization module.

## 21. Design brief — Warm Scandinavian Minimal

- **Surfaces**: paper-white/off-white backgrounds (not pure #fff), near-black ink (not pure #000), warm neutral grays. Dark mode as a first-class twin, not an inversion afterthought.
- **Accent**: exactly one accent color — the active community's configured accent. Branding is structural: switching communities re-tints the interface. Ensure computed contrast safety for any admin-chosen accent (derive tints/shades; enforce WCAG AA).
- **Type**: Inter (variable) or system stack; generous line-height; restrained scale (4–5 sizes total). No decorative display fonts.
- **Form**: whitespace over dividers; hairline borders over shadows; small consistent radii; no glassmorphism, no gradients, no visual noise. Motion minimal and purposeful — subtle transitions that respect `prefers-reduced-motion` (a client v1 requirement, ADR 0024).
- **Density**: comfortable on mobile, denser on desktop. Feed cards quiet; content is the interface.
- **Navigation**: mobile bottom tab bar — **Home · Events · Groups · Notifications · You** — stable within the active community; **community switcher** as an avatar-stack control in the top bar. Files, members, and settings live inside each group/community, not top-level. Desktop: left sidebar (communities + groups), same IA. (For the product client this is the starting IA, not a fixed constraint — the owner delegated IA evolution to the client design as long as the community-first principle below holds; ADR 0024.)
- **Community-first IA** (ADR 0024): users shouldn't have to care about instances as an abstraction. Merged cross-community views and per-community views are both effortless to reach, and where provenance matters it is shown as the community, never the server it happens to live on.
- The overall impression to aim for: calm, honest, durable — closer to a well-set book or an FDB catalogue than to a social app.

## 22. Prescribed dependencies (verify current versions before use; do not substitute without a CHANGELOG/PR note explaining why)

- Phoenix (latest stable) + Phoenix LiveView + Ecto/postgrex.
- **Oban** — background jobs. **Swoosh** — email. **Gettext** — i18n.
- **Wax** — WebAuthn/passkeys. **web push**: use the currently maintained Elixir web-push library (verify on Hex; implement VAPID payload encryption per RFC 8291 if library support is thin).
- **Vix (libvips)** — image processing (thumbnails, EXIF strip, HEIC→WebP/JPEG).
- **Earmark or MDEx** — Markdown rendering (sanitized output; verify current best choice).
- **Hammer** (or equivalent) — rate limiting.
- **icalendar** library for ICS generation (verify maintenance status; ICS is simple enough to generate directly if libraries are stale).
- Tailwind via Phoenix's standard esbuild/tailwind pipeline; **no** custom npm build chain in the application's runtime or asset build. (npm is permitted for dev tooling — commitlint — and the separate Starlight docs site.)
- Dev/quality: Credo, Dialyxir, Sobelow, ExCoveralls (coverage), lefthook, commitlint.
- Rule: prefer boring, maintained, well-documented libraries; when a needed library is stale or missing, implement the minimal internal version rather than adopting an abandoned dependency, and say why in the PR.

## 23. Collaborative tools (per-group, opt-in — issue #17)

Kammer serves two paths on the same group primitive: the **public
community face** (open groups, public events) and **private
collaboration** (Basecamp territory, but self-hostable and honest,
with sealed groups). Each tool below is its own feature toggle (§3),
off by default, sharing the existing comment/reaction/RSVP-style
primitives rather than inventing new ones.

- **Signup slots** on events: capacity-bounded slots ("bring cake ×2,
  drive ×4"); members and guests both claim (guests via the same
  email-confirm flow as guest RSVP), never overbooked (row-locked).
- **Availability polls** ("date finding"): candidate dates, members
  answer yes/if-needed/no on a shared grid; closing the poll converts
  the winning date into a real event with one click.
- **Assignments**: a flat open/claimed/done task list, never a board —
  volunteer orgs run on lists, not sprints. Multiple people can claim
  the same assignment; anyone can mark it done (the record shows who);
  each assignment carries a discussion thread through the same comment
  engine as posts.
- **Decisions register**: raise a motion (lands in the feed as a post
  with a For/Against/Abstain vote), then record the outcome (adopted,
  rejected, noted, with a note for the record). The register lists
  every motion and outcome chronologically — minutes-grade
  institutional memory, built for board groups.
- **Rotations** (not yet built): recurring duty rosters (coffee duty
  auto-rotates; you're notified when it's your week).
