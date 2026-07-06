# ADR 0006: No algorithmic feed, ever

## Context

Engagement-optimized feeds are the core mechanism of the platforms Kammer
replaces — and the main thing communities flee.

## Decision

Feeds are **strictly chronological plus pinned posts**. No ranking, no
recommendations, no "you may have missed". An optional user-selected
activity view (sorted by latest comment, forum-style) is the only alternate
ordering. This is a product principle and a marketing line, not a default.

## Consequences

- No ranking infrastructure, no engagement metrics collection.
- Important announcements are handled explicitly: pins, acknowledgment-
  required posts, notification escalation for broadcast groups.
- Feature requests for smart feeds are answered by this ADR.
