# ADR 0016: Per-group feature toggles

## Context

The group is Kammer's universal primitive, and the collaborative track
(issue #17) will multiply its tools. Without a structural answer,
every group sprouts every tab and the calm surface dies. RFC 0003
designed the answer; the owner accepted it as designed (issue #21).

## Decision

A `features` set on each group; group admins toggle in settings.
Navigation renders only enabled features. Disabling hides and stops
new writes but never deletes — re-enabling restores everything
(institutional memory, as with archiving). The enabled-check lives in
`Kammer.Authorization` so there is exactly one gate, and a disabled
feature is indistinguishable from an unauthorized one. The feed is not
toggleable. New features ship OFF by default for existing groups.

## Consequences

- The collaborative track lands without adding noise to groups that
  don't opt in — the mechanism that lets one primitive serve both the
  public-community and the collaboration path.
- One migration (column with default), one settings section, one
  authorization clause — deliberately boring.
- Toggling is per group, not per community/instance: the calm-surface
  decision belongs to the people living in the group.
