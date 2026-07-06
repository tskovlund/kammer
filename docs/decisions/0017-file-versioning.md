# ADR 0017: File versioning — same name, same place, new version

## Context

Issue #15 (owner-decided): versioned files with viewer-visible
history, unlimited default retention with admin caps, write
permission to replace, and a proper schema split rather than a
pointer-chain workaround.

## Decision

A `file_entries` table carries the logical file (name, place,
permissions target, `current_version_id`); every version remains a
`stored_files` row with the entry's scope columns denormalized, so
blob access checks, quotas, and contribution stats need no special
cases. **Uploading a file with the same name into the same folder
appends a version to the existing entry** — the Drive-like semantics
users already expect, requiring no new upload UI. Listings show only
current versions; feed attachments and transient uploads stay
entry-less (artifacts of posts, not documents). Version order uses a
monotonic `version_seq` (second-granular timestamps tie under rapid
uploads). Deleting the file removes the entry and every version;
deleting a single version (own uploads or file managers, never the
last) repoints the entry when needed. Retention (`version_retention`
on groups and communities, NULL = unlimited) prunes oldest on upload.

## Consequences

- Existing UI kept working through the migration: rows are still
  stored_files (the current versions), history is additive.
- Old-version downloads flow through the existing file controller;
  a property test pins version visibility ≡ current-version
  visibility.
- The API's file endpoints (issue #30) will expose entries + versions
  from this same model.
