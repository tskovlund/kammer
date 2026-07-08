# ADR 0022: Native apps and offline support are committed roadmap

## Context

ADR 0012 established PWA-first sequencing for good reasons (app-store
friction, per-platform build cost, native apps locking the roadmap
before the v2 API exists) and, in doing so, scoped two things as
v1-only exclusions: native apps ("become API siblings of the v2
Svelte client") and offline content support ("no offline content
support in v1 — explicit non-goal"). SPEC.md's non-goals list (§16)
flattened both into permanent exclusions with no version qualifier,
overselling what ADR 0012 actually decided. The owner confirmed
(2026-07-08, issues #131, #137) both are committed roadmap, not
"maybe someday."

## Decision

Native apps (Kotlin/Android, Swift/iOS) and full offline support
(beyond v1's app-shell-only service worker caching) are in scope,
sequenced after the JSON API (#30) and Svelte PWA (#32) — native apps
because they're API siblings of the Svelte client per ADR 0012's own
original framing, offline support because it needs the same
client-side session/sync model the Svelte client establishes. This
amends SPEC.md's non-goals list; it does not reverse ADR 0012's
PWA-before-native sequencing, which stands.

## Consequences

- SPEC.md §16 lists both under "confirmed future roadmap," not
  "explicit non-goals."
- Building and submitting a native iOS app requires Xcode, which
  requires macOS — there's no way around that even with cross-platform
  frameworks. Noted in #131 as a toolchain fact, not a blocker.
- Scope, platform choice, and timeline for both stay open, refined in
  their tracking issues (#131, #137) as the API/Svelte work lands.
