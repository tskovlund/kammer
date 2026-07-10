defmodule Kammer.Guests.GuestNotifier do
  @moduledoc """
  Guest emails (SPEC §6): the confirm-your-RSVP request and the
  confirmation with ICS attachment + signed management link. Guests
  have no locale preference, so emails use the instance default locale.
  """

  use Gettext, backend: KammerWeb.Gettext

  import Swoosh.Email

  alias Kammer.Calendar.ICS
  alias Kammer.Communities
  alias Kammer.Events.Event
  alias Kammer.Events.EventSlot
  alias Kammer.Groups.Group
  alias Kammer.Guests.GuestIdentity
  alias Kammer.Mailer

  @doc """
  Asks the guest to confirm their RSVP by following a signed link.
  """
  @spec deliver_confirmation_request(String.t(), String.t(), Event.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_confirmation_request(email_address, display_name, %Event{} = event, confirm_url) do
    with_instance_locale(fn ->
      deliver(
        email_address,
        gettext("Confirm your RSVP to %{title}", title: event.title),
        """
        #{gettext("Hi %{name},", name: display_name)}

        #{gettext("Follow this link to confirm your RSVP to %{title}:", title: event.title)}

        #{confirm_url}

        #{gettext("If you didn't request this, you can ignore this email — nothing is recorded until you confirm.")}
        """
      )
    end)
  end

  @doc """
  Confirms the recorded RSVP: calendar file attached, management link
  for changing the answer or erasing the guest's data (SPEC §12).
  """
  @spec deliver_confirmed(GuestIdentity.t(), Event.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_confirmed(%GuestIdentity{} = identity, %Event{} = event, manage_url) do
    with_instance_locale(fn ->
      email =
        base_email(
          identity.email,
          gettext("Your RSVP to %{title}", title: event.title),
          """
          #{gettext("Hi %{name},", name: identity.display_name)}

          #{gettext("Your RSVP to %{title} is recorded.", title: event.title)}

          #{gettext("Change your answer, or erase everything we store about you, anytime:")}

          #{manage_url}
          """
        )
        |> attachment(
          Swoosh.Attachment.new({:data, ICS.single(event)},
            filename: "event.ics",
            content_type: "text/calendar"
          )
        )

      with {:ok, _metadata} <- Mailer.deliver(email) do
        {:ok, email}
      end
    end)
  end

  @doc """
  Asks the guest to confirm their signup-slot claim by following a
  signed link (issue #37). Nothing is stored until it's followed.
  """
  @spec deliver_claim_confirmation_request(
          String.t(),
          String.t(),
          EventSlot.t(),
          Event.t(),
          String.t()
        ) :: {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_claim_confirmation_request(
        email_address,
        display_name,
        %EventSlot{} = slot,
        %Event{} = event,
        confirm_url
      ) do
    with_instance_locale(fn ->
      deliver(
        email_address,
        gettext("Confirm your signup: %{slot} — %{title}", slot: slot.title, title: event.title),
        """
        #{gettext("Hi %{name},", name: display_name)}

        #{gettext("Follow this link to confirm you're taking \"%{slot}\" for %{title}:", slot: slot.title, title: event.title)}

        #{confirm_url}

        #{gettext("If you didn't request this, you can ignore this email — nothing is recorded until you confirm.")}
        """
      )
    end)
  end

  @doc """
  Confirms the recorded slot claim, with the guest's management link.
  """
  @spec deliver_claim_confirmed(GuestIdentity.t(), EventSlot.t(), Event.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_claim_confirmed(
        %GuestIdentity{} = identity,
        %EventSlot{} = slot,
        %Event{} = event,
        manage_url
      ) do
    with_instance_locale(fn ->
      deliver(
        identity.email,
        gettext("You're signed up: %{slot} — %{title}", slot: slot.title, title: event.title),
        """
        #{gettext("Hi %{name},", name: identity.display_name)}

        #{gettext("You're taking \"%{slot}\" for %{title}. Thanks!", slot: slot.title, title: event.title)}

        #{gettext("See everything you've signed up for, or erase everything we store about you, anytime:")}

        #{manage_url}
        """
      )
    end)
  end

  @doc """
  Asks the guest to confirm their comment by following a signed link
  (SPEC §3 `members_and_guests`). The comment travels inside the link —
  nothing is stored until it's followed.
  """
  @spec deliver_comment_confirmation_request(String.t(), String.t(), Group.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_comment_confirmation_request(
        email_address,
        display_name,
        %Group{} = group,
        confirm_url
      ) do
    with_instance_locale(fn ->
      deliver(
        email_address,
        gettext("Confirm your comment in %{group}", group: group.name),
        """
        #{gettext("Hi %{name},", name: display_name)}

        #{gettext("Follow this link to submit your comment in %{group}:", group: group.name)}

        #{confirm_url}

        #{gettext("A moderator reviews guest comments before they appear.")}

        #{gettext("If you didn't request this, you can ignore this email — nothing is recorded until you confirm.")}
        """
      )
    end)
  end

  @doc """
  Confirms the guest's comment is in: awaiting moderation, with the
  management link for listing or erasing everything they created.
  """
  @spec deliver_comment_confirmed(GuestIdentity.t(), Group.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_comment_confirmed(%GuestIdentity{} = identity, %Group{} = group, manage_url) do
    with_instance_locale(fn ->
      deliver(
        identity.email,
        gettext("Your comment in %{group}", group: group.name),
        """
        #{gettext("Hi %{name},", name: identity.display_name)}

        #{gettext("Your comment in %{group} is submitted and will appear once a moderator approves it.", group: group.name)}

        #{gettext("See your comments and RSVPs, or erase everything we store about you, anytime:")}

        #{manage_url}
        """
      )
    end)
  end

  defp deliver(to_address, subject_line, body) do
    email = base_email(to_address, subject_line, body)

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
