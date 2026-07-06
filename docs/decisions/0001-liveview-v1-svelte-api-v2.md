# ADR 0001: LiveView for v1, Svelte over a JSON API for v2

## Context

We need a v1 UI quickly, but the long-term product is multi-instance: one
client holding sessions on several Kammer instances, merging calendars and
feeds client-side. A server-rendered UI cannot do that; maintaining two UIs
forever is a trap.

## Decision

Phoenix LiveView is the **v1 vehicle**: all domain logic lives in Phoenix
contexts, the LiveView layer stays thin. v2 adds a JSON API over the same
contexts and a Svelte PWA built multi-instance-capable from day one. LiveView
is then frozen and retired — no permanent dual-UI maintenance.

## Consequences

- Contexts are the permanent asset; nothing business-critical may live in
  LiveView modules or templates.
- No server-side "home instance" aggregation or inter-instance sync protocol
  is ever needed; the v2 client is a session-holder, not a proxy.
- ICS and RSS already provide standards-based cross-instance merging in v1.
