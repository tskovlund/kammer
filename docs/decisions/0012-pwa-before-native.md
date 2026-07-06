# ADR 0012: PWA before native apps

## Context

Most users are on phones; app stores demand accounts, review cycles, fees,
and per-platform builds a small open-source project cannot sustain — and
native apps would lock the roadmap before the v2 API exists.

## Decision

v1 ships as an installable **PWA**: manifest, service worker with app-shell
caching only (content stays online-only), Web Push via VAPID. Native apps
become API siblings of the v2 Svelte client, not LiveView wrappers.

## Consequences

- One codebase covers desktop and mobile in v1; Lighthouse installability is
  part of the quality bar.
- iOS Web Push limitations are documented honestly rather than papered over.
- No offline content support in v1 — explicit non-goal.
