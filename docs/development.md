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
5. **Architecture-shaping decisions** get a one-page ADR in
   [`docs/decisions/`](decisions/); scope trims and deferrals go to
   [BUILDLOG.md](../BUILDLOG.md). Silent stubs are forbidden.
6. **Docs move with the change**: if a PR alters behavior described in
   README, this directory, or `.env.example`, the same PR updates it
   (the PR template asks).

## What runs automatically

| When            | What                                                                                                                   |
| --------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Every PR        | Quality gate, smoke test (below), Prettier, commitlint, Docker build + boot check, CodeQL, dependency review, Gitleaks |
| Merge to `main` | Docker image → `ghcr.io/tskovlund/kammer:main`; mix.lock → dependency graph                                            |
| Tag `vX.Y.Z`    | GitHub Release + versioned image ([release.md](release.md))                                                            |
| Monday 07:00    | Renovate: grouped dependency PRs, non-majors automerge                                                                 |

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
