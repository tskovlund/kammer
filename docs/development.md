# Developing Kammer

The practical companion to [CONTRIBUTING.md](../CONTRIBUTING.md) (which
covers setup) and [CONVENTIONS.md](../CONVENTIONS.md) (which covers
standards). This page is the workflow reference: what you run, when,
and what the automation does around you.

## Environment

One toolchain, defined in `flake.nix`, three doors in — all identical,
and CI runs inside the same shell:

```sh
direnv allow      # auto-activating, or:
devbox shell      # no Nix knowledge needed, or:
nix develop       # plain Nix
```

Then `mix setup` (deps, database, assets, git hooks) and
`mix phx.server` → <http://localhost:4000>. First boot prints the setup
token for the `/setup` wizard.

## Everyday commands

| Task                       | Command                               |
| -------------------------- | ------------------------------------- |
| Run the app                | `mix phx.server`                      |
| Fast tests                 | `mix test`                            |
| Full quality gate          | `mix precommit` (or `make check`)     |
| Lint only                  | `mix lint`                            |
| Format everything          | `make format` (mix format + prettier) |
| Regenerate screenshots     | `scripts/screenshots.sh`              |
| Extract/merge translations | `mix gettext.extract --merge`         |

The gate = format check, Credo strict, compile with
warnings-as-errors, Sobelow, dependency audits, Dialyzer, tests with
the coverage tripwire. Git hooks (installed by `mix setup`) run the
cheap parts at commit and the full suite at push, so a red CI should
never surprise you.

## Change workflow

1. Branch from `main`. Small or large, every change lands via PR —
   `main` only moves through merges with required checks green
   (Conventional Commits, the quality gate, the Docker image build).
2. Commit messages follow [Conventional Commits](https://www.conventionalcommits.org)
   (commitlint enforces; types in CONVENTIONS.md). Merge commits are
   the default; squash is allowed when the branch history is noise.
3. **User-facing strings** go through Gettext with English _and_
   Danish filled in (`mix gettext.extract --merge`, then edit
   `priv/gettext/*/LC_MESSAGES/default.po`).
4. **Permission or visibility changes** happen in
   `lib/kammer/authorization.ex` only, with context-level tests —
   property-based (StreamData) when an invariant is involved.
5. **What's left to build lives as GitHub issues**, not a backlog doc —
   not a feature log (that's the CHANGELOG) and not the product spec
   (that's [SPEC.md](../SPEC.md), kept current in place). Engineering
   process lives in [CONVENTIONS.md](../CONVENTIONS.md) and
   [CONTRIBUTING.md](../CONTRIBUTING.md); this page is the "what you
   run, when" reference.
6. **Architecture-shaping decisions** get a one-page ADR in
   [`docs/decisions/`](decisions/); designs still awaiting an owner
   decision live as RFCs in [`docs/rfcs/`](rfcs/). Scope trims and
   deferrals go in the PR description and, if they outlive it, into a
   GitHub issue — never silent stubs.
7. **Docs move with the change**: if a PR alters behavior described in
   README, this directory, or `.env.example`, the same PR updates it
   (the PR template asks).

## Common pitfalls

The ones that cost real time — check here before you burn an hour on
the same one:

- **LiveView forms must be fully driven by `to_form`** — any field not
  round-tripped through the change event resets on re-render.
- **`phx-value-*` attributes are not merged** into a native
  `change`/`submit` event's payload for bare `<input>`/`<select>`
  elements (only for click-type events, and for elements inside an
  actual `<form>`). A per-field control that needs to identify itself
  needs a real `<form>` wrapper with a hidden input, not a bare
  element with `phx-value-*`.
- **Route order matters**: literal segments (`/events/new`) must be
  defined before wildcards (`/events/:event_id`) across `live_session`s.
- **Swoosh test assertions pop the _next_ mailbox message** — drain
  fixture-generated emails first (`drain_delivered_emails` helper,
  used throughout the test suite).
- **The ETS rate limiter is global across async tests and never
  resets between them** — so isolate by _keyspace_, on every
  dimension a limiter keys on, never by loosening the limit. For the
  email dimension, give each test a unique address
  (`System.unique_integer/1`). For the per-IP dimension, set a
  distinct `conn.remote_ip` from a documentation range (RFC 5737
  TEST-NET blocks — `203.0.113.0/24`, `198.51.100.0/24`,
  `192.0.2.0/24`; grep the suite for ones already pinned so you don't
  collide) rather than sharing the default `127.0.0.1`, which every
  guest/signup/magic-link test otherwise piles onto until one
  spuriously 429s. Resetting the shared table isn't an option under
  async; partitioning the keys is. And never reach for a production
  config knob to raise a limit in the test env — a security limit
  behind a runtime-reachable setting is a footgun, and the isolation
  belongs in the test layer regardless.

## What runs automatically

| When            | What                                                                                                                   |
| --------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Every PR        | Quality gate, smoke test (below), Prettier, commitlint, Docker build + boot check, CodeQL, dependency review, Gitleaks |
| Merge to `main` | Docker image → `ghcr.io/tskovlund/kammer:main`; mix.lock → dependency graph                                            |
| Tag `vX.Y.Z`    | GitHub Release + versioned image ([release.md](release.md))                                                            |
| Monday 07:00    | Renovate: grouped dependency PRs, non-majors automerge                                                                 |

## The web client (Svelte PWA)

The product UI (ADR 0024) lives in `clients/web` with its own
toolchain (node/pnpm — versions pinned in `package.json`). In
development it is **not** served by Phoenix; run it as its own dev
server next to the Elixir one:

```sh
mix phx.server                 # the API, on localhost:4000
cd clients/web && pnpm dev     # the client, on localhost:5173/app
```

Point the client at `http://localhost:4000` as its instance. The
`/app` prefix is baked into the client (`paths.base` in
`vite.config.ts`) and must match `:pwa_base_path` in
`config/config.exs` — both flip to `/` at the LiveView removal cut
(#187).

In releases the client **is** served by Phoenix: the Dockerfile's
client stage runs `pnpm build` and ships the output into the release
at `priv/static/app`, which the endpoint serves under `/app` with an
`index.html` fallback so client routes (e.g. `/app/sign-in/{token}`
from a magic-link email) deep-link straight into the SPA. A dev
server without a built bundle answers `/app` with a plain-text
pointer to this section instead of a 500.

## The API contract

`GET /api/v1/openapi.json` serves the OpenAPI 3 document, generated
from the same modules that shape responses. Clients generate from it
(TypeScript now; Swift/Kotlin when native starts) — never hand-write
an API client. A drift test pins the document to the router: adding an
API route without describing it fails CI.

## Smoke test & screenshots

`scripts/screenshots.sh` resets the dev database, boots the server,
and drives the real product flows in headless Chromium — first-run
wizard, invite-link signups for a four-member community, posts,
reactions, a poll, an acknowledgment post, an event with RSVPs, file
uploads, a sealed group — then captures the shots the README embeds.
Nothing is seeded behind the scenes.

The same script runs in CI as the **Smoke test** check on every PR: if
a flow breaks end to end, the PR goes red, and the captured screenshots
are attached to the run as artifacts so reviewers can eyeball the UI
without checking out the branch. The Docker workflow additionally boots
the freshly built image against Postgres and requires `/healthz` to
answer — proof the shipped artifact starts and migrates.

Committed screenshots in `docs/screenshots/` are deliberately **not**
auto-updated by CI: pixels are nondeterministic run to run, and binary
churn on every merge would bloat history for nothing. Regenerate
whenever a PR changes the UI visibly and commit the diff — reviewers
then see visual changes in the PR like any other change. Two ways to
regenerate: run `scripts/screenshots.sh` locally, or dispatch the
**Screenshots** workflow on the PR branch (Actions → Screenshots →
Run workflow) — it runs the same script and commits the diff back to
the branch. Same deliberate act, works from a phone.

**Deferred pre-v1 (owner-stated, 2026-07-12):** in practice the
per-PR regeneration above is on hold — screenshots get a single batch
refresh before v1, so don't regenerate per PR right now; note UI
changes in the PR and let that batch cover them, and don't block a
merge on stale screenshots. (See AGENTS.md's remote-container notes;
the agent container can't build CSS locally anyway.)
