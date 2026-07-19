defmodule Kammer.Repo.Migrations.MoveCommunityFileSpaceToGroupsTest do
  @moduledoc """
  The #187 data migration that rehomes the (LiveView-only, now
  unreachable) community file space onto a group. It carries real
  branching — reachable-group preference (each of its three disqualifiers
  discriminated), an oldest-first fallback, the transient-upload
  exclusion, per-community scoping, and the group-less skip — and moves
  personal-data-bearing rows, so it earns a test (#308). Runs the real
  `up/0` under the SQL sandbox via `Kammer.MigrationHelper`.
  """

  use Kammer.DataCase, async: true

  import Kammer.CommunitiesFixtures
  import Kammer.MigrationHelper

  alias Kammer.Files.FileEntry
  alias Kammer.Files.Folder
  alias Kammer.Files.StoredFile
  alias Kammer.Repo
  alias Kammer.Repo.Migrations.MoveCommunityFileSpaceToGroups

  # Migration files aren't compiled into the app (the migrator loads them
  # at runtime), so load this one to reference its module and run the real
  # `up/0`. Idempotent — `require_file` no-ops if already loaded.
  Code.require_file("priv/repo/migrations/20260713061337_move_community_file_space_to_groups.exs")

  # A fixed epoch so `inserted_at` ordering is deterministic, not
  # dependent on wall-clock creation order within the test.
  @epoch ~U[2026-01-01 00:00:00Z]

  # The migration ranks groups on visibility, features, archived_at, and
  # inserted_at, but group_fixture pins none of them controllably. So
  # seed_group writes every override *after* the fixture via
  # Ecto.Changeset.change/2, which bypasses the changeset cast and sets
  # the fields (inserted_at included) directly — the only way to pin
  # archived_at/features, which create_changeset doesn't even cast.
  defp seed_group(community, seconds_old, overrides \\ %{}) do
    community
    |> group_fixture()
    |> Ecto.Changeset.change(Map.put(overrides, :inserted_at, DateTime.add(@epoch, seconds_old)))
    |> Repo.update!()
  end

  # A community-space folder + its file entry + a stored version, all with
  # `group_id: nil` — the pre-migration state the removed LiveView left.
  defp seed_community_space(community, opts \\ []) do
    folder = Repo.insert!(%Folder{community_id: community.id, group_id: nil, name: "Docs"})

    entry =
      Repo.insert!(%FileEntry{
        community_id: community.id,
        group_id: nil,
        folder_id: folder.id,
        name: "budget.pdf"
      })

    stored =
      Repo.insert!(%StoredFile{
        community_id: community.id,
        group_id: nil,
        folder_id: folder.id,
        file_entry_id: entry.id,
        filename: "budget.pdf",
        content_type: "application/pdf",
        byte_size: 12,
        storage_key: "key-#{System.unique_integer([:positive])}",
        transient_expires_at: opts[:transient_expires_at]
      })

    %{folder: folder, entry: entry, stored: stored}
  end

  defp reload_group_id(row), do: Repo.reload!(row).group_id

  test "rehomes community-space rows onto the oldest group that can surface them" do
    {community, _owner} = community_with_owner_fixture()

    # Baseline attributes that make a group reachable for files. Each
    # older competitor flips exactly *one* of them, so every conjunct of
    # the migration's flag (not private, not archived, files-on) is pinned
    # by a group whose sole disqualifier is that one — drop any conjunct
    # and that group wins. All are older than `reachable`, so it can only
    # win on the flag, never on age. (Attributes are explicit, not relying
    # on schema defaults, so a default change can't silently un-pin one.)
    reachable_attrs = %{
      visibility: :community,
      features: [:feed, :events, :files],
      archived_at: nil
    }

    _older_private = seed_group(community, 0, %{reachable_attrs | visibility: :private})
    _older_archived = seed_group(community, 5, %{reachable_attrs | archived_at: @epoch})
    _older_files_off = seed_group(community, 7, %{reachable_attrs | features: [:feed, :events]})
    reachable = seed_group(community, 10, reachable_attrs)

    %{folder: folder, entry: entry, stored: stored} = seed_community_space(community)

    transient =
      %{stored: t} =
      seed_community_space(community, transient_expires_at: ~U[2027-01-01 00:00:00Z])

    run_migration(MoveCommunityFileSpaceToGroups)

    # Folder, entry, and non-transient stored file all move — together —
    # to the reachable group, not either older unreachable one.
    assert reload_group_id(folder) == reachable.id
    assert reload_group_id(entry) == reachable.id
    assert reload_group_id(stored) == reachable.id

    # The transient upload's stored file is left where it was — it's
    # ephemeral, not part of the file space. Its folder and entry share
    # the community, so they still move: the exclusion is on stored_files
    # only (the folders/file_entries UPDATEs carry no transient clause).
    assert reload_group_id(t) == nil
    assert reload_group_id(transient.folder) == reachable.id
    assert reload_group_id(transient.entry) == reachable.id
  end

  test "falls back to the community's oldest group when none can surface the files" do
    {community, _owner} = community_with_owner_fixture()
    # Every group is unreachable for files — private, then files-off — so
    # the migration rehomes into the oldest anyway (reachable once an admin
    # flips a toggle, better than the stranded group_id IS NULL state).
    oldest_private = seed_group(community, 0, %{visibility: :private})
    _newer_files_off = seed_group(community, 10, %{features: [:feed, :events]})

    %{folder: folder} = seed_community_space(community)

    run_migration(MoveCommunityFileSpaceToGroups)

    assert reload_group_id(folder) == oldest_private.id
  end

  test "leaves a group-less community's files untouched — nowhere to move them" do
    {community, _owner} = community_with_owner_fixture()
    %{folder: folder, entry: entry, stored: stored} = seed_community_space(community)

    run_migration(MoveCommunityFileSpaceToGroups)

    assert reload_group_id(folder) == nil
    assert reload_group_id(entry) == nil
    assert reload_group_id(stored) == nil
  end

  test "keeps each community's files within its own group — no cross-community leak" do
    {community_a, _owner} = community_with_owner_fixture()
    {community_b, _owner} = community_with_owner_fixture()
    group_a = seed_group(community_a, 0)
    group_b = seed_group(community_b, 0)

    %{folder: folder_a} = seed_community_space(community_a)
    %{folder: folder_b} = seed_community_space(community_b)

    run_migration(MoveCommunityFileSpaceToGroups)

    # `DISTINCT ON (community_id)` and the `community_id`-scoped join must
    # keep each community's files on *its own* group — never the other's.
    assert reload_group_id(folder_a) == group_a.id
    assert reload_group_id(folder_b) == group_b.id
  end
end
