# GitHub repository configuration

A record of how this repository is configured and why — for disaster
recovery and future maintainers, not a to-do list (the initial setup is
complete). Everything that _can_ live in the repository does (workflows,
`renovate.json`, `CODEOWNERS`, the ruleset JSON below); the settings
below only exist in the GitHub UI, so they are documented here.

## 1. Branch protection

The active ruleset is kept as importable JSON:
[`rulesets/main-protection.json`](rulesets/main-protection.json)
(Settings → Rules → Rulesets → Import a ruleset, should it ever need
recreating — also the procedure when the JSON changes, e.g. a new
required check: delete the old ruleset and re-import). It enforces on
the default branch:

- **Pull requests only** — no direct pushes; review threads must be
  resolved; **merge commits by default, squash allowed** (owner
  decision: honest history first, squash "can be okay sometimes";
  rebase stays off).
- **Required checks before merge**: `Conventional Commits`,
  `Format, Credo, Sobelow, audit, Dialyzer, tests`, `Docker image`, and
  `Smoke test` (the end-to-end driven flow), each up to date with the
  base branch (strict mode).
- **No force pushes, no deletion.**
- Required approvals is set to **0** deliberately: this is currently a
  single-maintainer project and requiring 1 approval would deadlock
  merges (you cannot approve your own PR). Raise it to 1 the moment a
  second maintainer exists.

## 2. Renovate (dependency updates)

The Mend-hosted [Renovate GitHub App](https://github.com/apps/renovate)
is installed on this repository — no PAT, no secrets.
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

## 3. General settings (Settings → General)

- Merge buttons: allow **merge commits and squash**, disable rebase
  (matches the ruleset; merge commits are the default habit, squash is
  the occasional exception).
- **Allow auto-merge**: on — Renovate's auto-merge relies on it.
- **Automatically delete head branches**: on.

## 4. Code security (Settings → Advanced Security)

Everything free for the repository's visibility is enabled:

- **Dependency graph**: on — required by the dependency-review check.
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
- **Automatic dependency submission**: leave **off** — it only covers
  Maven-style ecosystems and does nothing for mix. The
  dependency-submission workflow in this repo submits mix.lock to the
  dependency graph instead, which is what lets Dependabot alerts and
  the dependency-review check see Elixir dependencies.

## 5. Actions hygiene (Settings → Actions → General)

- Workflow permissions: **Read repository contents** (workflows that
  need more declare it per-job; keep the default minimal).
- Allow GitHub Actions to create and approve pull requests: **off**
  (nothing here needs it; the Renovate app is not affected).
- **"Require actions to be pinned to a full-length commit SHA": off.**
  It would also block `uses: tskovlund/.github/...@main`, and the
  auto-propagating shared workflows are deliberate. Renovate's
  pinGitHubActionDigests preset keeps third-party actions SHA-pinned
  without giving that up.
- **Actions policy**: "Allow tskovlund, and select non-tskovlund,
  actions and reusable workflows", with "Allow actions created by
  GitHub" checked and this allow-list:

      DeterminateSystems/*, docker/*, erlef/*, gitleaks/*,
      nix-community/*, pnpm/*

  Stricter than "allow all", and new entries are rare (Renovate SHA
  updates never touch the list because it matches by name).

## Choices made autonomously (and why)

- **Merge commits only** — owner decision (honest history over a
  rewritten one). The earlier linear-history requirement was dropped
  because merge commits and linear history are mutually exclusive.
- **Renovate via the hosted app** rather than self-hosted Actions —
  zero secrets to manage; the config file is identical either way.
- **Auto-merge only for non-major updates**, and only after all
  required checks pass. Majors wait for a human.
- **CodeQL scans JavaScript and the workflows themselves** — CodeQL has
  no Elixir support; Elixir-side scanning is Sobelow plus
  `mix deps.audit` and `mix hex.audit` in CI on every PR.
- **Gitleaks workflow in addition to GitHub secret scanning** so secret
  detection also runs on private forks/mirrors and full history.
- **OpenSSF Scorecard not added**: it hard-fails on private
  repositories; add `ossf/scorecard-action` once the repo is public.
