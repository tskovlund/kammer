# Conventions

Engineering standards for Kammer (SPEC.md §17). These are enforced by
tooling wherever possible; the rest is enforced in review.

## No hacks

- **Proper fixes over workarounds — always.** A hack is a symptom of a
  problem understood poorly or fixed in the wrong place. Solve at the
  root cause, even when it costs more now.
- If a workaround is genuinely unavoidable (an upstream bug, a platform
  limitation outside our control), it must be **(1) justified in a
  comment stating the external cause, (2) tracked** (an issue, or a
  note in `docs/HANDOFF.md`'s backlog, with a completion path), and
  **(3) removed** when the external cause goes away. Untracked
  workarounds are treated as bugs.
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

## Dev environment

- The Nix flake (`flake.nix`) is canonical. `devbox.json` and `.envrc`
  wrap it. CI runs every check inside `nix develop --command` so local and
  CI toolchains are identical. See CONTRIBUTING.md for the three entry paths.

## i18n

- All user-facing strings go through Gettext from the first commit.
  English and Danish must be complete for every shipped surface, including
  emails. `mix gettext.extract --merge` before every UI commit.

## Documentation

- Architecture decisions live in `docs/decisions/` as short ADRs
  (context → decision → consequences, ≤ 1 page).
- Scope trims, stubs, and deferrals go in the PR description and, if
  they outlive it, into `docs/HANDOFF.md`'s backlog — silent stubs are
  forbidden.
