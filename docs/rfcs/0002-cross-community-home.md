# RFC 0002: Cross-community home (single instance)

**Status:** Proposed · **Decides:** what a user's merged view across their
communities means, and how sealed groups behave in it.

## Context

One account can belong to many communities on an instance (SPEC §3),
but today each community is its own world behind the switcher. The
owner's direction: a user should be able to see one merged home —
upcoming events and fresh activity across everything they belong to —
_and_ still enter any single community. Cross-**instance** merging is
already answered by ADR 0001 (the v2 client merges client-side); this
RFC is only about one instance, where it is a query and UI problem,
not a protocol.

## Proposed design

- **A "Home" view above the community switcher**: upcoming events
  (agenda, merged, timezone-aware) and recent activity (chronological,
  newest-first — the no-algorithm stance applies doubly here) drawn
  from every group the user is a member of, across all their
  communities. Each item is labeled with its community + group and
  links into it.
- **Merging is read-only.** Posting, RSVPing, commenting happen in the
  group's own context. Home is a lens, not a place — this keeps
  authorization exactly as it is (every item shown is one the user
  could already see by navigating).
- **Implementation:** a context-level query unioning the user's member
  groups across communities; no denormalized timeline table until real
  usage proves the union query insufficient. LiveView renders it like
  any feed; it never caches across users.

## The sealed-group question (owner decision required)

Sealed groups exist so that _others_ cannot see in. The member can, so
authorization-wise sealed content **may** appear in that member's own
merged home. But there is a social dimension: a phone screen on a table
showing "Bestyrelsen: 3 new posts" leaks the _existence_ of activity to
shoulder-surfers, which is exactly the audience sealed groups guard
against in practice.

Options:

1. **Include, with a per-group "show in Home" toggle defaulting ON.**
   Simple mental model; the board can turn itself off.
2. **Include, toggle defaulting OFF for sealed groups only.**
   (Recommended.) Sealed groups are the discretion feature; discretion
   should be the default posture everywhere they surface. One line of
   settings UI, no new concepts.
3. Exclude sealed groups from Home entirely — safest, but punishes the
   most engaged members (board members check the board group most).

## Consequences

- Home becomes the natural PWA landing screen and, later, the v2
  client's default view — the client-side cross-instance merge (ADR 0001) then merges _Homes_, one per instance, into one screen.
- Notification "highlights" defaults likely want revisiting once Home
  exists (Home absorbs some of the "what did I miss" job).
