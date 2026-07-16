defmodule Kammer.Newsletters.NewsletterNotifier do
  @moduledoc """
  Newsletter subscription emails (SPEC §8): the confirm-your-subscription
  request, the confirmation with a management link, and the two
  delivery shapes (per-post, digest) — both carrying a one-click
  `List-Unsubscribe` header (RFC 8058) so a mail client can unsubscribe
  a guest without them ever opening a page. Guests have no locale
  preference, so emails use the instance default locale, same as every
  other guest notification.
  """

  use Gettext, backend: KammerWeb.Gettext

  import Swoosh.Email

  alias Kammer.Communities
  alias Kammer.Feed.Post
  alias Kammer.Groups.Group
  alias Kammer.Guests.GuestIdentity
  alias Kammer.Guests.Token, as: GuestToken
  alias Kammer.Mailer
  alias Kammer.Newsletters.NewsletterSubscription

  @doc """
  Asks the prospective subscriber to confirm by following a signed
  link. Nothing is stored until it's followed.
  """
  @spec deliver_confirmation_request(String.t(), String.t(), Group.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_confirmation_request(email_address, display_name, %Group{} = group, confirm_url) do
    with_instance_locale(fn ->
      deliver(
        email_address,
        gettext("Confirm your subscription to %{group}", group: group.name),
        """
        #{gettext("Hi %{name},", name: display_name)}

        #{gettext("Follow this link to confirm your email subscription to %{group}:", group: group.name)}

        #{confirm_url}

        #{gettext("If you didn't request this, you can ignore this email — nothing is recorded until you confirm.")}
        """
      )
    end)
  end

  @doc """
  Confirms the subscription is active, with the management link for
  changing the cadence or unsubscribing.
  """
  @spec deliver_confirmed(GuestIdentity.t(), Group.t(), NewsletterSubscription.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_confirmed(
        %GuestIdentity{} = identity,
        %Group{} = group,
        %NewsletterSubscription{} = subscription,
        manage_url
      ) do
    with_instance_locale(fn ->
      deliver(
        identity.email,
        gettext("Subscribed to %{group}", group: group.name),
        """
        #{gettext("Hi %{name},", name: identity.display_name)}

        #{gettext("You're subscribed to %{group} — %{cadence}.", group: group.name, cadence: cadence_label(subscription.cadence))}

        #{gettext("Change how often you hear from us, or unsubscribe, anytime:")}

        #{manage_url}
        """
      )
    end)
  end

  @doc """
  A per-post delivery: one new post, sent the moment it publishes.
  """
  @spec deliver_new_post(NewsletterSubscription.t(), Post.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_new_post(%NewsletterSubscription{} = subscription, %Post{} = post, manage_token) do
    group = subscription.group || raise "subscription.group must be preloaded"

    identity =
      subscription.guest_identity || raise "subscription.guest_identity must be preloaded"

    with_instance_locale(fn ->
      body = """
      #{gettext("New post in %{group}:", group: group.name)}

      #{excerpt(post.body_markdown)}

      #{post_url(group)}

      #{gettext("Unsubscribe, or change how often you hear from us:")}

      #{manage_url(manage_token)}
      """

      deliver_with_unsubscribe(
        identity.email,
        gettext("New post in %{group}", group: group.name),
        body,
        subscription.id
      )
    end)
  end

  @doc """
  A digest delivery: several posts since the last send, in one email.
  """
  @spec deliver_digest(NewsletterSubscription.t(), [Post.t()], String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_digest(%NewsletterSubscription{} = subscription, posts, manage_token) do
    group = subscription.group || raise "subscription.group must be preloaded"

    identity =
      subscription.guest_identity || raise "subscription.guest_identity must be preloaded"

    with_instance_locale(fn ->
      lines =
        Enum.map_join(posts, "\n\n", fn post ->
          "#{author_name(post)}: #{excerpt(post.body_markdown)}"
        end)

      body = """
      #{gettext("Hi %{name},", name: identity.display_name)}

      #{ngettext("%{count} new post in %{group}:", "%{count} new posts in %{group}:", length(posts), group: group.name)}

      #{lines}

      #{post_url(group)}

      #{gettext("Unsubscribe, or change how often you hear from us:")}

      #{manage_url(manage_token)}
      """

      deliver_with_unsubscribe(
        identity.email,
        gettext("%{group} digest", group: group.name),
        body,
        subscription.id
      )
    end)
  end

  defp deliver(to_address, subject_line, body) do
    email = base_email(to_address, subject_line, body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  defp deliver_with_unsubscribe(to_address, subject_line, body, subscription_id) do
    unsubscribe_url = unsubscribe_url(subscription_id)

    email =
      to_address
      |> base_email(subject_line, body)
      |> header("List-Unsubscribe", "<#{unsubscribe_url}>")
      |> header("List-Unsubscribe-Post", "List-Unsubscribe=One-Click")

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  defp base_email(to_address, subject_line, body) do
    new()
    |> to(to_address)
    |> from(mail_from())
    |> subject(subject_line)
    |> text_body(body)
  end

  defp cadence_label(:per_post), do: gettext("a new email for every post")
  defp cadence_label(:daily), do: gettext("a daily digest")
  defp cadence_label(:weekly), do: gettext("a weekly digest")

  defp post_url(group) do
    community = group.community
    "#{KammerWeb.Endpoint.url()}/c/#{community.slug}/g/#{group.slug}"
  end

  # Full-power, 60-day manage token, deliberately still embedded here
  # (contrast `unsubscribe_url/1` below) — this is a link a human must
  # open and click from the email body, not a URL mail gateways
  # auto-fetch with no interaction, so it isn't issue #233's attack
  # vector. The token rides the URL *fragment* (`#…`, not `/…`): the PWA
  # guest-manage page (ADR 0026, issue #187) reads it client-side, and a
  # fragment is never sent to any server, so a long-lived credential
  # can't leak into access logs or the `Referer` header. This matches
  # `KammerWeb.Api.PublicLinks.manage_url/2`.
  defp manage_url(manage_token) do
    "#{KammerWeb.Endpoint.url()}/guest/manage##{manage_token}"
  end

  # RFC 8058 `List-Unsubscribe` is fetched automatically by mail
  # gateways with no human interaction, so (issue #233) it must never
  # carry a full-power credential — only a token scoped to exactly this
  # one subscription, unable to authorize anything else.
  defp unsubscribe_url(subscription_id) do
    token = GuestToken.sign_unsubscribe(%{subscription_id: subscription_id})
    "#{KammerWeb.Endpoint.url()}/newsletter/unsubscribe/#{token}"
  end

  defp author_name(%Post{author_type: :group, group: group}), do: group.name
  defp author_name(%Post{author_user: %{display_name: name}}), do: name
  defp author_name(_post), do: gettext("Deleted user")

  defp excerpt(nil), do: ""

  defp excerpt(markdown) do
    markdown
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 240)
  end

  defp with_instance_locale(fun) do
    locale = Communities.get_instance_settings().default_locale || "en"
    Gettext.with_locale(KammerWeb.Gettext, to_string(locale), fun)
  end

  defp mail_from do
    from_config = Application.get_env(:kammer, :mail_from, [])
    product_name = Kammer.product_name()

    {Keyword.get(from_config, :name, product_name),
     Keyword.get(from_config, :address, "kammer@localhost")}
  end
end
