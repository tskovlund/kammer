defmodule Kammer.ModerationFixtures do
  @moduledoc """
  Test helpers for moderation state (SPEC §11).
  """

  alias Kammer.Moderation.InstanceBan
  alias Kammer.Repo

  @doc """
  Records an instance ban on an email directly — no operator, no purge.
  For tests that only need the ban row present: the full-lockout gates
  (#377) read the ban list, not `Kammer.Moderation.ban_instance/3`'s whole
  orchestration, and inserting the row lets a test ban an account whose
  live credentials should deliberately survive (to isolate a single gate).
  """
  def instance_ban_fixture(email) when is_binary(email) do
    Repo.insert!(InstanceBan.changeset(%InstanceBan{}, %{email: email}))
  end
end
