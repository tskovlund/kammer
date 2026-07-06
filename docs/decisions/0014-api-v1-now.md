# ADR 0014: JSON API v1 starts now, churn accepted

## Context

RFC 0001 proposed gating the v2 JSON API behind one real community
season, to avoid freezing contracts around unvalidated domain models.
The owner overrode the gate (issue #20): the API is needed for season
one, and versioned APIs exist precisely to absorb breaking changes.

## Decision

Build the JSON API v1 immediately, shaped as RFC 0001 specifies: plain
JSON over REST (`/api/v1`), URL-versioned and additive-only within a
version, device tokens minted through the magic-link flow, cursor
pagination (newest-first), one error envelope with stable codes,
capability discovery at `GET /api/v1/instance`, Phoenix Channels for
realtime. Every route resolves through `Kammer.Authorization` — the
API adds transport, never policy.

Breaking model changes before 1.0 are handled by version bumps
(`/api/v2`, deprecation window), not by holding the work.

## Consequences

- The Svelte PWA (ADR 0001) and native apps (ADR 0012) unblock in that
  order once the API stabilizes.
- Contexts remain the permanent asset; API controllers/JSON views stay
  thin and are tested against the same authorization property suites.
- The cost accepted knowingly: early clients may chase version bumps.
