# RFC 0003: Per-group feature toggles

**Status:** Accepted (ADR 0016) as designed (#21) · **Decides:** how groups show only the tools they
actually use, ahead of the collaborative track (issue #17).

## Context

A group is Kammer's universal primitive: a "page" is a group with
admin-only posting, a board is a sealed group, a project is a group
with an end date in its future. The owner's direction (issue #17) adds
a collaborative track — assignments, signup slots, decisions — and
with it a risk: every group sprouting every tool turns a calm product
into a dashboard of unused tabs. The fix is structural, and it should
land _before_ the first toggleable feature does.

## Proposed design

- **A `features` set on the group** (e.g. `["feed", "events", "files"]`
  today; `"tasks"` etc. join as they ship). Group admins edit it in
  group settings; sensible defaults per creation (all current features
  on, future features off — nothing changes for existing groups).
- **Navigation renders only enabled features.** Disabling hides the
  tab and stops new writes; it never deletes data. Re-enabling brings
  the content back exactly as it was (archive semantics, per SPEC's
  institutional-memory stance — the feature toggle is a visibility
  switch, not a destructor).
- **Authorization sits above toggles:** a disabled feature returns the
  same "not found" surface as an unauthorized one; the toggle check
  lives in the authorization module's context so there is exactly one
  gate (no scattered `if feature_enabled?` in templates).
- **The feed is not toggleable** in v1 of this design: a group with no
  feed is a different product concept (pure calendar/file-share), and
  none of the current or planned features work without the group
  having a "wall". Revisit only with a concrete use case.

## Consequences

- The collaborative track (tasks, slots, decisions, rotations) ships
  OFF by default per group — new features never add noise to groups
  that don't opt in. This is the mechanism that lets Kammer serve the
  public-community path and the Basecamp-ish collaboration path from
  one primitive without bloating either.
- One migration (a column with a default), one settings section, one
  authorization clause — deliberately boring.
- Feature toggles are per **group**, not per community or instance:
  the calm-surface decision belongs to the people living in the group.
