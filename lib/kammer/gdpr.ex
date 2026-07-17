defmodule Kammer.Gdpr do
  @moduledoc """
  Data rights (SPEC §12): self-serve export and account erasure.

  **Export** gathers everything the instance stores about one person —
  profile, memberships, posts, comments, RSVPs, signups, votes,
  availability answers — as one JSON document, plus every file they
  uploaded, into a zip built in a temporary directory and streamed by
  the controller.

  **Erasure** is a waitlist-promotion pass plus one `Repo.delete/1`,
  atomically: the schema was designed for the delete — personal rows
  (memberships, RSVPs, claims, votes, sessions, notifications) cascade
  away, while authored content is anonymized to "Deleted user" by
  `nilify_all` foreign keys — and the promotion pass (issue #329)
  hands the person's freed future-event seats to their waitlists
  instead of leaving them idle. Files the person uploaded into shared
  spaces remain (they belong to the group's shared memory); their
  uploader becomes anonymous.
  """

  import Ecto.Query, warn: false

  alias Kammer.Accounts.User
  alias Kammer.Events
  alias Kammer.Groups.GroupMembership
  alias Kammer.Repo
  alias Kammer.Storage

  @doc """
  Builds the export zip in a fresh temporary directory; returns the
  zip's path. The caller streams it and may delete the directory
  afterwards.
  """
  @spec export(User.t()) :: {:ok, Path.t()} | {:error, term()}
  def export(%User{} = user) do
    workdir =
      Path.join(
        System.tmp_dir!(),
        "kammer-export-#{user.id}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workdir)

    data_path = Path.join(workdir, "data.json")
    File.write!(data_path, user |> collect() |> Jason.encode!(pretty: true))

    file_entries = export_files(user, workdir)

    zip_path = Path.join(workdir, "kammer-export.zip")

    entries =
      [{~c"data.json", File.read!(data_path)}] ++
        Enum.map(file_entries, fn {name, path} -> {String.to_charlist(name), File.read!(path)} end)

    case :zip.create(String.to_charlist(zip_path), entries) do
      {:ok, _zip} -> {:ok, zip_path}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes the account. The schema does the SPEC §12 work: identity
  gone, personal rows cascaded, authored content anonymized. Freed
  event seats promote their waitlists first (issue #329) — the FK
  cascade would silently delete the RSVP rows anyway, but without the
  promotion pass every seat this person held would sit idle until an
  arbitrary later capacity write self-healed it.
  """
  @spec delete_account(User.t()) :: :ok
  def delete_account(%User{} = user) do
    group_ids =
      Repo.all(
        from(membership in GroupMembership,
          where: membership.user_id == ^user.id,
          select: membership.group_id
        )
      )

    {:ok, _} =
      Repo.transact(fn ->
        Events.drop_member_future_rsvps_in_groups(user.id, group_ids)
        Repo.delete!(user)
        {:ok, :ok}
      end)

    :ok
  end

  defp collect(user) do
    %{
      exported_at: DateTime.utc_now(:second),
      profile: %{
        email: user.email,
        display_name: user.display_name,
        locale: user.locale,
        timezone: user.timezone,
        inserted_at: user.inserted_at
      },
      community_memberships:
        rows(
          from(membership in Kammer.Communities.CommunityMembership,
            join: community in assoc(membership, :community),
            where: membership.user_id == ^user.id,
            select: %{
              community: community.name,
              role: membership.role,
              since: membership.inserted_at
            }
          )
        ),
      group_memberships:
        rows(
          from(membership in Kammer.Groups.GroupMembership,
            join: group in assoc(membership, :group),
            where: membership.user_id == ^user.id,
            select: %{group: group.name, role: membership.role, since: membership.inserted_at}
          )
        ),
      posts:
        rows(
          from(post in Kammer.Feed.Post,
            where: post.author_user_id == ^user.id,
            select: %{body_markdown: post.body_markdown, published_at: post.published_at}
          )
        ),
      comments:
        rows(
          from(comment in Kammer.Feed.Comment,
            where: comment.author_user_id == ^user.id,
            select: %{body_markdown: comment.body_markdown, inserted_at: comment.inserted_at}
          )
        ),
      reactions:
        rows(
          from(reaction in Kammer.Feed.Reaction,
            where: reaction.user_id == ^user.id,
            select: %{emoji: reaction.emoji, inserted_at: reaction.inserted_at}
          )
        ),
      poll_votes:
        rows(
          from(vote in Kammer.Feed.PollVote,
            join: option in assoc(vote, :option),
            where: vote.user_id == ^user.id,
            select: %{option: option.text, inserted_at: vote.inserted_at}
          )
        ),
      event_rsvps:
        rows(
          from(rsvp in Kammer.Events.EventRsvp,
            join: event in assoc(rsvp, :event),
            where: rsvp.user_id == ^user.id,
            select: %{event: event.title, status: rsvp.status, updated_at: rsvp.updated_at}
          )
        ),
      slot_claims:
        rows(
          from(claim in Kammer.Events.SlotClaim,
            join: slot in assoc(claim, :slot),
            where: claim.user_id == ^user.id,
            select: %{slot: slot.title, inserted_at: claim.inserted_at}
          )
        ),
      assignment_claims:
        rows(
          from(claim in Kammer.Assignments.AssignmentClaim,
            join: assignment in assoc(claim, :assignment),
            where: claim.user_id == ^user.id,
            select: %{assignment: assignment.title, inserted_at: claim.inserted_at}
          )
        ),
      availability_responses:
        rows(
          from(response in Kammer.Availability.AvailabilityResponse,
            join: option in assoc(response, :option),
            where: response.user_id == ^user.id,
            select: %{starts_at: option.starts_at, answer: response.answer}
          )
        )
    }
  end

  defp rows(query), do: Repo.all(query)

  # Every file the person uploaded, fetched through the storage adapter
  # (works for local and S3 alike via path_for).
  defp export_files(user, workdir) do
    files_dir = Path.join(workdir, "files")
    File.mkdir_p!(files_dir)

    uploads =
      Repo.all(
        from(stored_file in Kammer.Files.StoredFile,
          where: stored_file.uploader_user_id == ^user.id,
          select: %{
            id: stored_file.id,
            filename: stored_file.filename,
            key: stored_file.storage_key
          }
        )
      )

    for upload <- uploads,
        {:ok, source_path} <- [Storage.path_for(upload.key)],
        File.exists?(source_path) do
      safe_name = "files/#{upload.id}-#{Path.basename(upload.filename)}"
      target = Path.join(workdir, safe_name)
      File.cp!(source_path, target)
      {safe_name, target}
    end
  end
end
