# ADR 0004: Exactly four group visibility presets

## Context

Per-object ACLs are flexible, unauditable, and routinely misconfigured.
Communities need to reason at a glance about who can see a group.

## Decision

Groups have exactly four visibility presets: `private`, `community`,
`public_link` (unlisted), `public_listed`. No custom visibility, no
per-user exceptions.

## Consequences

- Every visibility question reduces to one enum check in the central
  authorization module — testable exhaustively.
- The file-visibility invariant (ADR 0009) is expressible and enforceable
  because scope visibility is a total order.
- Edge-case wishes ("visible to these two people only") are deliberately
  unsupported; that's what private groups are for.
