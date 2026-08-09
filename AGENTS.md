This is a web application written using the Phoenix web framework.

## Kammer: working autonomously on this repo

Read order for picking this up cold: [SPEC.md](SPEC.md) (what the
product is) → [CONVENTIONS.md](CONVENTIONS.md) and
[CONTRIBUTING.md](CONTRIBUTING.md) (how to work on it) →
[docs/development.md](docs/development.md) (workflow reference,
pitfalls) → open GitHub issues, especially anything labeled `decision`,
plus **#352 (the durable v1 ordering — the master plan for everything
left, updated by full-catalogue sweeps)** and **#314 (the approved A+
quality program)** → then
[`docs/decisions/`](docs/decisions/) (why past calls were made). Owner
comments on issues override everything below. (The Phase 2 umbrella #33
is closed, superseded by #352 as the live plan.)

**Picking this up in a brand-new session**: check open PRs first — an
unmerged PR from a prior session takes priority over starting anything
new, and no new work starts on a branch until the current PR is merged.
Otherwise open GitHub issues are the only durable backlog; a prior
session's in-memory task list is not persisted and must not be assumed
to exist. `decision`/`action` issues assigned to the owner are
read-only for you; everything else open and unassigned is fair game.

**The Svelte PWA over the JSON API is the only product UI** — LiveView
was removed in #187 (ADR 0024), so new user-facing capability lands in
the API and the PWA, full stop. Client-side conventions live in
[CONVENTIONS.md](CONVENTIONS.md), SPEC.md §21, and `clients/web/`.

**Don't reproduce a prior iteration's limitations** (owner-stated
2026-07-12). Match _or exceed_ whatever came before — "the old version
only did X" is never on its own a reason to stop at X, nor to carry an
old bug forward. (Widened #259 from a required-only toggle to full
label/visibility editing.)

### PR lifecycle

Conventional Commits, Gettext EN/DA, and ADR triggers are specified in
[docs/development.md](docs/development.md) and
[CONVENTIONS.md](CONVENTIONS.md); this is the agent-specific sequence
layered on top. (Step 4's CHANGELOG scope is the actual policy —
neither of those docs states one.)

One coherent concern per PR: a feature, a docs reorg, and a dependency
bump get separate branches, even mid-session.

**Parallel PRs via side branches** (owner-approved 2026-07-09): the
designated branch is the _main lane_, reserved for ladder/server
feature PRs, and stays strictly serial — they all touch the same
hotspots (CHANGELOG, serializer, `api_spec`, schemas, router, the
generated `schema.d.ts`), so a second open PR only converts merge-waits
into rebase-waits. Genuinely orthogonal PRs may run in parallel on
suffixed side branches (`<designated-branch>-docs`, `-client`,
`-site`, `-ci`): one coherent concern each, same gates and review
rules, cut fresh from `origin/main` per PR and deleted after merge. You
manage merge order; if a side PR collides with the main lane (both
touch CHANGELOG, say), merge the main-lane PR first and rebase the side
branch. Never more than one open PR _per lane_, and never use a side
branch to dodge the one-concern rule.

1. `git fetch origin main && git checkout -B <branch> origin/main`.
2. Implement, then verify with **all four** gates: `mix precommit`
   (format, Credo strict, warnings-as-errors, tests),
   `mix dialyzer --format short`, `mix sobelow --config`, and the root
   `npx prettier@3.8.1 --check .` (the CI Prettier job's exact command;
   version-lockstep set in the remote-container notes). The last three
   are not in the `precommit` alias, and nothing else covers root
   markdown — CHANGELOG asterisk emphasis slipped past the local gates
   and failed CI on 2026-07-17.
3. Self-review before opening the PR: run the `code-review` skill
   against the diff and address what it finds. ("Well-structured, not
   just lint-clean" is the one thing not machine-checkable.)
4. Add a `CHANGELOG.md` entry under `## [Unreleased]` for anything
   worth recording — user-facing changes, and audit-driven fixes or
   additions (including pure test-coverage ones) even though those
   aren't user-facing — describing what gap it closed.
5. Commit inside `nix develop --command`; Conventional Commit message.
   Use `Closes #N` only on the commit that actually finishes an issue:
   GitHub auto-closes from **any** commit referencing it, not just the
   PR description, so earlier PRs in a multi-PR issue say `Part of #N`
   or the issue closes prematurely.
6. Push with `-u`, open the PR, subscribe to its activity.
7. Three things gate the merge, in no fixed order: CI green, review
   comments addressed, and an independent Agent review run and
   addressed.
8. Merge with a merge commit, then immediately restart the branch
   (`git fetch origin main && git checkout -B <branch> origin/main`)
   **and push that reset** (`git push origin <branch>`) before touching
   anything else, not whenever a later commit happens to. A remote
   branch left at the pre-merge tip makes every session-stop check that
   diffs local `HEAD` against it report the merge commit as unpushed,
   every session, until something closes the gap. This push is always a
   fast-forward, never a force-push.

### Independent review

Two gates, both required, neither redundant. **Self-review** (step 3),
run by the implementing session before the PR opens, is 2–3 parallel
_finder_ agents with distinct lenses — correctness, contract-trace,
tests-and-conventions, plus a security lens for any privileged surface
— on the integrated diff. **Independent review** is a _separate_ fresh
Agent with no context from the implementing session, run on the
committed head before merge and told what the finders already covered
so it goes deeper and sideways instead of repeating them. Automated
tooling (the four step-2 gates, CI) enforces correctness and style, not
design quality or "does this test actually test what it claims to."
Every substantive slice's reviewer has found something real.

Tell the independent reviewer to be adversarial and report ranked
findings rather than default to a clean bill of health — and that
**GitHub is read-only for it**. That clause goes in _every_ spawned
agent's brief, finders and builders too: an agent that "helpfully"
comments, edits, reviews, merges, or pushes corrupts the record of who
wrote what (unattributable PR-body edit, 2026-07-17). Findings and
patches come back as the agent's final message, nowhere else.

Skip independent review only for a purely mechanical change (a
dependency bump, a typo fix). **"Docs-only" is not itself a mechanical
category** (owner-stated 2026-07-12): docs are part of the product, so
any doc change that _authors_ normative content — a SPEC edit that
decides something, an ADR, operating-manual prose — gets the
independent pass. Exempt is the _judgment-free_ edit: a typo, a dead
link, verbatim transcription of a settled decision. Address what it
finds, or note in the PR why not.

**The dismissal bar** (owner-stated 2026-07-12; recalibrated 2026-07-17
after the owner overruled three dismissals): a finding — the reviewer's
or your own observation — is dismissed only when fixing it costs
something real (complexity, risk, genuine scope) or the finding is
factually wrong. "Minor", "small", "rare", "established wording", and
"doesn't need to scale" are **not** acceptable reasons — the owner's
test is "if it's that cheap, name one good reason to not do it now."
When in doubt, fix it. This bar triggered a full re-audit of every
dismissal in the repo's history (2026-07-17; four failed the re-test
and became issues), so dismissals recorded before that date don't set
precedent.

**A conditional disposition ("fix when X lands") must put its trigger
on a GitHub issue** — the one X's implementer will actually touch, or a
new one — never only in a PR comment or review reply, which is
invisible to the session that lands X. (An RSS item-link fix deferred
in #54 went unfound until a 2026-07-17 audit surfaced it as #341.) If
the condition isn't worth an issue comment, the deferral isn't real —
fix it now.

**"Done" means present in the committed tree, not intended.** Verify
your own claims against the tree before asserting them in a PR body, a
review disposition, or chat — this session once claimed a test that was
never written, and the reviewer caught it.

**Reviewers and finders read the committed tree, never a captured diff
alone**, and read whole files around each change, not just the hunks.
Tell them to **pin to the commit SHA, not `HEAD`** (`git show <sha>`,
`git show <sha>:<path>`, `git diff origin/main...<sha>`): the main
session can switch the working-tree branch out from under an in-flight
review — opening a side-branch PR does exactly this — and an agent
reading `HEAD` mid-switch silently reviews the wrong tree. Running the
agent in a **worktree** (`isolation: "worktree"`) sidesteps this
entirely. A captured diff is worse still: three finder rounds were once
burned on a stale snapshot. Tell them to VERIFY contracts against
source (read the changeset / context / serializer before trusting any
client→server field mapping) — a build agent once _guessed_ a 422
detail key and the wrong client mapping shipped.

### Delegating to build agents

When a slice is large enough to hand to a build Agent rather than
implement inline, run it in a **worktree** (`isolation: "worktree"`) so
parallel agents don't collide on the tree. The brief MUST say, in
spirit verbatim: **FIRST ACTION: run `pwd` and confirm you are inside
your assigned worktree — if you are in the shared checkout, STOP; do
NOT spawn sub-agents; GitHub is READ-ONLY for you — never create, edit,
comment on, or label any issue or PR, nor write to GitHub in any other
form (reviews, merges, pushes included); run every gate inline in the
foreground and wait for it to finish; do NOT wait on notifications;
deliver the patch plus a commit-message file to the session scratchpad
AND bank a copy into `$(git rev-parse --git-common-dir)/banked-patches/`
(`mkdir -p` it first — that expression resolves to the main checkout's
`.git` from inside any worktree); return raw data as your final
message.** (Each clause is incident-earned: a builder ran
`git reset --hard origin/main` in the shared checkout and yanked the
session's branch pointer out from under in-flight edits; three builders
backgrounded `mix precommit` and reported "done" with the gate still
running; a mid-session scratchpad wipe left the banked copy as the only
survivor. Only pushed commits survive the container itself.)

Agents write to a _fresh_ scratchpad each session, never a path carried
over from a prior session's notes. A fresh worktree may first need
`mix local.hex --force && mix deps.get`, `pnpm install`, and — when
plain `nix develop` fails on it — `nix develop "path:$PWD"`.

**Model selection** (owner-approved 2026-07-17): creation can be
cheaper, verification must not be. A builder whose brief fully
enumerates the changes (files, functions, expected tests) runs on
Sonnet; finders, adversarial reviewers, design work, and orchestration
stay on the top tier. Escalate back to the top tier when gates fail
repeatedly or the slice carries authorization-critical control flow —
briefs like that can't be fully enumerated, which is the tell.

Never trust a build agent's committed generated artifact (above all
`schema.d.ts`): regenerate it on the integrated branch and require a
byte-identical diff — that check has caught real drift. Recipe in the
remote-container notes.

### Session mechanics (check-ins, reply scans)

None of these is delivered to you automatically; arming them is your
responsibility.

- **After opening any PR, subscribe to its activity and arm a one-shot
  self check-in a few minutes out, not 15–20** (owner-stated
  2026-07-12). Webhooks deliver CI _failures_ and comments but never CI
  _success_, so without it a green PR just sits unmerged. Re-arm each
  time it fires until the PR is merged or closed; check-ins bound to a
  prior session die with it.
- **Never cancel a stale check-in** (owner-stated 2026-07-12: each
  cancellation needs owner approval, so it's pure churn). A one-shot
  check-in that outlives its PR fires once and gets no-oped ("stale,
  already merged"). Cancel only when the owner says to stop watching a
  PR mid-flight, and never cancel-and-re-arm to "refresh" one for a new
  head — a check-in acts on the PR's _current_ head regardless of any
  SHA in its text.
- **Prefer per-PR one-shot check-ins to a generic recurring trigger**,
  which fires on a fixed schedule even with no open PR, is less
  responsive than one tuned to expected CI time, and still needs
  disabling when idle.
- **Owner-reply scans**, hourly during owner-away stretches: GitHub
  comments are not pushed to the session. Scan from the _previous
  scan's actual timestamp_, not a fixed window (a fixed window missed
  an owner reply once), reading assigned and `decision` issues'
  comments directly.
- **Side-branch PRs need a branch update (`gh pr update-branch`) and a
  CI re-run after any main-lane merge**, or branch protection won't let
  them merge — their checks go stale against the new `main`.

### Architecture audits

Distinct from the periodic line-level quality/DRY sweeps ("is each
piece internally consistent"): a dedicated architecture-level review
asking "is the system's shape still right" — module cohesion, context
boundaries, the inter-context dependency graph, god-modules accreting
unrelated responsibility, whether an early context split still holds.
File findings as GitHub issues the way line-level audits do, and file
the audit itself as an issue labeled `architecture-audit` so the
cadence is checkable without relying on memory.

**Trigger**: search issues **including closed ones**
(`label:architecture-audit`, `state:all`, sorted by creation date — a
completed audit's tracker gets closed, so an open-only search always
reads as "none has ever run"). Run one now if that search is empty.
After that, re-run when either 90 days have passed since the most
recent one was opened or a full round of line-level audit fixes has
completed — whichever comes first.

### Task & state tracking

GitHub Issues are the only durable, cross-session source of truth. The
in-session task list is scratch for the current session only; it does
not persist, and a new session must not assume it exists. Anything that
must survive goes in an issue, a CHANGELOG entry, an ADR, or this file
— never only the task list or the conversation.

- Work from open GitHub issues, not a separate backlog doc.
  Implementation choices are yours; product-shaping choices (pricing,
  naming, new scope) go to an issue assigned to the owner with concrete
  options and a recommendation (label `decision`).
- Issues that are the owner's own action (real-machine testing, human
  review passes, infra deploys, final naming/business calls) are read,
  never resolved unilaterally — comment status deltas, don't close them
  (label `action`).
- Keep the owner assigned only while an issue genuinely waits on their
  input. Unassign once resolved (the issue can stay open for tracking);
  implementation work, including sequencing already-approved items, is
  never a reason to keep them assigned.

#### Issue hygiene (continuous, not a one-off pass)

Issues are the async communication channel — during owner-away
stretches the _only_ one — so a messy tracker is a broken channel, and
hygiene is standing maintenance rather than a scheduled task. Owner,
2026-07-19: "issue hygiene is how I follow our progress… nothing
random, everything deliberate and aligned, down to the last issue title
format." When the tracker has drifted enough to warrant a full sweep,
run it as a read-only fan-out of auditors over slices against one fixed
rubric, with synthesis and every write kept on the main session and a
single named before/after batch for the owner to approve first.

- **The open-issue count is a metric the owner watches** (stressed
  twice, 2026-07-09). Net growth needs justification: before filing,
  ask whether it folds into an existing issue, and pair filing with
  closing — closing what a merge completed is part of landing the
  merge. Refined 2026-07-17: the goal is **turnover and an
  eventually-shrinking pile**; once the audit backlog clears, sessions
  must trend net-negative. **No GitHub milestones** (owner-declined)
  and **no separate tracked progress number** such as a posted
  "v1-gating count" (owner-stated 2026-07-19: "just another number that
  grows stale if you track it") — the honest open list is the tracker.
- **Stale/superseded issues get closed, not left open**, with a comment
  explaining why (`state_reason` of `not_planned` or `completed`).
  A partly-stale but still-live body gets a dated status comment, or a
  body/title edit where the stale part is a short, wrong factual claim
  — not silent rot. Prefer a status comment to retyping a long body:
  reproducing an audit finding's code refs risks corrupting them.
- **A resolved decision must be struck from the issue _body_**, not
  just answered in a comment: edit the body, drop the `decision` label,
  unassign the owner. A comment plus label-drop leaves the body opening
  with "Decision needed" and a later session re-surfaces it as
  unanswered (#352's chat-scope question, 2026-07-19). Corollary:
  **never manufacture a decision from an inferred omission** — if the
  ADR, SPEC, and issue thread agree and the owner hasn't signalled
  otherwise, it's settled. Always read an issue's full comment thread
  before surfacing any "open decision"; the answer is often already
  there under a stale body.
- **Labels are load-bearing.** Four axes, not one catch-all —
  `enhancement` is not a default. Re-check labels when an issue's
  status changes, not just at creation.
  - **Type** (exactly one): `bug` (real correctness/security defect),
    `enhancement` (genuinely new user-facing capability — not audit
    cleanup, a doc fix, or a test gap), `tech-debt` (refactor, cleanup,
    DRY, context-boundary fix, no behavior change), `documentation`,
    `tests`. Before reaching for `enhancement`, ask whether it's really
    a new capability or cleanup wearing the default label. Exception
    (owner-confirmed on #236): purely owner planning/action items carry
    no Type label — that axis classifies work on the product.
  - **Process** (zero or more): `decision`/`action` only while
    genuinely blocking; `roadmap` on confirmed future scope.
  - **Provenance** (zero or one): `architecture-audit` /
    `quality-audit`, on every sub-issue a tracker spawns, not just the
    tracker.
  - **Component** (zero or one): `api`, `web-client`. Don't add a new
    component axis casually — per-context labels (`area:feed`, …) would
    fragment a tracker this size for no payoff; revisit past roughly
    100 open issues.
- **Titles carry no hand-rolled label echoes** — no `[decision]` or
  `[bug]` prefixes. The label already says it, the prefix duplicates it
  inconsistently, and it rots when the label changes. Plain,
  sentence-case, descriptive titles.
- **Umbrella/tracker issues use GitHub-native sub-issues, not prose.**
  Link children through GitHub's sub-issue API (children are addressed
  by internal node id, not `number`), the way #33/#74/#90 do. A tracker
  with prose-only "#122, #123, …" references and no native links is
  exactly the inconsistency this section exists to catch — check every
  new tracker before calling it done.
- **Consistent structure**: a one-line "What", then context/reasoning,
  then a checklist or "Files touched" if implementation-relevant. Match
  nearby issues rather than improvising a format per issue.
- **Prioritization shifts get reflected in the tracker**, not just
  remembered — when a class of issues drops in priority from a bigger
  strategic shift, say so on those issues.
- **Bulk edits to pre-existing issues need the owner to name the
  batch**, not just approve the idea: compute the exact before/after
  and post it as one comment on a single issue for approval. A denied
  write is never routed around — many direct calls are the same pattern
  as one delegated call — and a "go ahead" covers that named batch
  only, not whatever comes later.

### Product scope changes

SPEC.md §16's "explicit non-goals" list is the canonical, durable
record of what's out of scope — not this file, not a conversation. The
moment the owner adds, removes, or narrows a non-goal, or states any
other scope decision, it goes into SPEC.md (plus a cross-referenced
issue tracking the now-in-scope item, and an ADR if it reverses a prior
architectural decision) in the same turn, before continuing whatever
was in progress. A scope decision that only lives in conversation is
exactly what a long, compacted session loses. (This rule exists because
that happened: native apps were listed as an explicit non-goal despite
the owner wanting them built.)

Corollary: the non-goals list is not static background reading. If a
session's work touches it, or the owner's request brushes against
something listed there, read the whole list back and ask whether it's
still accurate — asking costs one message; silently building, or
silently refusing to build, something the owner changed their mind
about costs much more.

### Owner interaction

- Renovate runs Mondays 07:00 CPH; non-major dependency PRs automerge
  when checks pass, majors wait for the owner.
- Message the owner only at milestones or when genuinely blocked.
- **When asked to make a decision, always give a recommendation, not a
  menu** (owner-stated 2026-07-12). Lead with the option you'd pick,
  flagged as your recommendation, and the reasoning; alternatives come
  after. Holds for a `decision` issue and an in-chat question alike.
- **Anything asking the owner to decide leads with a TL;DR-ask block**
  (owner-prompted 2026-07-17: "I have no idea what to read or what to
  reply to"): **Decision needed** in one sentence, **My recommendation**
  in one sentence, then **Reply with:** the literal short answers that
  unblock the work ("Go" / "Keep gate" / …) — answer tokens for the
  recommendation, not a menu of undecided options — plus a note that
  reading the full analysis is optional. Long-form reasoning goes
  _below_ that block, never above. A decision post the owner can't
  answer in one line from the first screen is a defect in the post.
- Surface a process/convention question when there's no precedent in
  this file or the linked docs rather than picking one silently — and
  once answered, write the answer down here so it isn't asked twice.
- **Read an issue's full comment thread before asking the owner
  something in chat that might already be answered there.** GitHub
  comments are a channel the owner uses independently of chat.
- **The owner is _always_ assigned to any issue awaiting their input —
  no exceptions** (owner-stated 2026-07-10, after the pattern slipped
  twice). Their assigned-issues list is the one overview they maintain,
  so a question in an unassigned issue is effectively unasked. Assign
  the moment the question is posed; unassign when the input arrives.
  This covers _any_ owner input — decisions, reviews, steers, restyle
  passes — not just `decision`-labeled issues.
- **Anything needing the owner to decide or review before it's final
  goes in a GitHub _issue_ (assigned, `decision` label) — never in a PR
  body or comment** (owner-stated 2026-07-10). A PR can merge before
  they read it and the decision point is then gone; an issue has no
  such deadline. A PR body describes the change and non-blocking
  status. If a design choice in a PR genuinely needs sign-off, file the
  issue, cross-reference it from the PR as non-blocking, and proceed on
  the most reasonable option. This holds in sync mode too.

#### Async-only stretches (owner watching GitHub, not chat)

The owner periodically goes fully async and means it literally: no chat
replies coming, GitHub the only channel they check, for a defined
stretch. During one:

- Keep working autonomously; pausing for a chat reply that will not
  come is a stall, not caution.
- Write all status, findings, and decisions to GitHub, routed by the
  owner-interaction rules above — chat may not be read again for the
  whole stretch.
- For a `decision` issue that would normally block, pick the most
  reasonable option and say so in an issue comment with the reasoning,
  so the call is visible and overridable, then keep moving.
- Resume normal "surface and wait" behavior the moment the owner posts
  in chat again; async-only is a temporary mode, not a default.

### Continuous process critique

Critique the process itself unprompted, at every level: orchestration
(solo vs. an Agent vs. a Workflow swarm — pick per task, don't
default), tracking, prioritization (what's deferred and why, said out
loud), owner-interaction cadence, and whether what was just decided is
written down durably. Give opinions and concrete proposals as they come
up, not only when asked.

**This is as much about the _product_ as the process** (owner-stated
2026-07-12): critique the UX, the model, and the feature set, and
propose improvements unprompted, routed by the owner-interaction rules
— a product gap is an issue (mind the open-issue count), a scope
question needing the owner's call is an assigned `decision` issue.
Leave both the product and the process better than you found them.

**Persist process changes automatically, without being asked**: the
moment a standing decision or convention is made — whether the owner
states it or you reach it yourself — write it into this file (or a
CHANGELOG entry, ADR, or issue) in the same session. This instruction
is itself an example: it exists because it was asked for once and must
never need asking again.

## Kammer: remote container notes (Claude Code on the web)

- Nix may be **absent entirely** on a fresh container. Restore it with
  the official installer: create the `nixbld` group and the
  `nixbld1`..`nixbld10` users first
  (`useradd -r -g nixbld -G nixbld -M -N -s "$(command -v nologin)" nixbldN`),
  then run `sh nix-install.sh --no-daemon` (the installer fetched from
  nixos.org). Binaries land at `/root/.nix-profile/bin`, so
  `export PATH=/root/.nix-profile/bin:$PATH` in every shell
  (`/nix/var/nix/profiles/default/bin` may be absent until the
  reinstall; afterwards both resolve to the same store path), and
  `export NIX_SSL_CERT_FILE=/root/.ccr/ca-bundle.crt` so Nix trusts the
  proxy's CA. The single-user install ships with flakes **off**, so
  `nix develop` errors (`experimental Nix feature 'nix-command' is disabled`)
  until you enable them once:
  `mkdir -p /root/.config/nix && printf 'experimental-features = nix-command flakes\n' > /root/.config/nix/nix.conf`.
- Node and pnpm are pre-installed at `/opt/node22/bin` (not via Nix):
  `export PATH=/opt/node22/bin:$PATH` and
  `export NODE_EXTRA_CA_CERTS=/root/.ccr/ca-bundle.crt` for the client
  gates and the root `npx prettier@3.8.1 --check .`. That Prettier
  version is pinned in `ci.yml`, the `Makefile`'s `format` target, and
  PR-lifecycle step 2 — on a bump, update every one in lockstep, both
  AGENTS.md mentions included. Run client gates from absolute paths or
  `pnpm --dir clients/web ...`; **never `cd` mid-chain** — the Bash
  tool's cwd persists between calls, so a stray `cd` leaks into the
  next command and has caused repeated failed runs.
- The proxy blocks GitHub release downloads, so `mdex_native`'s
  precompiled NIF download 403s at compile time. Fix:
  `export MDEX_NATIVE_BUILD=1` to build it from source (cargo is
  preinstalled at `/root/.cargo/bin`).
- `pg_ctlcluster 16 main start` after container restarts (a stale pid
  is normal; Postgres also drops mid-session sometimes, same fix). A
  fresh container may additionally need
  `su postgres -c "psql -c \"ALTER USER postgres PASSWORD 'postgres'\""`
  once, so the app's dev config can authenticate.
- Commit and push inside `nix develop --command` (git hooks need `mix`
  on `PATH`). Committer identity: `Claude <noreply@anthropic.com>`.
  There is no signing key in the container, so every commit is
  **unsigned and shows as "Unverified" on GitHub** — expected, not a
  defect. The committer email is already correct, so do **not** amend
  with `--reset-author` to chase the badge: it changes nothing about
  verification and rewrites the SHA, yanking the tree out from under
  any in-flight SHA-pinned review agent.
- The Playwright e2e gate (`scripts/e2e.sh`) needs a browser and `mix`
  on PATH, so run it inside `nix develop` with
  `export CHROMIUM_BIN=/opt/pw-browsers/chromium` (the config reads
  `CHROMIUM_BIN`; the container pre-installs Chromium there — never
  `playwright install`). It is **destructive to `kammer_dev`**, so
  don't point it at a database you care about.
- Regenerate `schema.d.ts` after any API-file change and require a
  byte-identical diff, using the **project-pinned tools exactly as
  written here** — five independent agents have confirmed the
  alternatives are traps. From repo root, `rm -f /tmp/spec.json` first
  (a compile failure leaves the old spec behind and the next step
  happily regenerates from it), then
  `nix develop --command bash -c 'mix run --no-start -e "File.write!(\"/tmp/spec.json\", Jason.encode!(KammerWeb.ApiSpec.spec()))"'`
  then, with node on PATH,
  `clients/web/node_modules/.bin/openapi-typescript /tmp/spec.json -o clients/web/src/lib/api/schema.d.ts`
  then
  `pnpm --dir clients/web exec prettier --write src/lib/api/schema.d.ts`,
  then confirm `git diff --quiet clients/web/src/lib/api/schema.d.ts`.
  (The two node steps mirror `clients/web`'s `generate:api` script with
  explicit pinned paths — if that script changes, sync this recipe.) Do
  **not** substitute a root-level `npx prettier` for the last step: the
  root `.prettierignore` excludes `clients/web/`, so it exits 0 having
  formatted _nothing_ and the unformatted output reads as a false
  ~30k-line drift. Floating `npx` versions differ from the client's
  pinned ones for the same effect. After the pinned recipe a non-empty
  diff is real — the committed copy was hand-edited or stale; never
  ship it.
- Screenshots: `docs/screenshots/` gets a single batch refresh before
  v1 (owner-stated 2026-07-12) — note UI changes in the PR and let that
  batch cover them; no per-PR regen, and don't block a merge on it. The
  PWA-era replacement for the dead LiveView Screenshots workflow rides
  the docs overhaul (#189) and the visual-regression net (#286).
- If GitHub tool access shows as disconnected it needs re-authorization
  from the owner (`claude mcp` / `/mcp`, not doable from an agent
  session); local git still works without it.

## Project guidelines

- Use the `mix precommit` alias when you are done with all changes, and
  fix any pending issues.
- Use the already included `:req` (`Req`) library for HTTP requests;
  **avoid** `:httpoison`, `:tesla`, and `:httpc`.
- **Every test earns its place** (owner-mandated; full statement in
  [CONVENTIONS.md](CONVENTIONS.md) §Tests) — the suite is a portfolio
  piece, and a test that asserts nothing, restates the framework,
  duplicates coverage, or exists as ceremony is a defect.
- Fields set programmatically, such as `user_id`, must **not** appear
  in `cast` calls or similar; set them explicitly when building the
  struct, or the endpoint is mass-assignable.
