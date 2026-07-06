# Build Prompt: Self-Hosted Community Platform (v1, spec revision 2)

You are building a production-quality, self-hostable, open-source community platform — a replacement for Facebook Groups/Pages/Events, group email threads, and the file-sharing half of Google Drive, for real-world communities (associations, bands, clubs). Founding use case: TÅGEKAMMERET, a Danish student association, and its 70-year anniversary revy band.

Design ethos: privacy-first, no ads, no algorithmic manipulation, frictionless participation for non-members, honest about limitations, a joy to self-host. This is also a portfolio-grade codebase: engineering standards (§17) and documentation (§18) are deliverables, not afterthoughts.

---

## 1. Stack (fixed decisions — do not substitute)

- **Backend/UI**: Elixir + Phoenix (latest stable) + **Phoenix LiveView** as the v1 UI layer. Domain logic in Phoenix contexts — this is non-negotiable, because the decided long-term strategy (§16) adds a JSON API in v2 and migrates the UI to a multi-instance Svelte client; the contexts are the permanent asset, LiveView is the v1 vehicle.
- **Database**: PostgreSQL via Ecto. UUID primary keys everywhere. Timestamps stored UTC; rendered in the user's timezone.
- **Styling**: Tailwind CSS. Clean, warm, modern, mobile-first (most users are on phones). Designed empty/loading/error states — the app must feel finished, not scaffolded.
- **PWA**: manifest, service worker (app-shell caching only; content online-only), installable on iOS/Android. **Web Push** via VAPID.
- **Real-time**: LiveView sockets + Phoenix PubSub (live feeds, comments, RSVP counts).
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

### Invitations
- Invite links with optional expiry and max-use count, revocable, per group and community. Admin email invites supported.

## 4. Profiles & member directory

- **Display name — the only required base field.** Free-form. **Per-community names policy toggle**: a community may require full/real names (policy statement shown when joining that community; not technically verified).
- **Profile scope**: the base profile (display name, avatar, bio, pronouns, contact) is **global per account**; community custom fields are per-community by definition. Per-community display-name overrides (Discord-style nicknames) are roadmap.
- **Avatar — optional**, with a deterministic generated fallback (initials + stable color) so feeds stay scannable. Roadmap: personalizable generated avatars (font, color, style templates on the deterministic base).
- **Optional base fields**: bio (short), pronouns (with per-user display control), contact info (phone, visible email, other) — each contact field with **user-controlled visibility** (hidden / members / admins-only), **default hidden**.
- **Community-defined custom fields** (text / single-select), e.g. "Instrument", "Section", "Dietary needs", each with admin-set visibility (members / admins-only). Admins may mark fields **required**: required fields **hard-block** at join/onboarding; fields made required *after* a member joined trigger a persistent nag banner, never a lockout.
- Member directory is filterable by custom fields — the directory *is* the band roster.
- Timezone and language are auto-detected and editable in settings; never demanded at onboarding. Notification preferences live in settings, not the profile.

## 5. Feed & posts

- Per-group feeds + aggregated home feed **scoped to the active community** (cross-community merging is roadmap, delivered properly by the v2 client). **Strictly chronological + pinned posts. No algorithmic ranking, ever** (product principle and marketing line). Optional user-selectable **activity view** (sorted by latest comment, forum-style bump). New-since-last-visit marker.
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

- Report → admin queues (community-wide and per-group): dismiss, remove, warn, remove/ban member (community ban blocks rejoin by email).
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
- **Backups built in**: Oban-scheduled pg_dump + file snapshot to local path or S3 target; retention policy; **optional `age` public-key encryption** of archives (documented hard: lose the key, lose the backups); tested restore procedure in `RESTORE.md`.
- **Observability**: structured logs, `/healthz`, optional Prometheus `/metrics` (Telemetry), optional Sentry-compatible (GlitchTip) error reporting.
- **Upgrades**: release check against GitHub shown **in the admin panel only** (toggleable off; no phone-home otherwise); never shown to regular users. Migrations run on boot; LiveView clients pick up new versions on reconnect; assets digest-versioned.
- **Email admin UX**: SMTP settings with "send test email". Docs cover providers (Postmark/Resend) and self-hosted (Stalwart) incl. SPF/DKIM/DMARC.

## 14. Packaging & repo

- **Primary**: `docker-compose.yml` (app + Postgres + optional MinIO + optional ClamAV), `.env.example`, Caddy TLS example, multi-stage Dockerfile → small Elixir release image.
- **Also**: Nix flake as the **canonical dev environment** (dev shell with Elixir/OTP, Node for tooling, Postgres client, libvips, lefthook; plus package + NixOS module). Ship `.envrc` (`use flake`) for **direnv** auto-activation and a **devbox.json** wrapping the same toolset for contributors who don't speak Nix. Every dev task (setup, test, lint, format, run) must work identically inside the flake shell, devbox shell, and CI — document the three entry paths in CONTRIBUTING ("`direnv allow`, or `devbox shell`, or `nix develop` — then `mix setup && mix phx.server`").
- Repo: README that *sells* (ethos, screenshots, 10-minute quickstart), CONTRIBUTING, LICENSE, CHANGELOG (Keep a Changelog format; semver from 0.1.0), CONVENTIONS.md, CODE_OF_CONDUCT.md (Contributor Covenant), SECURITY.md (disclosure policy), GitHub issue templates (bug/feature) + PR template, `.editorconfig`, `docs/`, `docs/decisions/` (ADRs), seeds, `BUILDLOG.md` (see §16).

## 15. Naming

**Working title: Kammer** — scaffold under module namespace `Kammer`; keep the display name a single config constant so renaming is one commit. (Origin homage: TÅGEKAMMERET; resonances: kammermusik — small ensembles, no conductor; *kammerat*, etymologically "chamber-mate.") Final name pending owner verification (domains, GitHub, Hex, existing products, trademark skim). Shortlist: Kammer, Kammerat, Stemme, Grapevine, Ekko; alternates: Knyt, Felles, Langbord, Torvet, Havn, Tutti, Husting.

## 16. Build order — pilot slice first

**Phase 1 — Pilot slice (fully working; target of the initial build):**
1. Scaffold, dev environment (Nix flake + `.envrc` for direnv + devbox.json — see §14), Docker/compose, CI, env config, Postgres, mailer, gettext (EN+DA), engineering-standards tooling (§17) wired from the first commit.
2. Magic-link auth, sessions, devices. (Passkeys may sit behind a feature flag, completed in Phase 2.)
3. Communities (multi-tenant) + community switcher + groups: four visibility presets, join/posting/comment policies, roles, invite links, post-as-group, sealed flag, archive state. Cross-instance bookmark list.
4. Feed: Markdown posts, images (thumbnails, EXIF strip, HEIC conversion), polls (with anonymity toggle), file attachments incl. transient, reactions, comments (one reply level, collapse, per-post lock), mentions, pins, scheduled posts, acknowledgment posts, edited-marker + admin history, soft-delete stubs, live updates.
5. Events: single events, all-day/multi-day, RSVP, comments, email reminders, ICS attachment + group/user ICS feeds.
6. Files: both scopes, tree, permission presets + central visibility invariant, uploads with hardening, auto-collections, storage-policy modes.
7. Notifications: in-app center, email, Web Push, "highlights" defaults with broadcast-group escalation.
8. Hybrid first-run setup + demo data. Legal page templates.

**Phase 2 — v1 complete:** passkeys; recurrence + attendance matrix; guest RSVP; RSS/Atom; newsletter subscriptions + digests; content-minimized email mode; global search incl. file text extraction; moderation queues + bans + full rate limiting; GDPR export/erasure; backups (+ age encryption); Prometheus; branding UI; audit log; admin update notice; custom profile fields + roster directory; activity-sort feed view; ClamAV option; Nix flake + NixOS module.

**Explicit v1 non-goals (design constraints only):** chat/DMs, E2EE, ticketing/capacity/waitlists, native apps, ActivityPub, document editing, video upload, offline support, storage billing, **group type templates** (presets such as "Announcement channel", "Discussion forum", "Standard group" that bundle posting/comment policies and — explicitly — reply-style options like deeper forum threading; template presets are the sanctioned future path to configurable comment mechanics, keeping raw per-group threading switches out of the product).

**UI architecture strategy (decided):** LiveView is the v1 *vehicle*, not the end state. v2 = JSON API over the same Phoenix contexts, then a **Svelte PWA as the primary client — built multi-instance-capable from day one** (holds sessions on N instances, merges views client-side: merged calendar first, merged feed second; foreign items resolve naturally since the client is a session-holder, not a proxy). LiveView is then frozen and retired — no permanent dual-UI maintenance. This client-side model replaces any server-side "home instance" aggregation scheme; no inter-instance sync protocol is required. Native apps become API siblings of the Svelte client. Note: ICS and RSS already provide standards-based cross-instance merging in v1.

**Identity strategy (decided):** email + synced passkeys is the identity layer for v1–v2 (email is the existing federated identifier; the multi-instance client supplies the felt "one identity"). v3 candidate: **instance-as-OIDC-provider** ("sign in with your home instance") for true single-account linking across instances. **AT Protocol / DIDs: explicit watchlist item** — re-evaluate adoption maturity at each major release; do not build on it yet.

**One-shot build rule:** the builder may self-trim scope to guarantee a coherent, running, deployable product — but every trim, stub, or deferral MUST be documented in `BUILDLOG.md` (what was cut, why, and how to complete it). Silent stubs are forbidden.

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
- **ADRs**: ~12 minimal records (context → decision → consequences, ≤1 page) in `docs/decisions/`, covering only decisions a contributor would relitigate: LiveView-for-v1-Svelte-on-API-for-v2, AGPL, magic-link identity primitive, four visibility presets, sealed groups, no-algorithmic-feed, one-comment-model, storage scoping, presets-not-ACLs, hybrid first-run, email privacy mode, PWA-before-native.
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
- **Form**: whitespace over dividers; hairline borders over shadows; small consistent radii; no glassmorphism, no gradients, no visual noise. Motion minimal and purposeful (LiveView transitions subtle).
- **Density**: comfortable on mobile, denser on desktop. Feed cards quiet; content is the interface.
- **Navigation**: mobile bottom tab bar — **Home · Events · Groups · Notifications · You** — stable within the active community; **community switcher** as an avatar-stack control in the top bar. Files, members, and settings live inside each group/community, not top-level. Desktop: left sidebar (communities + groups), same IA.
- The overall impression to aim for: calm, honest, durable — closer to a well-set book or an FDB catalogue than to a social app.

## 22. Prescribed dependencies (verify current versions before use; do not substitute without BUILDLOG justification)

- Phoenix (latest stable) + Phoenix LiveView + Ecto/postgrex.
- **Oban** — background jobs. **Swoosh** — email. **Gettext** — i18n.
- **Wax** — WebAuthn/passkeys. **web push**: use the currently maintained Elixir web-push library (verify on Hex; implement VAPID payload encryption per RFC 8291 if library support is thin, and note the choice in BUILDLOG).
- **Vix (libvips)** — image processing (thumbnails, EXIF strip, HEIC→WebP/JPEG).
- **Earmark or MDEx** — Markdown rendering (sanitized output; verify current best choice).
- **Hammer** (or equivalent) — rate limiting.
- **icalendar** library for ICS generation (verify maintenance status; ICS is simple enough to generate directly if libraries are stale).
- Tailwind via Phoenix's standard esbuild/tailwind pipeline; **no** custom npm build chain in the application's runtime or asset build. (npm is permitted for dev tooling — commitlint — and the separate Starlight docs site.)
- Dev/quality: Credo, Dialyxir, Sobelow, ExCoveralls (coverage), lefthook, commitlint.
- Rule: prefer boring, maintained, well-documented libraries; when a needed library is stale or missing, implement the minimal internal version rather than adopting an abandoned dependency, and document it in BUILDLOG.md.
