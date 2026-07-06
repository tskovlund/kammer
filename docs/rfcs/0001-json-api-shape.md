# RFC 0001: JSON API shape (v2)

**Status:** Accepted (ADR 0014) — owner overrode the season gate: “implement v1 now”, churn accepted (#20) · **Decides:** the contract the v2 API freezes, and the
gate that must open before freezing it.

## Context

ADR 0001 already stages the architecture: LiveView is the v1 vehicle,
domain logic lives in contexts, and v2 adds a JSON API over those same
contexts for a multi-instance Svelte client (ADR 0012 makes native apps
API siblings of that client). What is _not_ yet decided is the API's
concrete shape — and shape is the expensive part, because a published
API is a compatibility promise to clients we don't control.

## Gate (proposed): no API freeze before one real season

The API is cut **after** a real community has run on v1 long enough to
stress the domain models (the same criterion as 1.0). Freezing contracts
around unvalidated models converts future learning into breaking
changes. Until then this RFC evolves freely.

## Proposed shape

- **Style:** plain JSON over REST-ish resource routes (`/api/v1/...`).
  No GraphQL: the client set is known (our own clients), the query
  flexibility isn't needed, and REST keeps the authorization module the
  single choke point per route. No JSON:API envelope ceremony — flat
  objects, `snake_case`, UUIDs as strings, UTC ISO 8601 timestamps.
- **Versioning:** URL-versioned (`/api/v1`), additive-only within a
  version. Breaking change ⇒ `/api/v2` with a deprecation window. The
  version is the whole contract — no per-endpoint versioning.
- **Auth:** long-lived revocable **device tokens** minted through the
  existing magic-link flow (the API sibling of the sessions/devices
  page). `Authorization: Bearer`. Scoped per instance — the
  multi-instance client holds one token per instance, matching ADR
  0001's session-holder model. No OAuth provider role in v1 of the API;
  third-party clients can come later behind the same token model.
- **Authorization:** every route resolves through `Kammer.Authorization`
  exactly like LiveView does — the API adds transport, never policy.
  Sealed-group and visibility invariants are enforced in one place.
- **Pagination:** cursor-based (`?after=<opaque>`), newest-first,
  matching the chronological product stance. No offset pagination.
- **Errors:** one envelope — `{"error": {"code": "...", "message": "..."}}`
  with stable machine-readable codes; HTTP status carries the class.
- **Capabilities:** `GET /api/v1/instance` returns instance metadata,
  enabled features, and limits, so clients discover rather than assume
  (this is also what makes cross-instance clients graceful when
  instances run different versions).
- **Realtime:** Phoenix Channels on the same socket infrastructure,
  same topics the LiveView PubSub already uses; the API client
  subscribes rather than polls.

## Consequences

- The contexts stay the permanent asset; the API layer is thin
  controllers + JSON views, testable against the same property suites
  that guard authorization today.
- The freeze gate means the Svelte client work cannot start before the
  season proof — by design, not by accident.
- ICS/RSS remain the standards-based read-only API in the meantime.
