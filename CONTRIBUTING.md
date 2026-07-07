# Contributing to Kammer

Thanks for wanting to help build a calmer home for real-world communities.

## How contributions work: prompt requests

Kammer takes contributions as **prompt requests**: open an issue that
describes what you want — a bug report, a feature idea, a design
sketch, even a fully specified implementation plan — and a maintainer
implements it. Anyone can open issues; pull requests are reserved for
maintainers.

Why this model: Kammer is maintained by a very small team with a high
bar for the codebase (see [CONVENTIONS.md](CONVENTIONS.md) — lean, no
hacks, exemplary). Reviewing external code to that bar costs more than
writing it, while describing a change well costs you far less than
implementing it. The better the prompt request — context, the _why_,
edge cases, proposed behavior — the faster it ships.

Unsolicited pull requests are closed with a friendly pointer to this
section; it's the model, not a judgment of your code. If you'd like to
join the implementing-and-reviewing side, say so in an issue — growing
the maintainer team is how this scales.

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

## Pull requests (maintainers)

- One coherent change per PR; Conventional Commit messages.
- Add tests for behavior you add or change — permission/visibility logic
  changes require context-level tests.
- All user-facing strings through Gettext, with English **and** Danish
  translations (`mix gettext.extract --merge`, then fill both locales).
- Architecture-level decisions get a short ADR in `docs/decisions/`.

## Decision-making

Implementation choices are the maintainer's to make. Product-shaping
choices — pricing, naming, UX philosophy, new scope — go to a GitHub
issue labeled `decision`, assigned to the project owner, with concrete
options and a recommendation. Owner comments on any issue override
whatever's written elsewhere, including this document.

## The backlog

What's left to build lives as GitHub issues (labeled `enhancement`),
not a separate roadmap document — issue #33 is the current umbrella
tracking Phase 2 completion, with each remaining item wired in as a
real **sub-issue** (not a hand-written checklist link), so its progress
bar and checkbox state track automatically when a sub-issue closes.
Working on something not yet tracked? Open an issue first — and add it
as a sub-issue of the relevant umbrella — so the "what's left" view
stays accurate without anyone having to remember to edit it.

## How this stays fresh, not just written down

Every doc above has exactly one reason to exist, and each one's
freshness is enforced at a different point rather than left to
memory:

- **What's left (Issues)** stays accurate because closing the PR that
  resolves an issue closes the issue itself — there's no separate
  edit step to forget. Sub-issue linking (above) extends that to
  umbrella tracking issues too.
- **What shipped (`CHANGELOG.md`)** and **what changed architecturally
  (`docs/decisions/`)** are enforced by the PR template checklist —
  the same checklist item exists for Gettext completeness, and CI
  additionally gates on it (below).
- **Whether a doc reference still points somewhere real** is a CI gate
  (#72 tracks adding this — it doesn't exist yet, filed rather than
  silently assumed), because "the PR template asked and someone
  checked the box" has already failed once (`docs/HANDOFF.md` went
  stale mid-project before being retired).
- **Whether Danish translations are actually complete** is likewise
  slated to become a CI gate (#71), not just a checklist line, for the
  same reason.
- **Whether the code itself is well-structured, not just
  lint-clean** — the one thing genuinely not machine-checkable — gets
  a self-review pass (the `code-review` skill against the diff) before
  a PR opens, not just the automated gate after.

The rule underneath all of it: if keeping something current requires a
human (or an AI) to remember to do it by hand, on every single change,
forever, that's a bug in the process, not a discipline problem to
solve by trying harder. Prefer a mechanism (auto-closing issues,
CI gates, native GitHub linking) over a reminder every time one is
available.

## Reporting security issues

Please see [SECURITY.md](SECURITY.md) — do not open public issues for
vulnerabilities.
