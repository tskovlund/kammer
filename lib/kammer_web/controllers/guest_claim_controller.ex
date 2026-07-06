defmodule KammerWeb.GuestClaimController do
  @moduledoc """
  Lands the guest's emailed confirm link for a signup-slot claim
  (issue #37): records the claim — capacity re-checked — and returns
  the guest to the event. Invalid or expired tokens get a friendly
  dead end; a slot that filled up in the meantime says so honestly.
  """

  use KammerWeb, :controller

  alias Kammer.Events

  @spec confirm(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def confirm(conn, %{"token" => token}) do
    case Events.confirm_guest_claim(token, fn manage_token ->
           url(~p"/guest/manage/#{manage_token}")
         end) do
      {:ok, event, identity} ->
        conn
        |> put_flash(
          :info,
          gettext("Thanks %{name} — you're signed up. We emailed you a link to manage it.",
            name: identity.display_name
          )
        )
        |> redirect(to: event_path(event))

      {:error, :slot_full} ->
        conn
        |> put_flash(:error, gettext("Sorry — that slot filled up in the meantime."))
        |> redirect(to: ~p"/")

      {:error, :invalid} ->
        conn
        |> put_flash(:error, gettext("That link is invalid or has expired."))
        |> redirect(to: ~p"/")
    end
  end

  defp event_path(event) do
    case Kammer.Repo.get(Kammer.Communities.Community, event.community_id) do
      nil -> ~p"/"
      community -> ~p"/c/#{community.slug}/events/#{event.id}"
    end
  end
end
