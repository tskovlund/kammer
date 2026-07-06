# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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
