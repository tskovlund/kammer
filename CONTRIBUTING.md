# Contributing to Kammer

Thanks for wanting to help build a calmer home for real-world communities.

## Dev environment — three entry paths, one toolset

The toolchain (Elixir/OTP, Node for tooling, Postgres client, libvips,
lefthook) is defined once in `flake.nix`. Pick whichever entry path suits you:

1. **direnv** (auto-activation): `direnv allow`
2. **devbox** (no Nix knowledge needed): `devbox shell`
3. **plain Nix**: `nix develop`

Then, inside the shell:

```sh
mix setup        # deps, database, assets, git hooks
mix phx.server   # → http://localhost:4000
```

All three paths provide the identical toolset — CI runs the same flake via
`nix develop --command`, so "works locally" means "works in CI".

You also need a PostgreSQL 16 server reachable at `localhost:5432` with user
`postgres` / password `postgres` (or export `DATABASE_URL`). Easiest:

```sh
docker compose up db   # just the database from the compose file
```

## Everyday commands

| Task      | Command                                  |
| --------- | ---------------------------------------- |
| Setup     | `mix setup`                              |
| Run       | `mix phx.server`                         |
| Test      | `mix test`                               |
| Lint      | `mix lint` (format check + Credo strict) |
| Format    | `mix format`                             |
| Full gate | `mix precommit`                          |

## Standards

Read [CONVENTIONS.md](CONVENTIONS.md) — it is short and enforced by tooling:
Conventional Commits (commitlint), lefthook hooks (installed by `mix setup`),
Credo strict, Dialyzer, warnings-as-errors, Sobelow, and a test-coverage
floor. CI must be green; hooks keep you honest before you push.

## Pull requests

- One coherent change per PR; Conventional Commit messages.
- Add tests for behavior you add or change — permission/visibility logic
  changes require context-level tests.
- All user-facing strings through Gettext, with English **and** Danish
  translations (`mix gettext.extract --merge`, then fill both locales).
- Architecture-level decisions get a short ADR in `docs/decisions/`.

## Reporting security issues

Please see [SECURITY.md](SECURITY.md) — do not open public issues for
vulnerabilities.
