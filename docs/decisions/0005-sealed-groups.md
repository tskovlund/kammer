# ADR 0005: Sealed groups

## Context

Community admins have full override on all groups — necessary for moderation,
wrong for genuinely private circles (a band's internal planning, a board's
personnel discussions) that still want to live inside the community.

## Decision

A group may set the **sealed flag at creation time only; it is irreversible**.
Sealed groups grant community admins no access of any kind; their sole power
is whole-group deletion. _(Amended 2026-07-17, below: for sealed private
groups that power is operator-level, not an API power.)_ The UI states
honestly: "Sealed: hidden from community admins. The server operator can
still technically access all data."

## Consequences

- Sealing is a creation-time contract, so members can trust it never flips.
- Precisely: sealing reduces a community admin to _ordinary community
  member_ rights on that group (a sealed community-visible group is still
  visible to them as members), plus whole-group deletion. The property
  suite encodes exactly this.
- Deletion-without-inspection remains, so a community can still expel a
  rogue sealed group. _(Scope narrowed by the 2026-07-17 amendment
  below: the API expulsion path remains only where the admin can see
  the group — sealed non-private groups; for a sealed private group,
  expulsion is an operator action.)_
- The rule set is enforced only in `Kammer.Authorization` and carries a
  dedicated (property-based) test suite.
- We never imply protection from the instance operator — no E2EE in v1.

## Amendment (2026-07-17): sealed private groups vs. the no-oracle gate

#224 folded "you can't view this group" into the same 404 as "no such
group" on the group endpoint itself — the one carrying DELETE — and
#339 extends that fold to every slug-addressed API surface; both apply
to community admins too. For a sealed **private** group, this makes
the admin's sole remaining power (deletion) unreachable over the API:
the gate hides the group before the delete authorization (which would
say yes) can run. The two rules genuinely conflict.

Decision (owner, issue #347): **the no-oracle gate wins.** Expelling a
sealed private group from outside — the community-admin path — is an
operator-level action (console/DB), not an API power; the group's own
owner keeps the ordinary delete, being a member who can see it. An
admin-reachable delete on a group they provably cannot see would
itself be an existence oracle, and "delete what you cannot inspect" is
a footgun, not a feature. Sealed _non-private_ groups are unaffected:
admins can see those (as ordinary members for community-visible ones,
like anyone for public ones), so deletion still works over the API.

## Amendment (2026-07-17, issue #345): sealed and the tokenless public surfaces

The original decision scoped sealing to _admin_ override; anonymous
visitor visibility was deliberately untouched, so a sealed
`public_listed` group kept its RSS/Atom feed, newsletter
subscriptions, and guest RSVP/comment flows. #345's unification ends
that: **sealed now also excludes a group from every tokenless public
surface** — the public JSON API, the feeds, newsletter subscribe
_and_ delivery, and the guest write flows all gate on one predicate
(`Authorization.publicly_readable?/1`), because serving anonymous
flows and emails whose every link 404s on the public pages was
incoherent, not a feature. Member and admin access is unchanged —
authenticated surfaces never consulted this predicate, so the
original decision's scope (and the #347 amendment above) stand.
