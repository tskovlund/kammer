# ADR 0005: Sealed groups

## Context

Community admins have full override on all groups — necessary for moderation,
wrong for genuinely private circles (a band's internal planning, a board's
personnel discussions) that still want to live inside the community.

## Decision

A group may set the **sealed flag at creation time only; it is irreversible**.
Sealed groups grant community admins no access of any kind; their sole power
is whole-group deletion. The UI states honestly: "Sealed: hidden from
community admins. The server operator can still technically access all data."

## Consequences

- Sealing is a creation-time contract, so members can trust it never flips.
- Precisely: sealing reduces a community admin to _ordinary community
  member_ rights on that group (a sealed community-visible group is still
  visible to them as members), plus whole-group deletion. The property
  suite encodes exactly this.
- Deletion-without-inspection remains, so a community can still expel a
  rogue sealed group. _(Scope narrowed by the 2026-07-17 amendment
  below: this now holds only for sealed community-visible groups.)_
- The rule set is enforced only in `Kammer.Authorization` and carries a
  dedicated (property-based) test suite.
- We never imply protection from the instance operator — no E2EE in v1.

## Amendment (2026-07-17): sealed private groups vs. the no-oracle gate

#224/#339 folded "you can't view this group" into the same 404 as "no
such group" on every slug-addressed API surface — for community admins
too. For a sealed **private** group, that makes the admin's sole
remaining power (deletion) unreachable over the API: the gate hides the
group before the delete authorization (which would say yes) can run.
The two rules genuinely conflict.

Decision (owner, issue #347): **the no-oracle gate wins.** Deleting a
sealed private group is an operator-level action (console/DB), not an
API power. An admin-reachable delete on a group they provably cannot
see would itself be an existence oracle, and "delete what you cannot
inspect" is a footgun, not a feature. Sealed _community-visible_ groups
are unaffected: admins see them as ordinary members, and deletion still
works over the API.
