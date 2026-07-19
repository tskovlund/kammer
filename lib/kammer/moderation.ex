defmodule Kammer.Moderation do
  @moduledoc """
  Reports and bans (SPEC §11). Anyone who can see a post or comment
  can report it; the queue serves community admins (everything) and
  group moderators (their groups). Resolving removes the content
  through the same moderation functions the UI already uses; bans are
  keyed on email and enforced at the single membership choke-point
  (`Communities.add_member/3`).

  Boundary note (#167): as-group posts hide the human author on every
  member-facing surface, but the moderation queue deliberately shows
  them — moderator accountability is why `author_user_id` is retained
  at all. Moderators sit inside the hiding boundary.
  """

  import Ecto.Query, warn: false

  alias Kammer.Accounts
  alias Kammer.Accounts.User
  alias Kammer.Audit
  alias Kammer.Authorization
  alias Kammer.Communities.Community
  alias Kammer.Events
  alias Kammer.Feed
  alias Kammer.Feed.Comment
  alias Kammer.Feed.Post
  alias Kammer.Groups.Group
  alias Kammer.Moderation.CommunityBan
  alias Kammer.Moderation.InstanceBan
  alias Kammer.Moderation.Report
  alias Kammer.RateLimit
  alias Kammer.Repo

  ## Reports

  @doc """
  Files a report on a post. Anyone who may view the host group may
  report; one open report per person per subject.
  """
  @spec report_post(User.t(), Post.t(), String.t()) ::
          {:ok, Report.t()} | {:error, Ecto.Changeset.t() | :unauthorized | :rate_limited}
  def report_post(%User{} = reporter, %Post{} = post, reason) do
    group = Repo.get!(Group, post.group_id)

    with :ok <- Authorization.authorize(reporter, :view_group, group),
         :ok <- check_report_rate_limit(reporter.id) do
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
          {:ok, Report.t()} | {:error, Ecto.Changeset.t() | :unauthorized | :rate_limited}
  def report_comment(%User{} = reporter, %Comment{} = comment, reason) do
    {group, _subject} = Feed.comment_context(comment)

    with :ok <- Authorization.authorize(reporter, :view_group, group),
         :ok <- check_report_rate_limit(reporter.id) do
      %Report{
        community_id: group.community_id,
        reporter_user_id: reporter.id,
        comment_id: comment.id
      }
      |> Report.changeset(%{reason: reason})
      |> Repo.insert()
    end
  end

  # Authorization runs first, so a refused caller never burns budget
  # and the limiter can't be used to probe what someone may see. After
  # that, every attempt counts — a duplicate report spends the budget
  # too (`Kammer.RateLimit.hit_report_create/1`).
  defp check_report_rate_limit(user_id) do
    case RateLimit.hit_report_create(user_id) do
      {:allow, _count} -> :ok
      {:deny, _retry} -> {:error, :rate_limited}
    end
  end

  @doc """
  Whether a report-changeset rejection means "this reporter already
  has an open report on this subject" — matched by the two named
  partial-unique constraints, not the error class, so a future unique
  constraint on reports can't be silently mistaken for a duplicate
  (callers collapse duplicates into a friendly no-op).
  """
  @spec duplicate_report?(Ecto.Changeset.t()) :: boolean()
  def duplicate_report?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, meta}} ->
      meta[:constraint] == :unique and
        meta[:constraint_name] in ["reports_one_open_per_post", "reports_one_open_per_comment"]
    end)
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
      filter_by_moderated_groups(actor, community, reports)
    end
  end

  @doc """
  Fetches a report by id, or `nil` if it doesn't exist. Unauthenticated
  — callers pass the result to an authorization-checked mutator below.
  """
  @spec get_report(Ecto.UUID.t()) :: Report.t() | nil
  def get_report(report_id), do: Repo.get(Report, report_id)

  @doc """
  Dismisses a report — the content stays.
  """
  @spec dismiss_report(User.t(), Report.t()) ::
          {:ok, Report.t()} | {:error, :unauthorized}
  def dismiss_report(%User{} = actor, %Report{status: :open} = report) do
    with :ok <- authorize_on_report(actor, report),
         {:ok, dismissed} <- close_report(report, actor, :dismissed) do
      kind = if(report.post_id, do: "post", else: "comment")

      Audit.record(
        report.community_id,
        actor,
        "report.dismissed",
        "#{actor.display_name} dismissed a report on a #{kind}",
        %{"report_id" => report.id}
      )

      {:ok, dismissed}
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
  admins — demote first, deliberately two steps. The protected-role
  check runs inside the transaction against the row-locked membership,
  so a concurrent promotion cannot land between check and removal
  (issue #129), and the banned email is re-read from the row-locked
  user, so the ban records the target's current address even when the
  caller's struct predates an email change (issue #171).
  """
  @spec ban_member(User.t(), Community.t(), User.t(), String.t() | nil) ::
          {:ok, CommunityBan.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def ban_member(%User{} = actor, %Community{} = community, %User{} = target, reason) do
    cond do
      not Authorization.can?(actor, :manage_community, community) ->
        {:error, :unauthorized}

      actor.id == target.id ->
        {:error, :unauthorized}

      true ->
        with {:ok, ban} <-
               Repo.transact(fn ->
                 # Lock order: the target's user row first, then their
                 # community-membership row — the same user→membership
                 # order `purge_memberships_and_ban/3` takes (and
                 # `Communities.add_member/3` shares the user-row lock,
                 # #170), so the ban paths can never deadlock each
                 # other. The locked re-read also yields the target's
                 # current email: the struct in hand may predate an
                 # email change, and the ban must record the address
                 # the account uses now (issue #171).
                 current_email = Accounts.lock_user_email(target) || target.email

                 if lock_community_role(community, target) in [:admin, :owner] do
                   {:error, :unauthorized}
                 else
                   remove_memberships(community, target)

                   %CommunityBan{community_id: community.id, banned_by_user_id: actor.id}
                   |> CommunityBan.changeset(%{email: current_email, reason: reason})
                   |> Repo.insert()
                 end
               end) do
          Audit.record(
            community,
            actor,
            "member.banned",
            "#{actor.display_name} banned #{target.display_name} (#{ban.email})" <>
              if(reason, do: " — #{reason}", else: "")
          )

          {:ok, ban}
        end
    end
  end

  @doc """
  Fetches a community ban by id, or `nil` if it doesn't exist.
  Unauthenticated — callers pass the result to an authorization-checked
  mutator below.
  """
  @spec get_community_ban(Ecto.UUID.t()) :: CommunityBan.t() | nil
  def get_community_ban(ban_id), do: Repo.get(CommunityBan, ban_id)

  @doc """
  Lifts a ban (community admins).
  """
  @spec unban(User.t(), CommunityBan.t()) ::
          {:ok, CommunityBan.t()} | {:error, :unauthorized}
  def unban(%User{} = actor, %CommunityBan{} = ban) do
    community = Repo.get!(Community, ban.community_id)

    if Authorization.can?(actor, :manage_community, community) do
      # stale_error_field: a concurrently-lifted ban folds into the same
      # 404 as a nonexistent one instead of raising (500).
      case Repo.delete(ban, stale_error_field: :id) do
        {:ok, lifted} ->
          Audit.record(
            community,
            actor,
            "member.unbanned",
            "#{actor.display_name} lifted the ban on #{ban.email}"
          )

          {:ok, lifted}

        {:error, _stale} ->
          {:error, :not_found}
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
  operators only; forbids self-ban, banning another operator, and
  banning anyone who owns a community — same demote/transfer-first
  rule `Communities.remove_member/3` enforces for ordinary removal,
  extended here since a bulk purge has no single community to ask
  "who's the new owner?" of. The target-protection checks run inside
  the transaction against row-locked state, so a concurrent promotion
  or ownership transfer cannot land between check and purge
  (issue #129).
  """
  @spec ban_instance(User.t(), String.t(), String.t() | nil) ::
          {:ok, InstanceBan.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def ban_instance(%User{} = actor, email, reason) when is_binary(email) do
    normalized_email = String.downcase(email)

    ban_changeset =
      InstanceBan.changeset(%InstanceBan{banned_by_user_id: actor.id}, %{
        email: normalized_email,
        reason: reason
      })

    cond do
      not Authorization.instance_operator?(actor) ->
        {:error, :unauthorized}

      not ban_changeset.valid? ->
        # Reject a malformed email (control chars, missing @, over-length)
        # HERE, before the row-locked lookup in the purge transaction — a
        # raw NUL in `where email = ?` is a Postgres 500, not a 422 (issue
        # #334). The changeset carries the field error for the client.
        {:error, ban_changeset}

      normalized_email == String.downcase(actor.email) ->
        {:error, :unauthorized}

      true ->
        with {:ok, {ban, target, affected_communities}} <-
               Repo.transact(fn -> purge_memberships_and_ban(actor, normalized_email, reason) end) do
          Enum.each(affected_communities, fn community ->
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
  Fetches an instance ban by id, or `nil` if it doesn't exist.
  Unauthenticated — callers pass the result to an authorization-checked
  mutator below.
  """
  @spec get_instance_ban(Ecto.UUID.t()) :: InstanceBan.t() | nil
  def get_instance_ban(ban_id), do: Repo.get(InstanceBan, ban_id)

  @doc """
  Lifts an instance ban (instance operators). Unlike lifting a
  community ban, there is no single community to write an audit entry
  against — the ban list itself is the record.
  """
  @spec unban_instance(User.t(), InstanceBan.t()) ::
          {:ok, InstanceBan.t()} | {:error, :unauthorized}
  def unban_instance(%User{} = actor, %InstanceBan{} = ban) do
    if Authorization.instance_operator?(actor) do
      # See unban/2: a concurrent lift folds into the nonexistent-ban 404.
      case Repo.delete(ban, stale_error_field: :id) do
        {:ok, lifted} -> {:ok, lifted}
        {:error, _stale} -> {:error, :not_found}
      end
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

  # Also ends the target's spot on every one of those groups' future
  # events (issue #329) — a ban's group-membership removal is just
  # another door into the same membership-ending rule `Groups.leave_group/2`
  # and `Groups.remove_member/3` enforce; past RSVPs stay as attendance
  # history. See `Kammer.Events.drop_member_future_rsvps_in_groups/2`.
  defp remove_memberships(community, target) do
    {_count, group_ids} =
      Repo.delete_all(
        from(membership in Kammer.Groups.GroupMembership,
          join: group in assoc(membership, :group),
          where: group.community_id == ^community.id and membership.user_id == ^target.id,
          select: membership.group_id
        )
      )

    Events.drop_member_future_rsvps_in_groups(target.id, group_ids)

    Repo.delete_all(
      from(membership in Kammer.Communities.CommunityMembership,
        where: membership.community_id == ^community.id and membership.user_id == ^target.id
      )
    )
  end

  # Same rule, instance-wide: every group across every community the
  # target belongs to (issue #329).
  defp remove_all_memberships(target) do
    {_count, group_ids} =
      Repo.delete_all(
        from(membership in Kammer.Groups.GroupMembership,
          where: membership.user_id == ^target.id,
          select: membership.group_id
        )
      )

    Events.drop_member_future_rsvps_in_groups(target.id, group_ids)

    Repo.delete_all(
      from(membership in Kammer.Communities.CommunityMembership,
        where: membership.user_id == ^target.id
      )
    )
  end

  # Runs inside `ban_instance/3`'s transaction. The guards a ban must
  # not race past — the target's operator flag and community ownership
  # (a purge past an owner would orphan that community, the bug #122
  # fixed) — are checked here, against the row-locked user and
  # membership rows, not before the transaction: a concurrent
  # promotion or ownership transfer either committed before the locks
  # were taken (so the check sees it) or blocks until the ban commits
  # (issue #129).
  defp purge_memberships_and_ban(actor, normalized_email, reason) do
    target =
      Repo.one(from(user in User, where: user.email == ^normalized_email, lock: "FOR UPDATE"))

    memberships = (target && lock_community_memberships(target)) || []

    cond do
      Authorization.instance_operator?(target) ->
        {:error, :unauthorized}

      Enum.any?(memberships, &(&1.role == :owner)) ->
        {:error, :unauthorized}

      true ->
        if target do
          remove_all_memberships(target)
          # An instance ban locks the account out of every community, so
          # it severs live access too: revoke its device tokens here, in
          # the same transaction as the purge. The controller broadcasts
          # the socket disconnect once this commits.
          Accounts.revoke_all_user_devices(target)
        end

        insert_result =
          %InstanceBan{banned_by_user_id: actor.id}
          |> InstanceBan.changeset(%{email: normalized_email, reason: reason})
          |> Repo.insert()

        with {:ok, ban} <- insert_result do
          {:ok, {ban, target, Enum.map(memberships, & &1.community)}}
        end
    end
  end

  # Inside `ban_member/4`'s transaction: reads the target's community
  # role with the membership row locked, so a concurrent role change
  # cannot land between this check and the membership removal.
  defp lock_community_role(community, target) do
    Repo.one(
      from(membership in Kammer.Communities.CommunityMembership,
        where: membership.community_id == ^community.id and membership.user_id == ^target.id,
        lock: "FOR UPDATE",
        select: membership.role
      )
    )
  end

  # Inside `ban_instance/3`'s transaction: locks every community
  # membership row of the target before the ownership check reads
  # their roles. The community preload runs unlocked afterwards —
  # only the membership rows (where the roles live) need the lock.
  defp lock_community_memberships(target) do
    memberships =
      Repo.all(
        from(membership in Kammer.Communities.CommunityMembership,
          where: membership.user_id == ^target.id,
          lock: "FOR UPDATE"
        )
      )

    memberships
    |> Repo.preload(:community)
    |> Enum.map(&%{community: &1.community, role: &1.role})
  end

  defp report_group(%Report{post: %Post{} = post}) do
    case post.group do
      %Group{} = group -> group
      _not_loaded -> Repo.get(Group, post.group_id)
    end
  end

  defp report_group(%Report{comment: %Comment{} = comment}) do
    # Prefer the queue's own preloads (comment: [post: :group, ...]) —
    # `Feed.comment_context/1` re-fetches the parent per call, which
    # put comment reports back on a per-report query cost (#346 review).
    case comment do
      %Comment{post: %Post{group: %Group{} = group}} -> group
      %Comment{event: %{group: %Group{} = group}} -> group
      %Comment{assignment: %{group: %Group{} = group}} -> group
      _not_preloaded -> comment |> Feed.comment_context() |> elem(0)
    end
  end

  defp report_group(_report), do: nil

  # Group moderators only see reports whose subject lives in a group
  # they moderate. Resolving each report's group once and then asking
  # `Authorization.can?/3` per report would hit the DB twice per report
  # (community role + group role) — issue #342. Batching every distinct
  # group's relationship through `Authorization.group_relationships/3`
  # (#206) resolves them all in two queries total for the whole page,
  # the same shape `CommunityController.groups/2` already uses.
  defp filter_by_moderated_groups(_actor, _community, []), do: []

  defp filter_by_moderated_groups(actor, community, reports) do
    groups_by_report_id = Map.new(reports, &{&1.id, report_group(&1)})

    groups =
      groups_by_report_id
      |> Map.values()
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)

    relationships = Authorization.group_relationships(actor, community, groups)

    Enum.filter(reports, fn report ->
      case Map.fetch!(groups_by_report_id, report.id) do
        nil -> false
        group -> Authorization.can?(actor, :moderate_group, group, relationships[group.id])
      end
    end)
  end
end
