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
- [ ] BUILDLOG.md / ADR updated if scope or architecture decisions changed
