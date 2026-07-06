defmodule Kammer.Notifications.NotificationEmail do
  @moduledoc """
  Notification emails (SPEC §9), localized per recipient. Bodies carry a
  short summary and a link; the instance-wide content-minimized mode
  (SPEC §9) is a Phase 2 toggle documented in BUILDLOG.
  """

  use Gettext, backend: KammerWeb.Gettext

  import Swoosh.Email

  alias Kammer.Accounts.User
  alias Kammer.Groups.Group
  alias Kammer.Mailer

  @doc """
  Delivers a notification email for `kind` with the given references.
  """
  @spec deliver(User.t(), Group.t(), atom(), keyword()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver(%User{} = recipient, %Group{} = group, kind, references) do
    Gettext.with_locale(KammerWeb.Gettext, recipient.locale, fn ->
      summary = summary_line(kind, references)

      email =
        new()
        |> to(recipient.email)
        |> from(mail_from())
        |> subject("#{group.name}: #{summary}")
        |> text_body("""
        #{gettext("Hi %{name},", name: recipient.display_name)}

        #{summary}

        #{target_url(group, references)}
        """)

      with {:ok, _metadata} <- Mailer.deliver(email) do
        {:ok, email}
      end
    end)
  end

  @doc """
  One-line summary for emails and push payloads, in the current locale.
  """
  @spec summary_line(atom(), keyword()) :: String.t()
  def summary_line(kind, references) do
    actor_name =
      case Keyword.get(references, :actor_id) do
        nil ->
          gettext("Someone")

        actor_id ->
          case Kammer.Repo.get(User, actor_id) do
            nil -> gettext("Someone")
            actor -> actor.display_name
          end
      end

    case kind do
      :mention ->
        gettext("%{name} mentioned you", name: actor_name)

      :reply ->
        gettext("%{name} replied to you", name: actor_name)

      :acknowledgment_required ->
        gettext("%{name} posted something to acknowledge", name: actor_name)

      :event_created ->
        gettext("%{name} created an event", name: actor_name)

      :event_reminder ->
        gettext("Event reminder")

      :post ->
        gettext("%{name} posted", name: actor_name)
    end
  end

  @doc """
  The in-app URL a notification points at.
  """
  @spec target_url(Group.t(), keyword()) :: String.t()
  def target_url(%Group{} = group, references) do
    community = Kammer.Repo.get!(Kammer.Communities.Community, group.community_id)
    base = KammerWeb.Endpoint.url()

    cond do
      event = Keyword.get(references, :event) ->
        "#{base}/c/#{community.slug}/events/#{event.id}"

      _post = Keyword.get(references, :post) ->
        "#{base}/c/#{community.slug}/g/#{group.slug}"

      true ->
        "#{base}/c/#{community.slug}/g/#{group.slug}"
    end
  end

  defp mail_from do
    from_config = Application.get_env(:kammer, :mail_from, [])
    product_name = Application.get_env(:kammer, :product_name, "Kammer")

    {Keyword.get(from_config, :name, product_name),
     Keyword.get(from_config, :address, "kammer@localhost")}
  end
end
