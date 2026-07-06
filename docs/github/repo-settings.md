# GitHub repository configuration

Everything that *can* live in the repository does (workflows,
`dependabot.yml`, `CODEOWNERS`, the ruleset JSON below). A few switches
only exist in the GitHub UI/API and must be flipped once by an admin —
they are listed here so nothing is forgotten.

## 1. Branch protection (import, don't click)

Settings → Rules → Rulesets → **New ruleset → Import a ruleset** →
upload [`rulesets/main-protection.json`](rulesets/main-protection.json).

What it enforces on `main`:

- **Pull requests only** — no direct pushes, review threads must be
  resolved, squash or rebase merges (keeps Conventional Commits usable
  for changelogs).
- **Required checks before merge**: `Conventional Commits`,
  `Format, Credo, Sobelow, audit, Dialyzer, tests`, and `Docker image`,
  each up to date with `main` (strict mode).
- **No force pushes, no deletion, linear history.**
- Required approvals is set to **0** deliberately: this is currently a
  single-maintainer project and requiring 1 approval would deadlock
  merges (you cannot approve your own PR). Raise it to 1 the moment a
  second maintainer exists.

## 2. One-time settings (Settings → General)

- **Allow auto-merge**: on — the Dependabot auto-merge workflow relies
  on it.
- **Automatically delete head branches**: on.
- Merge buttons: allow **squash** and **rebase**, disable merge commits
  (matches the ruleset's allowed methods).

## 3. Code security (Settings → Advanced Security)

Enable everything that is free for the repository's visibility:

- **Dependency graph** (default on for public repos) — required by the
  dependency-review workflow.
- **Dependabot alerts** and **Dependabot security updates** (the
  version updates half is already configured in `.github/dependabot.yml`).
- **Secret scanning** + **push protection** (free on public repos; the
  Gitleaks workflow covers the gap if the repo is private).
- **Private vulnerability reporting**: on — SECURITY.md points
  researchers at it.
- **Code scanning**: the CodeQL workflow uploads results automatically
  (public repos; private repos need GitHub Advanced Security).

## 4. Actions hygiene (Settings → Actions → General)

- Workflow permissions: **Read repository contents** (workflows that
  need more declare it per-job; keep the default minimal).
- Allow GitHub Actions to create and approve pull requests: **off**
  (nothing here needs it; Dependabot is not affected).

## Choices made autonomously (and why)

- **Dependabot instead of Renovate.** Renovate needs either the hosted
  GitHub App (an installation only an admin can do) or a self-hosted
  runner workflow with a PAT secret (which cannot be created from a
  code contribution). Dependabot activates purely from a committed
  file. If you later prefer Renovate, install the app and delete
  `.github/dependabot.yml`.
- **Auto-merge only for non-major Dependabot updates**, and only after
  all required checks pass. Majors wait for a human.
- **CodeQL scans JavaScript and the workflows themselves** — CodeQL has
  no Elixir support; Elixir-side scanning is Sobelow + `mix deps.audit`
  + `mix hex.audit` in CI on every PR.
- **Gitleaks workflow in addition to GitHub secret scanning** so secret
  detection also runs on private forks/mirrors and full history.
- **OpenSSF Scorecard not added**: it hard-fails on private
  repositories; add `ossf/scorecard-action` once the repo is public.
