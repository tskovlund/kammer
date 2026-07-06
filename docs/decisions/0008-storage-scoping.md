# ADR 0008: File storage scoping — community and group spaces

## Context

Files need a home that maps to how communities think: "the band's files",
"the association's files" — not a global bucket with permissions bolted on.

## Decision

Two file scopes only: the **community space** and **per-group spaces**, each
with a shallow folder tree, search, and auto-collections. Feed attachments
default into the owning group's space ("Feed uploads" folder); deleting a
post never deletes the file. A `Storage` behaviour abstracts local-disk
(default) and S3-compatible backends. Files are first-class DB entities so
a `document` type can slot in later.

## Consequences

- Every file has exactly one owning scope; permission questions inherit from
  that scope (ADR 0009).
- Storage backends are swappable per instance without schema changes.
- Instance-level storage policy (`unmetered` or `quota`) attaches cleanly to
  spaces.
