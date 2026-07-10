# ADR 0027: The configuration layer — no bare magic operational values

Date: 2026-07-10
Status: accepted

## Context

Kammer is meant to be a serious, self-hostable product, not a
single-operator toy. An audit of `lib/` and `config/` (issue #234)
found operational behaviour scattered as bare literals: rate limits,
token lifetimes, retention windows, quotas, pagination caps, an Oban
schedule, and a handful of outright bugs in the config story — a
`min_client_version` knob documented as settable but wired to no env
var, an endpoint body-length ceiling whose `.env.example` note tells
operators to hand-edit source, a `"Kammer"` product-name default
re-typed at eight call sites. Some of these an operator legitimately
needs to tune; some must never change; today they look alike, and a
self-hoster can't tell which is which or reach the ones they need.

User-facing _copy_ is already solved — it goes through Gettext (EN/DA)
and is out of scope here. This ADR is about operational/behavioural
values.

## Decision

Every operational value lives in exactly one of three tiers, and no
bare magic operational value is left inline.

1. **Instance settings** — runtime-changeable, per-instance,
   admin-editable. DB-backed `Kammer.Communities.InstanceSettings`
   plus the admin UI (already exists). For values an operator changes
   _while running_, per instance: instance name, default locale,
   community-creation policy, storage policy. Env may overlay these at
   boot (`Setup` reads `INSTANCE_NAME` etc.), env always winning.

2. **Deployment config** — set once at boot, from the environment.
   Env var → `config/runtime.exs` → **validated at boot** (bounds and
   format checked, raise on invalid — the #98 pattern) → documented in
   `.env.example`. One consistent, grouped accessor pattern, not
   scattered `Application.get_env` calls with re-typed defaults. This
   is the tier that _grows_: operator-tunable operational values a
   self-hoster reasonably reaches for — throughput/policy rate limits,
   session and API-device token lifetimes, content and transient-upload
   retention windows — each with a safe default, an env override, and
   validated bounds (loosen within reason, never disable).

3. **Named constants** — genuinely never-configurable. An explicit
   module attribute with a comment stating _why_ it is fixed. Crypto
   parameters, protocol constants, token byte lengths, and —
   deliberately — the **anti-abuse/security rate limits**.

**The rule (enforced by both review gates via CONVENTIONS.md):** no
bare magic operational value. Each is either a named constant with a
stated rationale, or a first-class configurable setting in tier 1 or 2.

**Security vs. policy rate limits.** The `Kammer.RateLimit` limits
split by intent, not uniformly:

- **Anti-abuse/security backstops stay tier 3, fixed** — magic-link,
  login-code, signup, setup, email-change, and invite-issuance limits.
  A security limit behind a runtime config knob is a footgun (ADR
  0026's setup-rate-limit stance; `rate_limit.ex`'s own comment): an
  operator loosening it to dodge a support ticket quietly reopens a
  brute-force or email-relay vector, and these numbers are tied to
  threat models (the login-code budget to the 40-bit code space), not
  to instance size.
- **Throughput/policy limits become tier-2 configurable** — post,
  comment, and upload creation rates, and the `@everyone` mention
  cadence. These are spam/UX trade-offs a large community's operator
  legitimately tunes (cf. Discourse, Mastodon), bounds-validated so
  they can be loosened within reason but not disabled.

This split honours both standing owner statements — a configurable
product for the knobs operators tune, a fixed floor for the security
backstops. The owner confirmed this split, the tier-2/tier-3
classification, and the `RATE_LIMIT_*`-prefixed naming convention for
the rate-limit vars on issue #234 (2026-07-10).

## Consequences

- Issue #234's audit is the classification worklist. Migration is
  **incremental** — interleaved between parity-ladder rungs, not one
  big-bang PR — starting with the tier-2 rate limits and retention
  windows and the outright config bugs (`min_client_version`,
  endpoint ceiling, `product_name` accessor).
- Both review gates (self-review and independent review) check the
  no-bare-magic-value rule, because it is written into CONVENTIONS.md;
  automated tooling can't judge "should this be configurable," only
  the rule's presence keeps it honest.
- A few values are bigger lifts and get their own sub-task rather than
  folding into the sweep: Oban queue concurrency and cron schedule are
  compile-time (`config.exs`) today and moving them to `runtime.exs`
  plus choosing the env-var shape is a small design of its own.
- The easy extractions are done as of #234's first tier-2 PR: the
  tier-2 rate limits (post/comment/upload creation, `@everyone`
  mentions), session/API-device/change-email token lifetimes, content
  and transient-upload retention windows, and guest confirm/manage
  link lifetimes are all `Kammer.Config`-backed and env-overridable.
  Deferred as tier-3, with no issue asking otherwise: `media.ex` image
  widths — changing widths doesn't regenerate existing thumbnails, a
  backfill hazard, not a free knob, until a backfill job exists to pair
  it with.
- The tier-2 documentation falls out as the configuration reference for
  the docs site (#188).

## References

Issue #234. Relates to ADR 0026 (the security-limit-as-footgun stance
this generalises) and the #98 boot-time config-validation pattern.
User-facing copy stays with Gettext, separate from this layer.
