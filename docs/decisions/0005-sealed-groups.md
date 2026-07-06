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
- Deletion-without-inspection remains, so a community can still expel a
  rogue sealed group.
- The rule set is enforced only in `Kammer.Authorization` and carries a
  dedicated (property-based) test suite.
- We never imply protection from the instance operator — no E2EE in v1.
