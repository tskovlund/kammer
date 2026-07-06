# ADR 0015: Cross-community Home — a read-only chronological lens

## Context

One account belongs to many communities, but each community was its
own world behind the switcher. RFC 0002 designed a merged Home;
the open question was sealed-group visibility in it.

## Decision

Build Home as RFC 0002 specifies: upcoming events and recent activity
across every group the user belongs to, across communities, strictly
chronological, read-only (a lens, not a place — every item is one the
user could already see by navigating; authorization is untouched).
Context-level union query; no denormalized timeline until real usage
demands it.

Sealed groups: **option 1** (issue #21) — sealed-group activity shows
in the member's own Home, controlled by a per-group "show in Home"
toggle **defaulting ON**, presented prominently enough that members
know it exists and can turn it off.

## Consequences

- Home becomes the natural landing screen (PWA now, the v2 client's
  default later — where per-instance Homes merge client-side).
- The toggle's prominence is a design requirement, not a nicety: the
  discretion story for sealed groups depends on members knowing the
  switch exists.
- Notification "highlights" defaults get revisited once Home absorbs
  part of the what-did-I-miss job.
