defmodule KammerWeb.GuestRsvpController do
  @moduledoc """
  Lands the guest's emailed confirm link (SPEC §6): records the RSVP
  and hands over to the management page. Invalid or expired tokens get
  a friendly dead end — no information about why.
  """

  use KammerWeb, :controller

  alias Kammer.Events
  alias KammerWeb.GuestPaths

  @spec confirm(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def confirm(conn, %{"token" => token}) do
    case Events.confirm_guest_rsvp(token, fn manage_token ->
           url(~p"/guest/manage/#{manage_token}")
         end) do
      {:ok, event, identity} ->
        conn
        |> put_flash(
          :info,
          gettext(
            "Thanks %{name} — your RSVP to %{title} is confirmed. We emailed you a calendar file and a link to change it.",
            name: identity.display_name,
            title: event.title
          )
        )
        |> redirect(to: GuestPaths.event_path(event))

      {:error, :invalid} ->
        conn
        |> put_flash(:error, gettext("That link is invalid or has expired."))
        |> redirect(to: ~p"/")
    end
  end
end
