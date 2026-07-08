# ADR 0023: No ActivityPub — client-side multi-instance aggregation instead

## Context

ActivityPub (the fediverse protocol behind Mastodon, PeerTube, Lemmy)
was raised as a candidate for cross-instance reach and considered
directly (2026-07-08) rather than left as an unexamined non-goal.

ActivityPub solves public, many-to-many content distribution across a
loosely-trusted network of independently-run servers: content is
pushed to and cached on remote servers so their local users can see
it, with visibility enforced by social convention between operators,
not real access control. It has real, well-documented costs even for
that use case: push-based fan-out that scales poorly for popular
accounts, coarse whole-server moderation with no fine-grained trust
model, weak identity portability (an account's history lives and dies
with its home server), and poor cross-network discovery.

Kammer's actual want, per SPEC.md §3, is different in kind: a
community lives on exactly one instance (the Discord model — no
cross-instance community concept exists or is planned), and a single
member's aggregated view across the several communities/instances
*they* belong to is a personal client-side concern, not a
content-distribution one.

## Decision

No ActivityPub adoption. The already-decided multi-instance Svelte
client (ADR 0001) — a client-side session-holder authenticating to
each instance a user is an actual member of, merging views (calendar,
feed) locally — covers the actual want without any of federation's
costs: no server-to-server push, no cross-instance moderation surface
(each instance only ever serves its own real members), no identity
portability question (identity per instance is just that instance's
normal login). ICS and RSS remain the standards-based answer for
read-only cross-instance reach.

## Consequences

- SPEC.md §16's non-goals list keeps ActivityPub, now with reasoning
  instead of a bare mention.
- If a future community wants public fediverse reach (e.g. publishing
  a community's public events to Mastodon), that's a narrower,
  separate question from adopting ActivityPub as Kammer's cross-instance
  architecture — revisit only if asked for explicitly.
