defmodule Kammer.Newsletters do
  @moduledoc """
  Guest email subscriptions to a public group's feed (ADR 0013's
  guest-identity pattern, SPEC §8): request → signed confirm link →
  the subscription is created, never before. Cadence is per-post
  (an email the moment a new post publishes) or a daily/weekly digest,
  mirroring `Kammer.Digests`' cadence math but scoped to one group
  instead of a user's memberships. Every delivery carries a one-click
  unsubscribe link built from the guest's management token — the same
  stateless, expiring credential every other guest link uses.
  """

  import Ecto.Query, warn: false

  alias Kammer.Authorization
  alias Kammer.Feed.Post
  alias Kammer.Groups.Group
  alias Kammer.Guests
  alias Kammer.Guests.GuestIdentity
  alias Kammer.Guests.Token, as: GuestToken
  alias Kammer.Newsletters.NewsletterNotifier
  alias Kammer.Newsletters.NewsletterSubscription
  alias Kammer.RateLimit
  alias Kammer.Repo

  ## Request / confirm (SPEC §8: nothing recorded before the link is followed)

  @doc """
  First step: validates the request, rate-limits it, and emails a
  signed confirm link. Nothing is stored yet.
  """
  @spec request_subscription(Group.t(), map(), keyword()) ::
          :ok | {:error, :unauthorized | :rate_limited | Ecto.Changeset.t()}
  def request_subscription(%Group{} = group, attrs, opts) do
    changeset = request_changeset(attrs)

    with true <- Authorization.can_guest_subscribe?(group) or {:error, :unauthorized},
         {:ok, request} <- Ecto.Changeset.apply_action(changeset, :insert),
         {:allow, _count} <- RateLimit.hit_guest_email(request.email),
         {:allow, _count} <- RateLimit.hit_guest_ip(opts[:client_ip]) do
      token =
        GuestToken.sign_confirm(%{
          group_id: group.id,
          email: request.email,
          display_name: request.display_name,
          cadence: request.cadence
        })

      confirm_url = opts |> Keyword.fetch!(:confirm_url_fun) |> then(& &1.(token))

      NewsletterNotifier.deliver_confirmation_request(
        request.email,
        request.display_name,
        group,
        confirm_url
      )

      :ok
    else
      {:deny, _retry_after} -> {:error, :rate_limited}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Second step, from the emailed confirm link: verifies the guest
  identity, upserts the subscription (re-confirming an existing one
  just updates the cadence), and emails the confirmation with the
  management link.
  """
  @spec confirm_subscription(String.t(), (String.t() -> String.t())) ::
          {:ok, Group.t(), NewsletterSubscription.t()} | {:error, :invalid}
  def confirm_subscription(token, manage_url_fun) do
    with {:ok, %{group_id: group_id, email: email, display_name: display_name, cadence: cadence}} <-
           GuestToken.verify_confirm(token),
         %Group{} = group <- Repo.get(Group, group_id),
         true <- Authorization.can_guest_subscribe?(group),
         {:ok, identity} <- Guests.verify_identity(email, display_name),
         {:ok, subscription} <- upsert_subscription(group, identity, cadence) do
      manage_token = GuestToken.sign_manage(%{identity_id: identity.id})

      NewsletterNotifier.deliver_confirmed(
        identity,
        group,
        subscription,
        manage_url_fun.(manage_token)
      )

      {:ok, group, subscription}
    else
      _invalid_or_gone -> {:error, :invalid}
    end
  end

  ## Management (through the guest's manage-page token)

  @doc """
  Changes a subscription's cadence through the guest's management
  link.
  """
  @spec update_cadence(String.t(), Ecto.UUID.t(), NewsletterSubscription.cadence()) ::
          {:ok, NewsletterSubscription.t()} | {:error, :invalid}
  def update_cadence(manage_token, subscription_id, cadence)
      when cadence in [:per_post, :daily, :weekly] do
    with {:ok, subscription} <- fetch_by_manage_token(manage_token, subscription_id) do
      subscription
      |> NewsletterSubscription.changeset(%{cadence: cadence})
      |> Repo.update()
    end
  end

  @doc """
  Unsubscribes through the guest's management link — also the target
  of the one-click `List-Unsubscribe` link every delivery carries, so
  a mail client can call this without the guest visiting any page.
  """
  @spec unsubscribe_by_token(String.t(), Ecto.UUID.t()) :: :ok | {:error, :invalid}
  def unsubscribe_by_token(manage_token, subscription_id) do
    with {:ok, subscription} <- fetch_by_manage_token(manage_token, subscription_id) do
      Repo.delete!(subscription)
      :ok
    end
  end

  @doc """
  A guest's active subscriptions, for the management page.
  """
  @spec list_subscriptions(GuestIdentity.t()) :: [NewsletterSubscription.t()]
  def list_subscriptions(%GuestIdentity{} = identity) do
    Repo.all(
      from(subscription in NewsletterSubscription,
        where: subscription.guest_identity_id == ^identity.id,
        preload: [group: :community],
        order_by: [asc: subscription.inserted_at]
      )
    )
  end

  ## Delivery

  @doc """
  Emails every confirmed per-post subscriber of the group the new
  post — called right after a post's normal member fan-out (SPEC §8).
  """
  @spec notify_subscribers(Post.t()) :: :ok
  def notify_subscribers(%Post{} = post) do
    now = DateTime.utc_now(:second)

    subscribers =
      Repo.all(
        from(subscription in NewsletterSubscription,
          where: subscription.group_id == ^post.group_id and subscription.cadence == :per_post,
          preload: [:guest_identity, group: :community]
        )
      )

    Enum.each(subscribers, fn subscription ->
      manage_token = GuestToken.sign_manage(%{identity_id: subscription.guest_identity_id})
      NewsletterNotifier.deliver_new_post(subscription, post, manage_token)
    end)

    if subscribers != [] do
      ids = Enum.map(subscribers, & &1.id)

      Repo.update_all(from(s in NewsletterSubscription, where: s.id in ^ids),
        set: [last_sent_at: now]
      )
    end

    :ok
  end

  @doc """
  Subscriptions whose digest is due at `now`: daily every day, weekly
  on Mondays — the same cadence math as `Kammer.Digests.due_users/1`,
  scoped to one group's subscribers instead of a user's memberships.
  """
  @spec due_subscriptions(DateTime.t()) :: [NewsletterSubscription.t()]
  def due_subscriptions(%DateTime{} = now) do
    weekly_due? = Date.day_of_week(DateTime.to_date(now)) == 1
    daily_cutoff = DateTime.add(now, -20, :hour)
    weekly_cutoff = DateTime.add(now, -6 * 24, :hour)

    cadence_filter =
      if weekly_due? do
        dynamic(
          [subscription],
          (subscription.cadence == :daily and
             (is_nil(subscription.last_sent_at) or subscription.last_sent_at < ^daily_cutoff)) or
            (subscription.cadence == :weekly and
               (is_nil(subscription.last_sent_at) or subscription.last_sent_at < ^weekly_cutoff))
        )
      else
        dynamic(
          [subscription],
          subscription.cadence == :daily and
            (is_nil(subscription.last_sent_at) or subscription.last_sent_at < ^daily_cutoff)
        )
      end

    Repo.all(
      from(subscription in NewsletterSubscription,
        where: ^cadence_filter,
        preload: [:guest_identity, group: :community]
      )
    )
  end

  @doc """
  Builds and delivers one subscription's digest; `:skipped` when the
  period holds nothing. Stamps `last_sent_at` on send AND on skip —
  a quiet week counts as covered, same as `Kammer.Digests`.
  """
  @spec deliver_digest(NewsletterSubscription.t(), DateTime.t()) :: :sent | :skipped
  def deliver_digest(%NewsletterSubscription{} = subscription, %DateTime{} = now) do
    subscription = Repo.preload(subscription, [:guest_identity, group: :community])
    since = since(subscription, now)
    posts = new_posts(subscription.group_id, since, now)

    outcome =
      if posts == [] do
        :skipped
      else
        manage_token = GuestToken.sign_manage(%{identity_id: subscription.guest_identity_id})
        NewsletterNotifier.deliver_digest(subscription, posts, manage_token)
        :sent
      end

    subscription
    |> Ecto.Changeset.change(last_sent_at: DateTime.truncate(now, :second))
    |> Repo.update!()

    outcome
  end

  defp fetch_by_manage_token(manage_token, subscription_id) do
    with {:ok, %{identity_id: identity_id}} <- GuestToken.verify_manage(manage_token),
         %NewsletterSubscription{} = subscription <-
           Repo.get_by(NewsletterSubscription,
             id: subscription_id,
             guest_identity_id: identity_id
           ) do
      {:ok, subscription}
    else
      _invalid_or_gone -> {:error, :invalid}
    end
  end

  defp upsert_subscription(%Group{} = group, %GuestIdentity{} = identity, cadence) do
    case Repo.get_by(NewsletterSubscription, group_id: group.id, guest_identity_id: identity.id) do
      nil ->
        %NewsletterSubscription{group_id: group.id, guest_identity_id: identity.id}
        |> NewsletterSubscription.changeset(%{cadence: cadence})
        |> Repo.insert()

      %NewsletterSubscription{} = subscription ->
        subscription
        |> NewsletterSubscription.changeset(%{cadence: cadence})
        |> Repo.update()
    end
  end

  defp since(%NewsletterSubscription{} = subscription, now) do
    fallback_hours =
      case subscription.cadence do
        :weekly -> 7 * 24
        _daily -> 24
      end

    subscription.last_sent_at || DateTime.add(now, -fallback_hours, :hour)
  end

  defp new_posts(group_id, since, now) do
    Repo.all(
      from(post in Post,
        where: post.group_id == ^group_id,
        where: post.published_at > ^since and post.published_at <= ^now,
        where: post.pending_approval == false,
        where: is_nil(post.deleted_at),
        order_by: [asc: post.published_at],
        limit: 50,
        preload: [:author_user]
      )
    )
  end

  defp request_changeset(attrs) do
    types = %{
      email: :string,
      display_name: :string,
      cadence: Ecto.ParameterizedType.init(Ecto.Enum, values: NewsletterSubscription.cadences())
    }

    {%{cadence: :per_post}, types}
    |> Ecto.Changeset.cast(attrs, Map.keys(types))
    |> Ecto.Changeset.validate_required([:email, :display_name, :cadence])
    |> Ecto.Changeset.update_change(:email, &String.downcase/1)
    |> Ecto.Changeset.validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/)
    |> Ecto.Changeset.validate_length(:email, max: 160)
    |> Ecto.Changeset.validate_length(:display_name, min: 1, max: 120)
  end
end
