# GitHub repository configuration

Everything that *can* live in the repository does (workflows,
`renovate.json`, `CODEOWNERS`, the ruleset JSON below). A few switches
only exist in the GitHub UI and must be flipped once by an admin — they
are listed here so nothing is forgotten. All of them work from a mobile
browser (request the desktop site if a page looks cramped).

## 1. Branch protection (import, don't click)

Settings → Rules → Rulesets → **New ruleset → Import a ruleset** →
upload [`rulesets/main-protection.json`](rulesets/main-protection.json).

What it enforces on the default branch:

- **Pull requests only** — no direct pushes; review threads must be
  resolved; **merge commits only** (owner decision: an honest,
  unrewritten history — no squash, no rebase).
- **Required checks before merge**: `Conventional Commits`,
  `Format, Credo, Sobelow, audit, Dialyzer, tests`, and `Docker image`,
  each up to date with the base branch (strict mode).
- **No force pushes, no deletion.**
- Required approvals is set to **0** deliberately: this is currently a
  single-maintainer project and requiring 1 approval would deadlock
  merges (you cannot approve your own PR). Raise it to 1 the moment a
  second maintainer exists.

## 2. Renovate (dependency updates)

Install the Mend-hosted Renovate GitHub App — no PAT, no secrets:

1. Open <https://github.com/apps/renovate> and tap **Install**.
2. Choose "Only select repositories" → `tskovlund/kammer`.

`renovate.json` in the repo root does the rest: weekly Monday-morning
runs, grouped GitHub Actions and commitlint updates, Conventional-Commit
messages, auto-merge for non-major updates once required checks pass
(via GitHub auto-merge, so the ruleset gates it), majors left open for a
human. Security updates jump the weekly schedule.

If you ever prefer a self-hosted runner instead of the app: create a
fine-grained PAT (contents: read/write, pull requests: read/write,
workflows: read/write on this repo), store it as the `RENOVATE_TOKEN`
secret, and add a scheduled workflow running `renovatebot/github-action`
— but the hosted app is less to maintain.

## 3. One-time settings (Settings → General)

- Merge buttons: allow **merge commits only** — disable squash and
  rebase (matches the ruleset and the honest-history policy).
- **Allow auto-merge**: on — Renovate's auto-merge relies on it.
- **Automatically delete head branches**: on.

## 4. Code security (Settings → Advanced Security)

Enable everything that is free for the repository's visibility:

- **Dependency graph** — required by the dependency-review check (it
  currently fails on PRs precisely because this is off).
- **Dependabot alerts**: on — Renovate reads them for security updates.
  Leave **Dependabot security updates** (the auto-PR half) off to avoid
  duplicate PRs next to Renovate; version updates come from Renovate
  (`.github/dependabot.yml` has been removed).
- **Secret scanning** + **push protection** (free on public repos; the
  Gitleaks workflow covers the gap if the repo is private).
- **Private vulnerability reporting**: on — SECURITY.md points
  researchers at it.
- **Code scanning**: the CodeQL workflow uploads results automatically
  (public repos; private repos need GitHub Advanced Security).

## 5. Actions hygiene (Settings → Actions → General)

- Workflow permissions: **Read repository contents** (workflows that
  need more declare it per-job; keep the default minimal).
- Allow GitHub Actions to create and approve pull requests: **off**
  (nothing here needs it; the Renovate app is not affected).

## Choices made autonomously (and why)

- **Merge commits only** — owner decision (honest history over a
  rewritten one). The earlier linear-history requirement was dropped
  because merge commits and linear history are mutually exclusive.
- **Renovate via the hosted app** rather than self-hosted Actions —
  zero secrets to manage; the config file is identical either way.
- **Auto-merge only for non-major updates**, and only after all
  required checks pass. Majors wait for a human.
- **CodeQL scans JavaScript and the workflows themselves** — CodeQL has
  no Elixir support; Elixir-side scanning is Sobelow + `mix deps.audit`
  + `mix hex.audit` in CI on every PR.
- **Gitleaks workflow in addition to GitHub secret scanning** so secret
  detection also runs on private forks/mirrors and full history.
- **OpenSSF Scorecard not added**: it hard-fails on private
  repositories; add `ossf/scorecard-action` once the repo is public.
