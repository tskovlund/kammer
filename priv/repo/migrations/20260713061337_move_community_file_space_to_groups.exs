defmodule Kammer.Repo.Migrations.MoveCommunityFileSpaceToGroups do
  @moduledoc """
  Rehomes the community file space onto a group in each community
  (issue #187).

  The community-level file library was a LiveView-only surface
  (`FileLive.Index :community`); it was never given an API twin (the file
  library API is group-scoped), so with LiveView removed there is no way
  to reach it. Its contents — folders, file entries, and their stored
  versions, all identified by `group_id IS NULL` within a community —
  are moved into one of the community's groups so they stay reachable and
  their file-space rows stay referentially consistent (a stored file, its
  entry, and its folder move together). The folder subtree is preserved:
  only the owning scope changes, `parent_folder_id` links are untouched,
  and community-space folders carry no `system_key`, so the
  `folders (group_id, system_key)` unique index cannot collide.

  ## Target group

  The community space had no feature gate and no group visibility — any
  community member could read it (`Kammer.Files` gates a `%Community{}`
  scope open). A group file library, by contrast, sits behind the group's
  `:files` toggle and `visibility`. So the target is the **oldest group
  that can actually surface the files**: not archived, not `:private`,
  and with `:files` enabled. Only if no such group exists does it fall
  back to the community's oldest group overall (deterministic tie-break
  on id), so every community with a group still gets a target rather than
  leaving the files stranded.

  Even the preferred target is one group's file library, not the old
  community-wide space: reachability is restored, but the audience is now
  whoever can read that group (a `:community`-visible group is the norm).
  A community whose *only* groups are private / files-off / archived has
  its files rehomed into the oldest such group — reachable to an admin
  who flips the toggle or visibility, which is strictly better than the
  unreachable `group_id IS NULL` state the removed LiveView left behind.

  Communities with no group are left untouched — there is nowhere to move
  their files to. Transient uploads and feed attachments are unaffected:
  both always carry a `group_id` already (see `Kammer.Files`).

  Irreversible: the original community-space membership is not recorded
  once moved, so `down/0` is a no-op (rollback must not fail).
  """

  use Ecto.Migration

  # The rehoming target for each community: prefer the oldest group that
  # can actually surface the files (not archived, not `:private`, `:files`
  # enabled), falling back to the community's oldest group overall. The
  # ranking flag is never NULL — `archived_at` is only tested via `IS NULL`
  # (null-safe regardless of the column's nullability), and `visibility`
  # and `features` are both NOT NULL — so `DESC` puts qualifying groups
  # first with no NULL-ordering ambiguity.
  @first_group """
  SELECT DISTINCT ON (community_id) community_id, id AS group_id
  FROM groups
  ORDER BY
    community_id,
    (archived_at IS NULL AND visibility <> 'private' AND 'files' = ANY(features)) DESC,
    inserted_at ASC,
    id ASC
  """

  def up do
    execute("""
    WITH first_group AS (#{@first_group})
    UPDATE folders AS f
    SET group_id = fg.group_id
    FROM first_group AS fg
    WHERE f.community_id = fg.community_id
      AND f.group_id IS NULL
    """)

    execute("""
    WITH first_group AS (#{@first_group})
    UPDATE file_entries AS e
    SET group_id = fg.group_id
    FROM first_group AS fg
    WHERE e.community_id = fg.community_id
      AND e.group_id IS NULL
    """)

    execute("""
    WITH first_group AS (#{@first_group})
    UPDATE stored_files AS s
    SET group_id = fg.group_id
    FROM first_group AS fg
    WHERE s.community_id = fg.community_id
      AND s.group_id IS NULL
      AND s.transient_expires_at IS NULL
    """)
  end

  def down, do: :ok
end
