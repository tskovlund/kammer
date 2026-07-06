defmodule Kammer.Events.EventNotifier do
  @moduledoc """
  Event emails (SPEC §6): reminders with an ICS attachment, localized to
  the recipient.
  """

  use Gettext, backend: KammerWeb.Gettext

  import Swoosh.Email

  alias Kammer.Accounts.User
  alias Kammer.Calendar.ICS
  alias Kammer.Events.Event
  alias Kammer.Mailer

  @doc """
  Delivers a reminder for an event starting within a day.
  """
  @spec deliver_reminder(User.t(), Event.t()) :: {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_reminder(%User{} = user, %Event{} = event) do
    Gettext.with_locale(KammerWeb.Gettext, user.locale, fn ->
      local_start =
        case DateTime.shift_zone(event.starts_at, user.timezone) do
          {:ok, shifted} -> shifted
          {:error, _reason} -> event.starts_at
        end

      email =
        new()
        |> to(user.email)
        |> from(mail_from())
        |> subject(gettext("Reminder: %{title}", title: event.title))
        |> text_body("""
        #{gettext("Hi %{name},", name: user.display_name)}

        #{gettext("%{title} starts %{time}.", title: event.title, time: Calendar.strftime(local_start, "%Y-%m-%d %H:%M"))}

        #{event.location_name || ""}
        """)
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

  defp mail_from do
    from_config = Application.get_env(:kammer, :mail_from, [])
    product_name = Application.get_env(:kammer, :product_name, "Kammer")

    {Keyword.get(from_config, :name, product_name),
     Keyword.get(from_config, :address, "kammer@localhost")}
  end
end
