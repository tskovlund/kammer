## What & why

<!-- Summary of the change and its motivation. Link issues. -->

## How

<!-- Anything a reviewer should know about the approach. -->

## Checklist

- [ ] Conventional Commit messages
- [ ] `mix precommit` green (format, Credo strict, warnings-as-errors, tests)
- [ ] Tests added/updated (permission logic → context tests required)
- [ ] User-facing strings via Gettext, EN + DA complete
- [ ] Permission/visibility decisions go through `Kammer.Authorization` only
- [ ] ADR added if an architecture-shaping decision changed; SPEC.md updated if a product decision changed
- [ ] `CHANGELOG.md` entry under `## [Unreleased]` for anything worth recording (user-facing changes, and audit-driven fixes/additions such as pure test-coverage additions)
- [ ] Docs still true (README, `AGENTS.md`/`CLAUDE.md`, docs/, `.env.example`) — updated here if not
- [ ] What's left tracked as a GitHub issue, not left as a silent stub
- [ ] UI changed visibly? Regenerate `docs/screenshots/` (`scripts/screenshots.sh`)
