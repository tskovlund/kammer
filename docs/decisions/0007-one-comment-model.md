# ADR 0007: One comment model everywhere

## Context

Deep threading fragments small-community conversations; per-group threading
options fragment the product and multiply UI/notification/permission paths.

## Decision

Exactly one threading model everywhere: **comment → replies, one level**,
chronological, collapsed beyond ~3 replies. Events use the same comment
engine as posts. No per-group or per-post threading variants.

## Consequences

- One rendering component, one notification path, one moderation surface.
- Future configurable comment mechanics arrive only via group *type
  templates* (an explicit v1 non-goal), never as raw per-group switches.
