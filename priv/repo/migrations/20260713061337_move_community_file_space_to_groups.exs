defmodule Kammer.Repo.Migrations.MoveCommunityFileSpaceToGroups do
  @moduledoc """
  Rehomes the community file space onto each community's oldest group
  (issue #187).

  The community-level file library was a LiveView-only surface
  (`FileLive.Index :community`); it was never given an API twin (the file
  library API is group-scoped), so with LiveView removed there is no way
  to reach it. Its contents — folders, file entries, and their stored
  versions, all identified by `group_id IS NULL` within a community —
  are moved into the community's first group so they stay reachable and
  their file-space rows stay referentially consistent (a stored file, its
  entry, and its folder move together). The folder subtree is preserved:
  only the owning scope changes, `parent_folder_id` links are untouched,
  and community-space folders carry no `system_key`, so the
  `folders (group_id, system_key)` unique index cannot collide.

  Communities with no group are left untouched — there is nowhere to move
  their files to. Transient uploads and feed attachments are unaffected:
  both always carry a `group_id` already (see `Kammer.Files`).

  Irreversible: the original community-space membership is not recorded
  once moved, so `down/0` is a no-op (rollback must not fail).
  """

  use Ecto.Migration

  # The oldest group of each community (deterministic tie-break on id).
  @first_group """
  SELECT DISTINCT ON (community_id) community_id, id AS group_id
  FROM groups
  ORDER BY community_id, inserted_at ASC, id ASC
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
