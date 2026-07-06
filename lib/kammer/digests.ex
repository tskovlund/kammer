defmodule Kammer.Digests do
  @moduledoc """
  Email digests (SPEC §16): a periodic, calm summary of what happened
  across everything the user belongs to — new posts and upcoming
  events, grouped by community. Strictly opt-in (`digest_frequency`
  defaults to `:off`), and an empty period sends nothing: no email is
  better than a hollow one.

  Content reuses the Home lens's membership-is-visibility argument:
  every item summarized is one the user could already reach.
  """

  use Gettext, backend: KammerWeb.Gettext

  import Ecto.Query, warn: false
  # Ecto.Query also exports from/2 — Swoosh's sender goes through the
  # module call below.
  import Swoosh.Email, except: [from: 2]

  alias Kammer.Accounts.User
  alias Kammer.Events.Event
  alias Kammer.Feed.Post
  alias Kammer.Groups.GroupMembership
  alias Kammer.Mailer
  alias Kammer.Repo

  @doc """
  Users whose digest is due at `now`: daily every day, weekly on
  Mondays — both at the cron hour, both guarded against double sends
  by `last_digest_at`.
  """
  @spec due_users(DateTime.t()) :: [User.t()]
  def due_users(%DateTime{} = now) do
    weekly_due? = Date.day_of_week(DateTime.to_date(now)) == 1
    daily_cutoff = DateTime.add(now, -20, :hour)
    weekly_cutoff = DateTime.add(now, -6 * 24, :hour)

    frequency_filter =
      if weekly_due? do
        dynamic(
          [user],
          (user.digest_frequency == :daily and
             (is_nil(user.last_digest_at) or user.last_digest_at < ^daily_cutoff)) or
            (user.digest_frequency == :weekly and
               (is_nil(user.last_digest_at) or user.last_digest_at < ^weekly_cutoff))
        )
      else
        dynamic(
          [user],
          user.digest_frequency == :daily and
            (is_nil(user.last_digest_at) or user.last_digest_at < ^daily_cutoff)
        )
      end

    Repo.all(from(user in User, where: ^frequency_filter))
  end

  @doc """
  Builds and delivers one user's digest; returns `:skipped` when the
  period holds nothing. Stamps `last_digest_at` on send AND on skip —
  a quiet week counts as covered.
  """
  @spec deliver_digest(User.t(), DateTime.t()) :: :sent | :skipped
  def deliver_digest(%User{} = user, %DateTime{} = now) do
    since = since(user, now)
    posts = new_posts(user, since)
    events = upcoming_events(user, now)

    outcome =
      if posts == [] and events == [] do
        :skipped
      else
        user |> digest_email(posts, events, since) |> Mailer.deliver()
        :sent
      end

    user
    |> Ecto.Changeset.change(last_digest_at: DateTime.truncate(now, :second))
    |> Repo.update!()

    outcome
  end

  defp since(%User{} = user, now) do
    fallback_hours =
      case user.digest_frequency do
        :weekly -> 7 * 24
        _daily_or_off -> 24
      end

    user.last_digest_at || DateTime.add(now, -fallback_hours, :hour)
  end

  defp new_posts(user, since) do
    now = DateTime.utc_now(:second)

    Repo.all(
      from(post in Post,
        join: membership in GroupMembership,
        on: membership.group_id == post.group_id,
        join: group in assoc(post, :group),
        where: membership.user_id == ^user.id,
        where: is_nil(group.archived_at),
        where: post.published_at > ^since and post.published_at <= ^now,
        where: post.pending_approval == false,
        where: is_nil(post.deleted_at),
        where: post.author_user_id != ^user.id or is_nil(post.author_user_id),
        order_by: [asc: post.published_at],
        limit: 50,
        preload: [:author_user, group: {group, :community}]
      )
    )
  end

  defp upcoming_events(user, now) do
    horizon = DateTime.add(now, 7 * 24, :hour)

    Repo.all(
      from(event in Event,
        join: membership in GroupMembership,
        on: membership.group_id == event.group_id,
        join: group in assoc(event, :group),
        where: membership.user_id == ^user.id,
        where: fragment("'events' = ANY(?)", group.features),
        where: is_nil(group.archived_at),
        where: event.starts_at >= ^now and event.starts_at <= ^horizon,
        order_by: [asc: event.starts_at],
        limit: 20,
        preload: [group: {group, :community}]
      )
    )
  end

  defp digest_email(user, posts, events, since) do
    Gettext.with_locale(KammerWeb.Gettext, user.locale, fn ->
      product_name = Application.get_env(:kammer, :product_name, "Kammer")

      new()
      |> to({user.display_name, user.email})
      |> Swoosh.Email.from(mail_from())
      |> subject(gettext("%{product} digest: what you missed", product: product_name))
      |> text_body(digest_body(user, posts, events, since))
    end)
  end

  defp digest_body(user, posts, events, _since) do
    sections =
      [posts_section(posts), events_section(user, events)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    """
    #{gettext("Hi %{name},", name: user.display_name)}

    #{sections}

    #{gettext("You get this because your digest setting is on — change it under Account settings.")}
    """
  end

  defp posts_section([]), do: nil

  defp posts_section(posts) do
    lines =
      posts
      |> Enum.group_by(fn post -> post.group.community.name end)
      |> Enum.sort_by(fn {community_name, _posts} -> community_name end)
      |> Enum.map_join("\n\n", fn {community_name, community_posts} ->
        post_lines =
          Enum.map_join(community_posts, "\n", fn post ->
            "  - #{post.group.name}: #{author_name(post)} — #{excerpt(post.body_markdown)}"
          end)

        "#{community_name}:\n#{post_lines}"
      end)

    """
    #{ngettext("%{count} new post", "%{count} new posts", length(posts))}

    #{lines}
    """
    |> String.trim_trailing()
  end

  defp events_section(_user, []), do: nil

  defp events_section(user, events) do
    lines =
      Enum.map_join(events, "\n", fn event ->
        local = shift(event.starts_at, user.timezone)

        "  - #{Calendar.strftime(local, "%a %d %b %H:%M")} — #{event.title} (#{event.group.name})"
      end)

    """
    #{gettext("Coming up this week")}

    #{lines}
    """
    |> String.trim_trailing()
  end

  defp author_name(%Post{author_type: :group, group: group}), do: group.name
  defp author_name(%Post{author_user: %{display_name: name}}), do: name
  defp author_name(_post), do: gettext("Deleted user")

  defp excerpt(nil), do: ""

  defp excerpt(markdown) do
    markdown
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 120)
  end

  defp shift(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} -> shifted
      {:error, _reason} -> datetime
    end
  end

  defp mail_from do
    from_config = Application.get_env(:kammer, :mail_from, [])
    product_name = Application.get_env(:kammer, :product_name, "Kammer")

    {Keyword.get(from_config, :name, product_name),
     Keyword.get(from_config, :address, "kammer@localhost")}
  end
end
