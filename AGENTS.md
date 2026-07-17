This is a web application written using the Phoenix web framework.

## Kammer: working autonomously on this repo

Read order for picking this up cold: [SPEC.md](SPEC.md) (what the
product is) → [CONVENTIONS.md](CONVENTIONS.md) and
[CONTRIBUTING.md](CONTRIBUTING.md) (how to work on it) →
[docs/development.md](docs/development.md) (workflow reference,
pitfalls) → open GitHub issues — especially anything labeled
`decision` and the Phase 2 umbrella (issue #33) for what's left → then
[`docs/decisions/`](docs/decisions/) (why past calls were made). Owner
comments on issues override everything below.

**Picking this up in a brand-new session**: check open PRs on this
repo first — an unmerged PR from a prior session takes priority over
starting anything new (see PR lifecycle below; never start new work
on a branch until the current PR is merged). If none, open GitHub
issues are the only durable backlog — a prior session's in-memory
task list is not persisted anywhere and must not be assumed to exist
or be reconstructable. `decision`/`action`-labeled issues assigned to
the owner are read-only for you (see Task & state tracking below);
everything else open and unassigned is fair game.

**LiveView has been removed (ADR 0024, cut in #187).** The Svelte PWA
over the JSON API is now the _only_ product UI — there is no LiveView
surface left to freeze, bugfix, or port. New user-facing capability
lands in the API and PWA, full stop. (History: LiveView was the
first-iteration UI, held bugfix-only under a feature freeze until the
PWA reached full parity, then deleted in one cut — #165/#187 both closed
by it. The framework-scaffold LiveView/HEEx/streams/gen-auth guidance
this file once carried was stripped right after the cut — what survives
below is only what still applies to the API server: the project, Elixir,
Mix, test, Phoenix-router, and Ecto guidelines. Client-side conventions
live in [CONVENTIONS.md](CONVENTIONS.md), SPEC.md §21 (the design
brief), and `clients/web/`.)

**Don't reproduce a prior iteration's limitations** (owner-stated,
2026-07-12; originally about LiveView→PWA ports, now the standing bar
for any rework). Match _or exceed_ whatever came before — "the old
version only did X" is never on its own a reason to stop at X, and never
a reason to carry an old bug forward. This reshaped the custom
profile-field surface in #259 — widened from a required-only toggle to
full label/visibility editing once the reasoning was caught.

### PR lifecycle

Full policy for Conventional Commits, Gettext EN/DA, and ADR triggers
lives in [docs/development.md](docs/development.md) and
[CONVENTIONS.md](CONVENTIONS.md) — this is the agent-specific
operational sequence layered on top, not a restatement of it. (The
CHANGELOG scope in step 4 below is the actual policy, not a pointer
to one defined elsewhere — neither of those docs states one.)

One coherent concern per PR: unrelated concerns (a feature vs. a docs
reorg vs. a dependency bump) get separate branches/PRs, even
mid-session.

**Parallel PRs via side branches** (owner-approved, 2026-07-09): the
designated branch is the _main lane_, reserved for ladder/server
feature PRs — those all touch the same hotspots (CHANGELOG,
serializer, api*spec, schemas, router, the generated `schema.d.ts`),
so running two of them as open PRs just converts merge-waits into
rebase-waits; keep the main lane strictly serial. Genuinely
\_orthogonal* PRs may run in parallel on suffixed side branches —
`<designated-branch>-docs`, `-client`, `-site`, `-ci` — one coherent
concern each, same gates and review rules, created fresh from
`origin/main` per PR and deleted after merge. The agent manages merge
order; if a side PR unexpectedly collides with the main lane (e.g.
both touch CHANGELOG), merge the main-lane PR first and rebase the
side branch. Never more than one open PR _per lane_, and never use a
side branch to dodge the one-coherent-concern rule.

1. `git fetch origin main && git checkout -B <branch> origin/main`.
2. Implement. Verify with **all four** gates, not just the first:
   `mix precommit` (format, Credo strict, compile warnings-as-errors,
   tests), `mix dialyzer --format short`, `mix sobelow --config` —
   dialyzer and sobelow are not part of the `precommit` alias — and
   the root `npx prettier@3.8.1 --check .` (the CI Prettier job's
   exact command; nothing else covers root markdown, which is how a
   CHANGELOG emphasis-marker escape failed a PR's CI on 2026-07-17).
3. Self-review before opening the PR: run the `code-review` skill
   against the diff (per CONTRIBUTING.md — "is the code
   well-structured, not just lint-clean" is the one thing genuinely
   not machine-checkable). Address what it finds.
4. Add a `CHANGELOG.md` entry under `## [Unreleased]` for anything
   worth recording: user-facing changes, and also audit-driven
   fixes or additions (including pure test-coverage additions) even
   though those aren't user-facing — describe what gap it closed.
5. Commit (`nix develop --command` — see remote container notes
   below); Conventional Commit message. Use `Closes #N` only on the
   commit that actually finishes an issue — GitHub auto-closes on
   merge to `main` from **any** commit referencing the issue, not
   just the PR description, so an earlier PR in a multi-PR issue says
   `Part of #N` instead, or it closes prematurely.
6. Push with `-u`, open the PR, subscribe to its activity.
7. Before merging, all three gate it (no fixed order between them):
   CI green, unresolved review comments addressed, and an
   independent Agent review pass (below) run and addressed.
8. Merge with a merge commit. Restart the branch from `origin/main`
   (`git fetch origin main && git checkout -B <branch> origin/main`),
   **then immediately push that reset** (`git push origin <branch>`)
   before touching anything else — not just when the next commit
   happens to trigger one. Skipping this leaves the remote copy of
   `<branch>` stale (still pointing at the pre-merge tip) until
   whenever a later commit incidentally pushes it forward; any
   session-stop check that diffs local `HEAD` against that stale
   remote ref in between will find the merge commit "unpushed" and
   fire on it — repeatedly, every session, until something happens to
   close the gap. The push here is always a plain fast-forward (the
   old branch tip is an ancestor of the new merge commit), never a
   force-push.

### Independent review

Two review gates, both required, not redundant with each other.
**Self-review** (step 3 above — the `code-review` skill, run by the
implementing session, before the PR opens) catches obvious issues
cheaply, but the session that just wrote the code can't see its own
blind spots. **Independent review** — a fresh Agent spawned with no
context from the implementing session, before merge — is what
catches those instead. Neither is covered by automated tooling
(`mix precommit`, dialyzer, sobelow, CI), which enforces correctness
rules and style, not design quality or "does this test actually test
what it claims to." Tell the independent reviewer to be adversarial
and report ranked findings rather than default to a clean bill of
health — and that **GitHub is read-only for it**: agents can reach
the session's GitHub tools, and an agent that "helpfully" comments
on or edits a PR mid-review corrupts the main session's record of
who wrote what (an unattributable PR-body edit on 2026-07-17 is why
this clause exists; findings come back as the agent's final message,
nowhere else). Skip independent review only for a purely mechanical change
(a dependency bump, a typo fix). **"Docs-only" is not itself a
mechanical category** (owner-stated, 2026-07-12): docs are part of the
product, so any doc change that _authors_ normative content — a SPEC
edit that decides something, an ADR, operating-manual prose — carries
real accuracy / clarity / consistency judgment and gets the
independent pass like any other substantive change. What's exempt is
the _judgment-free_ doc edit: a typo, a dead link, or verbatim
transcription of an already-settled decision. Address what it finds, or note in
the PR why not — don't just run it and move on regardless of what it
says.

**The dismissal bar** (owner-stated 2026-07-12; recalibrated
2026-07-17 after the owner overruled three dismissals): a finding —
the reviewer's or your own observation — is dismissed only when
fixing it costs something real (complexity, risk, genuine scope) or
the finding is factually wrong. "Minor", "small", "rare",
"established wording", and "doesn't need to scale" are **not**
acceptable reasons — the owner's test is "if it's that cheap, name
one good reason to not do it now." When in doubt, fix it. This bar
triggered a full re-audit of every dismissal in the repo's history
(2026-07-17; four earlier dismissals failed the re-test and became
issues), so dismissals recorded before that date don't set precedent
for what's dismissable.

**A conditional disposition ("fix when X lands") must put its trigger
on a GitHub issue** — the issue X's implementer will actually touch,
or a new one — never only in a PR comment or review reply. A
PR-thread deferral is invisible to the future session that lands X:
the RSS item-link fix was deferred in #54 pending public post pages,
the pages landed, and nobody re-found the deferral until a 2026-07-17
audit surfaced it as #341. If the condition isn't worth an issue
comment, the deferral isn't real — fix it now instead.

**"Done" means present in the committed tree, not intended.** Verify
your own claims against the tree before asserting them in a PR body, a
review disposition, or chat — this session claimed a test that was
never written, and the independent reviewer caught it. The same
discipline you demand of reviewers (read the tree, not a memory of it)
applies to your own reporting.

**How each gate is actually run** (practiced; keep it): self-review
is 2–3 parallel _finder_ agents with distinct lenses — correctness,
contract-trace, tests-and-conventions, plus a security lens for any
privileged surface — spawned on the integrated diff _before_ the PR
opens; the independent adversarial reviewer is a _separate_ fresh
agent run on the committed head _before_ merge, told what the finders
already covered so it goes deeper and sideways instead of repeating
them. Every substantive slice's reviewer has found something real, so
the skip-only-for-mechanical rule is load-bearing, not ceremony.

**Reviewers and finders read the committed tree, never a captured
diff alone** — and read whole files around each change, not just the
hunks. But tell them to **pin to the commit SHA, not `HEAD`**
(`git show <sha>`, `git show <sha>:<path>`,
`git diff origin/main...<sha>`): the main session can switch the
working-tree branch out from under an in-flight review — opening a
side-branch PR does exactly this — which moves `HEAD`, and an agent
reading `HEAD` mid-switch silently reviews the wrong tree. Running the
agent in a **worktree** (`isolation: "worktree"`) sidesteps this
entirely. A captured diff alone is worse still — three finder rounds
were once burned on a stale snapshot that no longer matched the
branch. And tell them to VERIFY contracts against source (read the
changeset / context / serializer before trusting any client→server
field mapping) — a build agent once _guessed_ a 422 detail key and the
wrong client mapping shipped.

### Delegating to build agents

When a slice is large enough to hand to a build Agent rather than
implement inline, run it in a **worktree** (`isolation: "worktree"`)
so parallel agents don't collide on the tree. The brief MUST say, in
spirit verbatim: **FIRST ACTION: run `pwd` and confirm you are inside
your assigned worktree — if you are in the shared checkout, STOP; do
NOT spawn sub-agents; GitHub is READ-ONLY for you — never create,
edit, comment on, or label any issue or PR; run every gate inline in
the foreground and
wait for it to finish; do NOT wait on notifications; deliver the
patch plus a commit-message file to the session scratchpad AND bank
a copy into `$(git rev-parse --git-common-dir)/banked-patches/`
(`mkdir -p` it first — that expression resolves to the main
checkout's `.git` from inside any worktree); return raw data as your
final message.** Each clause earns its place: a builder once ran
`git fetch && git reset --hard origin/main` in the shared checkout
before locating its worktree and yanked the session's branch pointer
out from under in-flight edits; three builders backgrounded
`mix precommit` and reported "done" with the gate still running,
making their reports unverified fiction; and the scratchpad has been
wiped mid-session — the banked copy is what survived that (only
pushed commits survive the container itself). A new session's agents
write to a _fresh_ scratchpad, never a path carried over from a
prior session's notes. A fresh worktree may first need
`mix local.hex --force && mix deps.get`, `pnpm install`, and — when
plain `nix develop` fails on the worktree — `nix develop "path:$PWD"`.

**Model selection for delegation** (owner-approved, 2026-07-17):
creation can be cheaper; verification must not be. A builder whose
brief fully enumerates the changes (files, functions, expected tests)
runs on Sonnet; finders, adversarial reviewers, design work, and
orchestration stay on the top model tier. Escalate a build
back to the top tier when its gates fail repeatedly or the slice
carries authorization-critical control flow — those briefs can't be
fully enumerated, which is the tell that Sonnet is the wrong tier.

Never trust a build agent's committed generated artifact (above all
`schema.d.ts`): regenerate it on the integrated branch and require a
byte-identical diff — that check has caught real drift. Recipe in the
remote-container notes below.

### Session mechanics (subscriptions, check-ins, reply scans)

These keep an autonomous session from stalling; none is delivered to
you automatically, so they are your responsibility to arm.

- **After opening any PR: subscribe to its activity AND arm a
  `send_later` self check-in — a few minutes out, not 15–20**
  (owner-stated, 2026-07-12). Webhooks deliver CI _failures_ and
  comments but never CI _success_ — without the check-in a green PR
  just sits unmerged — and CI here is fast, so err toward too-frequent:
  prefer one wasted check over a green PR idling unmerged. Re-arm the
  check-in each time it fires until the PR is merged or closed.
  Recurring triggers bound to a prior session die with it; a new
  session arms its own. **Never `delete_trigger` a stale check-in**
  (owner-stated, 2026-07-12: each delete needs owner approval, so it's
  pure churn). `send_later` check-ins are _one-shot_ — they auto-disable
  after firing once — so when a PR merges before its check-in fires, the
  straggler just fires once and you no-op it ("stale, already merged");
  that's cheaper than an approval-gated delete, and harmless. Don't
  delete-and-re-arm to "refresh" a check-in for a new head either
  (however the head moved — a force-push, an ordinary push, or
  `update_pull_request_branch`): a check-in acts on the PR's _current_
  head regardless of the SHA in its text, so the existing one already
  does the right thing. The only legitimate `delete_trigger` is when the
  owner tells you to stop watching a PR mid-flight. Prefer per-PR
  one-shot check-ins over one generic recurring trigger: the recurring
  one fires on a fixed schedule even with no open PR (visible noise),
  is less responsive than a check-in tuned to expected CI time, and
  still needs disabling when idle.
- **Owner-reply scans** (hourly during owner-away stretches): GitHub
  comments are not pushed to the session. Scan from the _previous
  scan's actual timestamp_, not a fixed window — a fixed window missed
  an owner reply once — and read assigned / `decision` issues'
  comments directly, since that's where owner input lands.
- **Side-branch PRs need `update_pull_request_branch` + a CI re-run
  after any main-lane merge** before branch protection will let them
  merge (their checks go stale against the new `main`).

### Architecture audits

Distinct from the line-level quality/elegance/DRY sweeps already run
periodically (which ask "is each piece internally consistent"): a
separate, dedicated architecture-level review asking "is the
system's shape still right" — module cohesion, context boundaries,
the inter-context dependency graph, god-modules accreting unrelated
responsibility, whether a context split made early in the project
still holds as it's grown. File findings as GitHub issues the same
way line-level audits do, and file the audit itself as a GitHub issue
labeled `architecture-audit` so the cadence is checkable without
relying on memory.

**Trigger**: search issues **including closed ones**
(`label:architecture-audit` with `state:all`, sorted by creation
date — a completed audit's tracking issue gets closed, so an
open-only search always reads as "none has ever run"). Run one now
if that search returns nothing. After that, re-run whenever either
is true: 90 days have passed since the most recent one (by that same
search) was opened, or a full round of line-level audit fixes has
just been completed — whichever comes first.

### Task & state tracking

GitHub Issues are the only durable, cross-session source of truth.
The in-session task list (TaskCreate/TaskUpdate) is scratch for
staying organized within the current session only — it does not
persist, and a new session must not assume it exists. If something
needs to survive past this session, it goes in a GitHub issue, a
CHANGELOG entry, an ADR, or this file — never only the task list or
the conversation.

- Work from open GitHub issues, not a separate backlog doc.
  Implementation choices are yours to make; product-shaping choices
  (pricing, naming, new scope) go to a GitHub issue assigned to the
  owner with concrete options and a recommendation (label `decision`).
- Issues that are explicitly the owner's own action (real-machine
  testing, human review passes, infra deploys, final naming/business
  calls) are read, never resolved unilaterally — comment status
  deltas, don't close them yourself (label `action`).
- Keep the owner assigned on a GitHub issue only while it's genuinely
  waiting on their input — a `decision` or `action` issue with an open
  question or an unchecked owner-only step. Unassign once that's
  resolved (the issue itself can stay open for tracking); implementation
  work, including sequencing already-approved backlog items, is never
  a reason to keep the owner assigned.

#### Issue hygiene (continuous, not a one-off pass)

If issues are the async communication channel — and per the section
below, during owner-away stretches they're the _only_ one — a messy
issue tracker isn't cosmetic, it's a broken channel. Treat hygiene as
standing maintenance, not a task to schedule once:

- **The total open-issue count is a metric the owner watches**
  (owner-stressed twice, 2026-07-09). Net growth needs genuine
  justification: before filing a new issue, ask whether it folds into
  an existing one, and pair filing with closing — a work session that
  only ever adds issues is a hygiene smell. Closing what a merge
  completed is part of landing the merge, not a separate chore.
  Refined 2026-07-17: what the owner wants to see is **turnover and
  an eventually-shrinking pile** — steady closes prove progress even
  while audits mint new work, but once the audit backlog clears,
  sessions must trend net-negative. **No milestones** (owner-declined
  explicitly): a milestone is extra management that grows stale; the
  open list itself, kept honest, is the tracker. Audit swarms fold
  findings into existing issues wherever possible and close their
  trackers promptly rather than minting freely.
- **Stale/superseded issues get closed, not left open.** If a
  reprioritization, a merged PR, or new scope makes an issue's ask
  moot, close it with a comment explaining why (`state_reason:
not_planned` or `completed` as fits) — don't let it linger as noise
  future sessions have to re-triage.
- **Labels are load-bearing, keep them accurate.** Four axes, not one
  catch-all — `enhancement` is not a default, it's one specific type
  among several:
  - **Type** (exactly one): `bug` (real correctness/security defect),
    `enhancement` (genuinely new user-facing capability — not audit
    cleanup, not a doc fix, not a test gap), `tech-debt` (refactor,
    cleanup, DRY, context-boundary fix — no user-facing behavior
    change), `documentation` (doc-only fix), `tests` (test-coverage
    addition/cleanup only). Before applying `enhancement`, ask "is
    this actually a new capability, or cleanup wearing the default
    label because that's what was easiest to reach for." Exception
    (owner-confirmed on #236): issues that are _purely_ owner
    planning/action items — a `decision` or `action` with no
    implementation of its own (e.g. a business-model call, a
    real-machine test, a naming decision) — carry no Type label; the
    Type axis classifies work on the product, and these aren't that.
  - **Process** (zero or more): `decision`/`action` only while
    genuinely blocking (see above — unassign and consider dropping
    the label once resolved, not just unassigning); `roadmap` on
    confirmed future-scope items.
  - **Provenance** (zero or one): `architecture-audit` /
    `quality-audit` tag which audit produced a finding — including on
    every sub-issue a tracker spawns, not just the tracker itself.
  - **Component** (zero or one, as the product grows multi-surface):
    `api` (JSON API surface), `web-client` (Svelte PWA client). Don't
    add a new component/area axis casually — this repo is small
    enough that per-context labels (`area:feed`, `area:events`, …)
    would fragment the tracker for no payoff; revisit only if the
    open-issue count grows past roughly 100.
    Re-check labels when an issue's status changes, not just at
    creation — a `decision` issue whose question got answered in a
    comment should lose the label promptly, not linger looking like it's
    still blocking.
- **Titles carry no hand-rolled label echoes.** Never prefix a title
  with `[decision]`, `[bug]`, or similar — the label already says
  that; a manual prefix duplicates it inconsistently (some issues get
  one, most don't) and rots the moment the label changes without the
  title following. Plain, sentence-case, descriptive title; let labels
  do labeling.
- **Umbrella/tracker issues use GitHub-native sub-issues, not just
  prose.** If an issue spawns findings or sub-tasks as their own
  issues (an audit tracker, a phase umbrella), link them with the
  `sub_issue_write` API (`method: "add"`, using each child's internal
  `id` from a full-object fetch like `search_issues` — not its
  `number`), the same way #33/#74/#90 do. A tracker with prose-only
  "#122, #123, …" references but no native links is exactly the kind
  of inconsistency this section exists to catch — check every new
  tracker issue for this before considering it done.
- **Consistent structure**: a one-line "What" summary, then context/
  reasoning, then a checklist or "Files touched" if implementation-
  relevant. Match the shape of nearby issues rather than improvising
  a new format per issue — a reader skimming the tracker shouldn't
  have to re-parse a new structure every time.
- **Prioritization shifts get reflected in the tracker itself**, not
  just remembered — if a class of issues (e.g. LiveView-template-only
  cosmetic findings) drops in priority because of a bigger strategic
  shift (e.g. the LiveView→Svelte transition), say so on those issues
  rather than leaving them looking equally urgent as everything else.
- **Bulk relabeling/rewriting pre-existing issues needs the owner to
  name the batch, not just approve the general idea.** The session's
  own write-permission classifier blocks mass modification of issues
  it didn't create this session when the justification is "the owner
  said clean up issues generally" — and it keeps blocking even if you
  switch from one Agent-delegated call to many individual direct
  calls; it recognizes that as the same pattern and explicitly says so
  rather than letting it through. Don't grind against this — it's not
  a bug to route around (see the tool's own guidance: attempting a
  workaround once denied is out of bounds). Instead: do the design/
  analysis work, compute the exact before/after for every affected
  issue, and post it as a single comment on one issue (create a
  tracking issue if none fits) asking the owner to approve the named
  batch. One new/existing issue commented on is a single, clearly-
  scoped write and won't trip the same block; many pre-existing issues
  silently rewritten in a script-like sequence will. An explicit
  "go ahead" from the owner is consent for that batch, not standing
  permission for whatever comes later — if unrelated work happens in
  between (a branch/PR fix, in the case that prompted this note) and
  you're not sure the original sign-off still applies, ask again
  rather than assume it does.

### Product scope changes

SPEC.md §16's "explicit non-goals" list is the canonical, durable
record of what's out of scope — not this file, not a conversation.
The moment the owner adds, removes, or narrows a non-goal, or states
any other scope decision, it gets written into SPEC.md (and a GitHub
issue tracking the now-in-scope item, cross-referenced; an ADR too if
it reverses or amends a prior architectural decision) in the same
turn — before continuing whatever else was in progress. A scope
decision that only lives in conversation is exactly the kind of thing
a long, compacted session loses; "the owner said this once and I
forgot" is not an acceptable failure mode. (This rule exists because
that failure mode happened: native apps were listed as an explicit
non-goal despite the owner wanting them built.)

Corollary: don't treat the non-goals list as static background
reading. If a session's work touches it, or the owner's request
brushes up against something listed there, read the whole list back
and ask explicitly whether it's still accurate — the cost of asking
is one message; the cost of silently building, or silently refusing
to build, something the owner already changed their mind about is
much higher.

### Owner interaction

- Renovate runs Mondays 07:00 CPH; non-major dependency PRs automerge
  when checks pass, majors wait for the owner.
- Message the owner only at milestones or when genuinely blocked.
- **When the owner asks you to make a decision, always give a
  recommendation — not a menu** (owner-stated, 2026-07-12). Lead with
  the option you'd pick — clearly flagged as your recommendation — and
  the reasoning; alternatives come after. This holds for a `decision`
  issue and an in-chat question alike.
- **Anything asking the owner to decide leads with a TL;DR-ask
  block** (owner-prompted, 2026-07-17: "I have no idea what to read
  or what to reply to"): **Decision needed** in one sentence, **My
  recommendation** in one sentence, then **Reply with:** the literal
  short answers that unblock the work ("Go" / "Keep gate" / …) —
  answer tokens for the recommendation above, not a menu of undecided
  options — with an explicit note that reading the full analysis is
  optional. The
  long-form reasoning goes _below_ that block, never above it. A
  decision post the owner can't answer in one line from the first
  screen is a defect in the post, not in the owner's attention.
- Surface a process/convention question when there's no precedent in
  this file or the linked docs, rather than picking one silently —
  and once answered, write the answer down here so it isn't asked
  twice.
- **Always check `issue_read`'s `get_comments` before asking the
  owner something in chat that might already be answered on the
  issue itself** — GitHub comments are a real channel the owner uses
  independently of chat, and re-asking something already answered
  there wastes their attention and looks like the process isn't
  paying attention.
- **The owner is _always_ assigned to any issue awaiting their
  input — no exceptions** (owner-stated, 2026-07-10, second time the
  pattern slipped). Their assigned-issues list is the one overview
  they maintain; a question posed in an unassigned issue's comment is
  invisible to it and effectively unasked. The assignment happens the
  moment the question is posed, not later; unassign when the input
  arrives (per the hygiene rule above). This applies to _any_ form of
  owner input — decisions, reviews, steers, restyle passes — not just
  `decision`-labeled issues.
- **Anything that needs the owner to decide or review before it's
  final goes in a GitHub _issue_ (assigned to owner, `decision`
  label) — never in a PR body or PR comment** (owner-stated,
  2026-07-10). A PR can merge before the owner reads it, and once
  merged the decision point is gone with no time-bound for them to
  catch it; an issue has no such deadline, so it's the only channel
  that guarantees the owner sees the question on their own schedule.
  A PR body describes the change and non-blocking status — it is not
  a place to park questions the owner must answer. If a design
  choice in a PR genuinely needs owner sign-off, file the issue,
  cross-reference it from the PR as non-blocking, and proceed on the
  most reasonable option (the issue makes the call visible and
  overridable). This holds in sync mode too, not just async
  stretches.

#### Async-only stretches (owner watching GitHub, not chat)

The owner periodically goes fully async — explicitly says so, and
means it literally: no chat replies coming, GitHub (issues, PRs,
labels, comments) is the only channel they're checking, for a defined
stretch (e.g. a week away). During one of these stretches:

- Keep working autonomously. Do not pause a task waiting on a chat
  reply that will not come — that's a stall, not caution.
- All status, findings, and decisions get written to GitHub, never
  left only in chat — chat may not be read again for the whole
  stretch. Match the channel to the content: status/findings can go
  in PR descriptions, issue comments, or the CHANGELOG, but anything
  needing the owner's decision goes in a `decision` _issue_, never a
  PR body (see the Owner-interaction rule above — a PR can merge
  before it's read).
- For a `decision`-labeled issue that would normally block on the
  owner: if truly blocking, pick the most reasonable option, say so
  explicitly in an issue comment with the reasoning (so it's a
  visible, overridable call, not a silent one), and keep moving —
  don't stall the way sync mode would tolerate.
- Resume normal "surface and wait" behavior the moment the owner
  posts anything in chat again — async-only is a temporary mode the
  owner opts into, not a permanent default.

### Continuous process critique

Continuously and critically evaluate the process itself, not just
the product — unprompted, as work happens, on every abstraction
level: orchestration (solo vs. delegating to an Agent, vs. a
Workflow swarm — pick per task, don't default), tracking (see above),
prioritization (what's being deferred and why, said out loud rather
than assumed), owner-interaction cadence, and whether what was just
decided is written down somewhere durable (this file, an ADR, a
CHANGELOG entry) or only lives in the conversation. Give opinions and
concrete optimization proposals as they come up, not only when asked.

**This is as much about the _product_ as the process** (owner-stated,
2026-07-12). Be an active collaborator, not a passive executor:
critique what we're _building_ — the UX, the model, the feature set —
and propose concrete product improvements and new ideas unprompted, the
same way you critique the workflow. Route them by the owner-interaction
rules: a product gap or proposal is a GitHub issue (mind the
open-issue count — pair with closing); a design or scope question that
needs the owner's call is an assigned `decision` issue; a passing
observation can ride the relevant PR or issue. The bar is to leave both
the product and the process better than you found them, every session.

**Persist process changes automatically, without being asked.** The
moment a standing decision or convention is made — whether the owner
states it directly, or you determine it yourself while critiquing the
process per the paragraph above — write it into this file (or a
CHANGELOG entry, ADR, or GitHub issue, whichever fits) in the same
session, before moving on. Don't wait for an explicit "write this
down" — a decision that only lives in one conversation is not
persisted, and the next session has no way to know it was made. This
instruction is itself an example: it exists here because it was
asked for once and must never need to be asked for again.

## Kammer: remote container notes (Claude Code on the web)

- Nix may be **absent entirely** on a fresh container. Restore it
  with the official installer: create the `nixbld` group and the
  `nixbld1`..`nixbld10` users first, then run
  `sh nix-install.sh --no-daemon` (the installer script fetched from
  nixos.org). Binaries land at `/root/.nix-profile/bin` — so
  `export PATH=/root/.nix-profile/bin:$PATH` in every shell
  (`/nix/var/nix/profiles/default/bin` may be absent until the
  reinstall; afterwards both resolve to the same store path), and
  `export NIX_SSL_CERT_FILE=/root/.ccr/ca-bundle.crt` so Nix trusts
  the network proxy's CA. The `nixbld1`..`nixbld10` build users are
  created with
  `useradd -r -g nixbld -G nixbld -M -N -s "$(command -v nologin)" nixbldN`.
  The single-user install ships with flakes **off**, so `nix develop`
  errors (`experimental Nix feature 'nix-command' is disabled`) until
  you enable them once:
  `mkdir -p /root/.config/nix && printf 'experimental-features = nix-command flakes\n' > /root/.config/nix/nix.conf`.
- Node and pnpm are pre-installed at `/opt/node22/bin` (not via Nix):
  `export PATH=/opt/node22/bin:$PATH` and
  `export NODE_EXTRA_CA_CERTS=/root/.ccr/ca-bundle.crt` for the client
  gates and the root `npx prettier@3.8.1 --check .` (the version CI
  pins in `ci.yml` and the `Makefile`'s `format` target both use —
  keep all three in lockstep). Run client gates from
  absolute paths / `pnpm --dir clients/web ...`; **never `cd`
  mid-chain** — the Bash tool's cwd persists between calls, so a stray
  `cd` leaks into the next command and has caused repeated failed runs.
- The proxy blocks GitHub release downloads, so `mdex_native`'s
  precompiled NIF download 403s at compile time. Fix:
  `export MDEX_NATIVE_BUILD=1` to build the NIF from source (cargo
  is preinstalled at `/root/.cargo/bin`).
- `pg_ctlcluster 16 main start` after container restarts (a stale
  pid is normal — Postgres also drops mid-session sometimes, same
  fix). A fresh container may additionally need
  `su postgres -c "psql -c \"ALTER USER postgres PASSWORD 'postgres'\""`
  once, so the app's dev config can authenticate.
- Commit and push inside `nix develop --command` (git hooks need `mix`
  on `PATH`). Committer identity: `Claude <noreply@anthropic.com>`.
- The Playwright e2e gate (`scripts/e2e.sh`) needs both a browser and
  `mix` on PATH, so run it inside `nix develop` with
  `export CHROMIUM_BIN=/opt/pw-browsers/chromium` (the config reads
  `CHROMIUM_BIN`; the container pre-installs Chromium there — never
  `playwright install`). It is **destructive to `kammer_dev`** (drops
  and recreates it), so don't point it at a database you care about.
- Regenerate `schema.d.ts` after any API-file change and require a
  byte-identical diff, using the **project-pinned tools exactly as
  written here** — five independent agents have confirmed the
  alternatives are traps. From repo root: `rm -f /tmp/spec.json`
  first (a compile failure leaves the old spec behind, and the next
  step happily regenerates from it), then
  `nix develop --command bash -c 'mix run --no-start -e "File.write!(\"/tmp/spec.json\", Jason.encode!(KammerWeb.ApiSpec.spec()))"'`
  then, with node on PATH,
  `clients/web/node_modules/.bin/openapi-typescript /tmp/spec.json -o clients/web/src/lib/api/schema.d.ts`
  then
  `pnpm --dir clients/web exec prettier --write src/lib/api/schema.d.ts`,
  then confirm `git diff --quiet clients/web/src/lib/api/schema.d.ts`.
  (The two node steps mirror `clients/web`'s `generate:api` script,
  spelled out with explicit pinned paths — if that script's pipeline
  ever changes, sync this recipe.)
  Do **not** substitute a root-level `npx prettier` for the last
  step: the root `.prettierignore` excludes `clients/web/`, so it
  exits 0 having formatted _nothing_, and the unformatted output
  reads as a false ~30k-line drift. Floating `npx` tool versions
  differ from the client's pinned ones for the same false-drift
  effect. After the pinned recipe, a non-empty diff is real: the
  committed copy was hand-edited or stale — never ship it.
- Screenshots: `docs/screenshots/` gets a single batch refresh before
  v1 (owner-stated, 2026-07-12) — just note UI changes in the PR and
  let that batch cover them; no per-PR regen, and don't block a merge
  on it. The old LiveView-driven Screenshots workflow died with the
  #187 cut; the PWA-era replacement rides the docs overhaul (#189) and
  the visual-regression net (#286). (The historical "CSS cannot be
  built in this container" constraint went with the server asset
  pipeline — the Svelte client's build works here, as the e2e gate
  proves.)
- If GitHub tool access shows as disconnected, it needs
  re-authorization from the owner (`claude mcp` / `/mcp` — cannot be
  done from an agent session); local git still works without it.

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->

## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you _must_ bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if valid? do
        params = Map.put(params, :verified_at, DateTime.utc_now())
      end

      # VALID: we rebind the result of the `if` to a new variable
      params =
        if valid? do
          Map.put(params, :verified_at, DateTime.utc_now())
        else
          params
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **Every test earns its place** (owner-mandated; full statement in
  [CONVENTIONS.md](CONVENTIONS.md) §Tests): the suite is a portfolio
  piece — lean, elegant, well-structured. A test that asserts nothing,
  restates the framework, duplicates coverage, or exists as ceremony
  is a defect. One sharp test over three overlapping ones; coverage is
  a floor, never a target. Both review gates check this on every new
  or changed test.
- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

  - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages

<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->

## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        get "/users", UserController, :index
      end

  the route would point to the `AppWeb.Admin.UserController` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it

<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->

## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed when rendering the response, ie a serializer that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programmatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files, so the correct timestamp and conventions are applied

<!-- phoenix:ecto-end -->

<!-- usage-rules-end -->
