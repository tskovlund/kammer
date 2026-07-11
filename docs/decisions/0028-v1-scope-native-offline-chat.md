# ADR 0028: V1 includes native apps, the offline write queue, and chat/DMs; managed hosting comes later

## Context

ADR 0012 excluded native apps and offline content from the first
release; ADR 0022 corrected the record to "committed roadmap" — still
sequenced after v1. Chat/DMs (#136) sat on the same roadmap list with
an open owner decision attached. The agent's working release framing
treated all three as post-V1.

The owner has now made the release-scope call directly (chat,
2026-07-11): that framing was wrong. These are not post-V1 extras —
the product is not finished in its first version without them.

## Decision

**V1 — "the product, complete in its first version" — includes:**

- **Native apps** (Kotlin/Android, Swift/iOS): API siblings of the
  Svelte client per ADR 0012/0025's own framing (#131).
- **The offline write queue**: full offline support beyond the
  shipped read-only offline reading — queued posts/comments/RSVPs
  that sync when connectivity returns (#137).
- **Chat/DMs** (#136): needs its own design pass (data model,
  realtime transport, retention) before build.

**Managed hosting / Kammer Cloud is explicitly post-V1** (owner, same
call): the business-model track (#22) and its storage-billing
dependency stay roadmap.

ADR 0012's **sequencing stands unchanged**: PWA first, the LiveView
cut (#187) before native work begins. What this ADR changes is the
finish line, not the order of the race.

## Consequences

- SPEC.md §16 records the V1 scope; #131/#136/#137 shed their
  roadmap framing and become V1 backlog.
- The #203 satellite repos (`kammer-android`, `kammer-ios`) become
  V1-era infrastructure rather than future placeholders.
- E2EE (#132) stays post-V1 roadmap (its shape depends on chat/DMs
  landing first; the owner has not pulled it forward).
- The `1.0` tag waits for these three, not for the LiveView cut —
  pre-1.0 `0.x` versioning (ADR 0025) covers the interim releases.
