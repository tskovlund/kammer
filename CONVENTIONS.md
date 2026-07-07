# Conventions

Engineering standards for Kammer (SPEC.md §17). These are enforced by
tooling wherever possible; the rest is enforced in review.

## No hacks

- **Proper fixes over workarounds — always.** A hack is a symptom of a
  problem understood poorly or fixed in the wrong place. Solve at the
  root cause, even when it costs more now.
- If a workaround is genuinely unavoidable (an upstream bug, a platform
  limitation outside our control), it must be **(1) justified in a
  comment stating the external cause, (2) tracked** (a GitHub issue
  with a completion path), and **(3) removed** when the external cause
  goes away. Untracked workarounds are treated as bugs.
- The bar for the whole codebase: lean, documented where a constraint
  can't be expressed in code (never narrating the obvious),
  industry-standard, portfolio-worthy. When a shortcut is tempting,
  the answer is to shrink the scope, not the quality.

## Language & naming

- **Full, descriptive, unabbreviated identifiers** everywhere: schemas,
  functions, variables, assigns, template variables. `community`, not `comm`;
  `post` not `p` — including Ecto query bindings and comprehensions.
- Single-letter variables are banned by a custom Credo check
  (`Kammer.CredoChecks.NoSingleLetterVariables`). `_` and `_`-prefixed
  ignored bindings are fine.
- `@moduledoc` on every module, `@doc` on every public function,
  `@spec` on every public function (Credo `Readability.Specs` +
  Dialyzer verify).

## Authorization

- **One authorization module**: every permission and visibility decision
  flows through `Kammer.Authorization`. No inline permission checks in
  templates, LiveViews, or controllers — they ask the module.
- The file-visibility invariant (file/folder visibility can never exceed the
  owning scope's visibility preset) and sealed-group rules have dedicated
  test suites, property-based where practical (`StreamData`).
- The transport-parity property (`test/kammer_web/api/resources_test.exs`)
  asserts the JSON API enforces the identical authorization the UI does —
  it must keep passing through any authorization change.

## Reusable patterns (don't reinvent)

- **Guest identities** (`Kammer.Guests`) are the substrate for any
  account-less interaction: guest comments, signup slots, newsletter
  subscriptions. Nullable FK + `num_nonnulls(...) = 1` check, cascade
  erasure, claim on sign-in.
- **Feature gate**: anything new that's per-group-toggleable adds a
  feature atom in `Group @features` (ships OFF by default) and calls
  `Authorization.feature_gate/2` at context entry points.
- **API**: `KammerWeb.Api.Serializer` is the only wire-shaping layer;
  `ApiError` the only error shape; `Pagination` the only cursor code.
  New endpoints follow the existing controller pattern — thin, all
  policy in contexts/authorization.
- **Comments/reactions** are one engine (ADR 0007) — reuse for any new
  commentable/reactable thing.
- **Non-access-control visibility redaction** (e.g. which profile
  fields a viewer sees) doesn't need to route through
  `Kammer.Authorization` — a small local predicate fed by
  `Authorization.relationship/2`'s role is fine (ADR 0020). Reserve
  the central module for actual access control (can this person reach
  this group/file/post at all).

## Formatting, linting, compilation

- `mix format` — enforced by hook and CI (`mix format --check-formatted`).
- `mix credo --strict` — zero issues tolerated.
- `mix compile --warnings-as-errors` — warnings are errors, always
  (configured project-wide via `elixirc_options`).
- `mix dialyzer` — no unexplained warnings; PLTs cached in `priv/plts/`.
- `mix sobelow --config` — Phoenix security static analysis.
- `mix coveralls` — coverage floor is configured in `coveralls.json`;
  CI fails below it.

## Git

- **Conventional Commits**, enforced by commitlint (commit-msg hook + CI).
  Types in use: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `ci`,
  `build`, `perf`.
- **lefthook** hooks are installed by `mix setup` (`mix hooks.install`):
  - commit-msg: commitlint
  - pre-commit: format check, Credo strict, compile with warnings-as-errors
  - pre-push: full test suite
- Never commit with a red pipeline. `mix precommit` runs the whole gate.

## Tests

- Context-level unit tests for all domain logic — **permissions above all**.
- LiveView tests for critical flows: auth, posting, RSVP, invite redemption.
- Doctests where they genuinely add value.
- Property-based tests (StreamData) for the authorization invariants.

## Dependencies

- Prescribed set in SPEC.md §22. Prefer boring, maintained, well-documented
  libraries. If a needed library is stale, implement the minimal internal
  version instead and say why in the PR.
- `mix hex.audit` and `mix deps.audit` run in CI.

## Database migrations

- Migration churn is welcome pre-0.1.0: design schemas properly rather
  than adding compatibility warts for data that doesn't exist in
  production yet. Always `mix ecto.gen.migration migration_name` for
  correct timestamps and conventions.

## Dev environment

- The Nix flake (`flake.nix`) is canonical. `devbox.json` and `.envrc`
  wrap it. CI runs every check inside `nix develop --command` so local and
  CI toolchains are identical. See CONTRIBUTING.md for the three entry paths.

## i18n

- All user-facing strings go through Gettext from the first commit.
  English and Danish must be complete for every shipped surface, including
  emails. `mix gettext.extract --merge` before every UI commit.
- API error messages are deliberately English-only — clients localize
  them, not the server.

## Documentation

- Architecture decisions live in `docs/decisions/` as short ADRs
  (context → decision → consequences, ≤ 1 page).
- Scope trims, stubs, and deferrals go in the PR description and, if
  they outlive it, into a GitHub issue — silent stubs are forbidden.
