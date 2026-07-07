defmodule Kammer.Moderation do
  @moduledoc """
  Reports and bans (SPEC §11). Anyone who can see a post or comment
  can report it; the queue serves community admins (everything) and
  group moderators (their groups). Resolving removes the content
  through the same moderation functions the UI already uses; bans are
  keyed on email and enforced at the single membership choke-point
  (`Communities.add_member/3`).
  """

  import Ecto.Query, warn: false

  alias Kammer.Accounts.User
  alias Kammer.Audit
  alias Kammer.Authorization
  alias Kammer.Communities.Community
  alias Kammer.Feed
  alias Kammer.Feed.Comment
  alias Kammer.Feed.Post
  alias Kammer.Groups.Group
  alias Kammer.Moderation.CommunityBan
  alias Kammer.Moderation.InstanceBan
  alias Kammer.Moderation.Report
  alias Kammer.Repo

  ## Reports

  @doc """
  Files a report on a post. Anyone who may view the host group may
  report; one open report per person per subject.
  """
  @spec report_post(User.t(), Post.t(), String.t()) ::
          {:ok, Report.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def report_post(%User{} = reporter, %Post{} = post, reason) do
    group = Repo.get!(Group, post.group_id)

    with :ok <- Authorization.authorize(reporter, :view_group, group) do
      %Report{
        community_id: group.community_id,
        reporter_user_id: reporter.id,
        post_id: post.id
      }
      |> Report.changeset(%{reason: reason})
      |> Repo.insert()
    end
  end

  @doc """
  Files a report on a comment (same rules as posts).
  """
  @spec report_comment(User.t(), Comment.t(), String.t()) ::
          {:ok, Report.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def report_comment(%User{} = reporter, %Comment{} = comment, reason) do
    group = comment_group(comment)

    with :ok <- Authorization.authorize(reporter, :view_group, group) do
      %Report{
        community_id: group.community_id,
        reporter_user_id: reporter.id,
        comment_id: comment.id
      }
      |> Report.changeset(%{reason: reason})
      |> Repo.insert()
    end
  end

  @doc """
  The open queue the actor may act on: community admins see the whole
  community, group moderators the reports whose subject lives in a
  group they moderate. Everyone else sees nothing.
  """
  @spec list_open_reports(User.t() | nil, Community.t()) :: [Report.t()]
  def list_open_reports(nil, %Community{}), do: []

  def list_open_reports(%User{} = actor, %Community{} = community) do
    reports =
      Repo.all(
        from(report in Report,
          where: report.community_id == ^community.id and report.status == :open,
          order_by: [asc: report.inserted_at],
          preload: [
            :reporter_user,
            post: [:author_user, :group],
            comment: [:author_user, post: :group, event: :group, assignment: :group]
          ]
        )
      )

    if Authorization.can?(actor, :manage_community, community) do
      reports
    else
      Enum.filter(reports, fn report ->
        group = report_group(report)
        group != nil and Authorization.can?(actor, :moderate_group, group)
      end)
    end
  end

  @doc """
  Dismisses a report — the content stays.
  """
  @spec dismiss_report(User.t(), Report.t()) ::
          {:ok, Report.t()} | {:error, :unauthorized}
  def dismiss_report(%User{} = actor, %Report{status: :open} = report) do
    with :ok <- authorize_on_report(actor, report) do
      close_report(report, actor, :dismissed)
    end
  end

  def dismiss_report(%User{}, %Report{}), do: {:error, :unauthorized}

  @doc """
  Resolves a report by removing the content — hard delete for posts,
  the shared engine's delete for comments — through the same functions
  the moderation UI already uses.
  """
  @spec resolve_report(User.t(), Report.t()) ::
          {:ok, Report.t()} | {:error, :unauthorized | term()}
  def resolve_report(%User{} = actor, %Report{status: :open} = report) do
    with :ok <- authorize_on_report(actor, report),
         community = Repo.get!(Community, report.community_id),
         kind = if(report.post_id, do: "post", else: "comment"),
         :ok <- remove_subject(actor, report) do
      # Removing the subject cascades the report row away; log before
      # it's gone would need the same data, so this order is just as
      # correct — the audit entry never depends on the deleted row.
      Audit.record(
        community,
        actor,
        "content.removed",
        "#{actor.display_name} removed a reported #{kind}",
        %{"report_id" => report.id}
      )

      {:ok, %Report{report | status: :resolved, resolved_at: DateTime.utc_now(:second)}}
    end
  end

  def resolve_report(%User{}, %Report{}), do: {:error, :unauthorized}

  ## Bans (SPEC §11: community ban blocks rejoin by email)

  @doc """
  Bans a member: removes their community membership (group memberships
  cascade through the community removal path they already follow) and
  records the email ban. Community admins only; admins cannot ban
  admins — demote first, deliberately two steps.
  """
  @spec ban_member(User.t(), Community.t(), User.t(), String.t() | nil) ::
          {:ok, CommunityBan.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def ban_member(%User{} = actor, %Community{} = community, %User{} = target, reason) do
    target_relationship = Authorization.relationship(target, community)

    cond do
      not Authorization.can?(actor, :manage_community, community) ->
        {:error, :unauthorized}

      actor.id == target.id ->
        {:error, :unauthorized}

      target_relationship.community_role in [:admin, :owner] ->
        {:error, :unauthorized}

      true ->
        with {:ok, ban} <-
               Repo.transact(fn ->
                 remove_memberships(community, target)

                 %CommunityBan{community_id: community.id, banned_by_user_id: actor.id}
                 |> CommunityBan.changeset(%{email: target.email, reason: reason})
                 |> Repo.insert()
               end) do
          Audit.record(
            community,
            actor,
            "member.banned",
            "#{actor.display_name} banned #{target.display_name} (#{target.email})" <>
              if(reason, do: " — #{reason}", else: "")
          )

          {:ok, ban}
        end
    end
  end

  @doc """
  Lifts a ban (community admins).
  """
  @spec unban(User.t(), CommunityBan.t()) ::
          {:ok, CommunityBan.t()} | {:error, :unauthorized}
  def unban(%User{} = actor, %CommunityBan{} = ban) do
    community = Repo.get!(Community, ban.community_id)

    if Authorization.can?(actor, :manage_community, community) do
      with {:ok, lifted} <- Repo.delete(ban) do
        Audit.record(
          community,
          actor,
          "member.unbanned",
          "#{actor.display_name} lifted the ban on #{ban.email}"
        )

        {:ok, lifted}
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Active bans of a community (community admins; empty otherwise).
  """
  @spec list_bans(User.t() | nil, Community.t()) :: [CommunityBan.t()]
  def list_bans(nil, %Community{}), do: []

  def list_bans(%User{} = actor, %Community{} = community) do
    if Authorization.can?(actor, :manage_community, community) do
      Repo.all(
        from(ban in CommunityBan,
          where: ban.community_id == ^community.id,
          order_by: [desc: ban.inserted_at],
          preload: [:banned_by_user]
        )
      )
    else
      []
    end
  end

  @doc """
  Whether the email is banned from the community — the check
  `Communities.add_member/3` enforces.
  """
  @spec banned?(Community.t() | Ecto.UUID.t(), String.t()) :: boolean()
  def banned?(%Community{id: community_id}, email), do: banned?(community_id, email)

  def banned?(community_id, email) when is_binary(email) do
    Repo.exists?(
      from(ban in CommunityBan,
        where: ban.community_id == ^community_id and ban.email == ^String.downcase(email)
      )
    )
  end

  ## Instance-wide bans (SPEC §11: blocks every community, not just one)

  @doc """
  Bans an email instance-wide: if an account with that email exists,
  removes its memberships across every community on the instance (not
  just one, unlike `ban_member/4`) before recording the block. Instance
  operators only; forbids self-ban and banning another operator without
  demoting them first — same two-step rule as community bans.
  """
  @spec ban_instance(User.t(), String.t(), String.t() | nil) ::
          {:ok, InstanceBan.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def ban_instance(%User{} = actor, email, reason) when is_binary(email) do
    normalized_email = String.downcase(email)
    target = Repo.get_by(User, email: normalized_email)

    cond do
      not Authorization.instance_operator?(actor) ->
        {:error, :unauthorized}

      normalized_email == String.downcase(actor.email) ->
        {:error, :unauthorized}

      Authorization.instance_operator?(target) ->
        {:error, :unauthorized}

      true ->
        affected_communities = target && communities_for(target)

        with {:ok, ban} <-
               Repo.transact(fn ->
                 if target, do: remove_all_memberships(target)

                 %InstanceBan{banned_by_user_id: actor.id}
                 |> InstanceBan.changeset(%{email: normalized_email, reason: reason})
                 |> Repo.insert()
               end) do
          Enum.each(affected_communities || [], fn community ->
            Audit.record(
              community,
              actor,
              "member.banned",
              "#{actor.display_name} banned #{target.display_name} (#{target.email}) instance-wide" <>
                if(reason, do: " — #{reason}", else: "")
            )
          end)

          {:ok, ban}
        end
    end
  end

  @doc """
  Lifts an instance ban (instance operators). Unlike lifting a
  community ban, there is no single community to write an audit entry
  against — the ban list itself is the record.
  """
  @spec unban_instance(User.t(), InstanceBan.t()) ::
          {:ok, InstanceBan.t()} | {:error, :unauthorized}
  def unban_instance(%User{} = actor, %InstanceBan{} = ban) do
    if Authorization.instance_operator?(actor) do
      Repo.delete(ban)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  All instance-wide bans (instance operators; empty otherwise).
  """
  @spec list_instance_bans(User.t() | nil) :: [InstanceBan.t()]
  def list_instance_bans(actor) do
    if Authorization.instance_operator?(actor) do
      Repo.all(
        from(ban in InstanceBan, order_by: [desc: ban.inserted_at], preload: [:banned_by_user])
      )
    else
      []
    end
  end

  @doc """
  Whether the email is banned instance-wide — the check
  `Communities.add_member/3` enforces ahead of the per-community ban.
  """
  @spec instance_banned?(String.t()) :: boolean()
  def instance_banned?(email) when is_binary(email) do
    Repo.exists?(from(ban in InstanceBan, where: ban.email == ^String.downcase(email)))
  end

  ## Internals

  defp authorize_on_report(actor, report) do
    community = Repo.get!(Community, report.community_id)
    report = Repo.preload(report, [:post, :comment])

    cond do
      Authorization.can?(actor, :manage_community, community) ->
        :ok

      (group = report_group(report)) != nil and Authorization.can?(actor, :moderate_group, group) ->
        :ok

      true ->
        {:error, :unauthorized}
    end
  end

  defp close_report(report, actor, status) do
    report
    |> Ecto.Changeset.change(
      status: status,
      resolved_by_user_id: actor.id,
      resolved_at: DateTime.utc_now(:second)
    )
    |> Repo.update()
  end

  defp remove_subject(actor, %Report{post_id: post_id}) when is_binary(post_id) do
    post = Repo.get!(Post, post_id)

    case Feed.hard_delete_post(actor, post) do
      {:ok, _post} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_subject(actor, %Report{comment_id: comment_id}) do
    comment = Repo.get!(Comment, comment_id)

    case Feed.delete_comment(actor, comment) do
      {:ok, _comment} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_memberships(community, target) do
    Repo.delete_all(
      from(membership in Kammer.Groups.GroupMembership,
        join: group in assoc(membership, :group),
        where: group.community_id == ^community.id and membership.user_id == ^target.id
      )
    )

    Repo.delete_all(
      from(membership in Kammer.Communities.CommunityMembership,
        where: membership.community_id == ^community.id and membership.user_id == ^target.id
      )
    )
  end

  defp remove_all_memberships(target) do
    Repo.delete_all(
      from(membership in Kammer.Groups.GroupMembership, where: membership.user_id == ^target.id)
    )

    Repo.delete_all(
      from(membership in Kammer.Communities.CommunityMembership,
        where: membership.user_id == ^target.id
      )
    )
  end

  defp communities_for(target) do
    Repo.all(
      from(community in Community,
        join: membership in Kammer.Communities.CommunityMembership,
        on: membership.community_id == community.id,
        where: membership.user_id == ^target.id
      )
    )
  end

  defp comment_group(%Comment{post_id: post_id}) when is_binary(post_id) do
    post = Repo.get!(Post, post_id)
    Repo.get!(Group, post.group_id)
  end

  defp comment_group(%Comment{event_id: event_id}) when is_binary(event_id) do
    event = Repo.get!(Kammer.Events.Event, event_id)
    Repo.get!(Group, event.group_id)
  end

  defp comment_group(%Comment{assignment_id: assignment_id}) do
    assignment = Repo.get!(Kammer.Assignments.Assignment, assignment_id)
    Repo.get!(Group, assignment.group_id)
  end

  defp report_group(%Report{post: %Post{} = post}) do
    case post.group do
      %Group{} = group -> group
      _not_loaded -> Repo.get(Group, post.group_id)
    end
  end

  defp report_group(%Report{comment: %Comment{} = comment}), do: comment_group(comment)
  defp report_group(_report), do: nil
end
