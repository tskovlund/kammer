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
- **Wire shapes decode into strongly-typed clients without edge-case
  overrides** (owner-confirmed, 2026-07-11): a field is one JSON type,
  always — never `false | string`, never present-sometimes without
  being declared optional, never a shape that would force a Swift
  `Codable`/Kotlin serializer to special-case it. The native V1
  clients (ADR 0025/0028) generate from the OpenAPI document, so the
  conformance + bijection suites are the enforcement; this bullet is
  the _why_.
- **Comments/reactions** are one engine (ADR 0007) — reuse for any new
  commentable/reactable thing.
- **Non-access-control visibility redaction** (e.g. which profile
  fields a viewer sees) doesn't need to route through
  `Kammer.Authorization` — a small local predicate fed by
  `Authorization.relationship/2`'s role is fine (ADR 0020). Reserve
  the central module for actual access control (can this person reach
  this group/file/post at all).

## Configuration (no bare magic operational values)

Every operational/behavioural value lives in one of three tiers (ADR
0027); none is left as a bare inline literal. User-facing copy is
separate — that goes through Gettext.

- **Instance setting** — runtime-changeable, per-instance,
  admin-editable: `Kammer.Communities.InstanceSettings` + admin UI.
- **Deployment config** — set at boot from an env var, read via
  `config/runtime.exs`, **validated at boot** (bounds/format, raise on
  invalid), documented in `.env.example`. For operator-tunable
  operational values (throughput/policy rate limits, token lifetimes,
  retention windows): safe default, env override, validated bounds.
- **Named constant** — a module attribute with a comment stating _why_
  it is fixed. For genuinely never-configurable values: crypto/protocol
  constants, and the **anti-abuse/security rate limits** (a security
  limit behind a runtime knob is a footgun — keep them fixed).

So: a new magic number or operational string is either a named constant
with a rationale, or a configurable setting — never a bare inline
literal. Both review gates check this.

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

- **Every test earns its place.** The test suite is a portfolio piece,
  held to the same bar as the code it covers: lean, elegant,
  well-structured. Everything critical is tested — but a test that
  asserts nothing, restates the framework, duplicates another test's
  coverage, or exists only as ceremony is a **defect, not caution**:
  it buries the tests that matter and rots trust in the suite. Before
  a test is added it must justify itself — _what real failure does it
  catch that no existing test does?_ Prefer one sharp test over three
  overlapping ones; delete a test that no longer earns its place
  rather than keep it for the count. Coverage (the floor in
  `coveralls.json`) is a floor to never fall below, never a target to
  pad toward. Both review gates ask this question of every new or
  changed test.
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

- **Diátaxis is the organizing lens** (owner-confirmed, #236): every
  doc should know which of the four modes it is — tutorial (learning
  by doing), how-to (task recipe), reference (lookup), explanation
  (understanding/why) — and not mix them mid-page. Applied
  pragmatically, reader-first: the best reader experience wins over
  taxonomic purity, so a quickstart README may stay marketing-forward
  and an ADR is simply explanation. It also becomes the information
  architecture of the docs website (#188).
- Architecture decisions live in `docs/decisions/` as short ADRs
  (context → decision → consequences, ≤ 1 page).
- Scope trims, stubs, and deferrals go in the PR description and, if
  they outlive it, into a GitHub issue — silent stubs are forbidden.
