defmodule KammerWeb.NewsletterController do
  @moduledoc """
  Lands the emailed newsletter confirm link (SPEC §8) and the
  unsubscribe links every delivery carries — the plain GET a human
  might click, and the RFC 8058 one-click POST a mail client fires
  with no session at all. Invalid or expired tokens get a friendly
  dead end; the one-click endpoint always answers 200 regardless, so
  it never leaks whether a token was valid.
  """

  use KammerWeb, :controller

  alias Kammer.Newsletters

  @spec confirm(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def confirm(conn, %{"token" => token}) do
    case Newsletters.confirm_subscription(token, fn manage_token ->
           url(~p"/guest/manage/#{manage_token}")
         end) do
      {:ok, group, _subscription} ->
        conn
        |> put_flash(
          :info,
          gettext("Subscribed — we emailed you a link to change or cancel it anytime.")
        )
        |> redirect(to: group_path(group))

      {:error, :invalid} ->
        conn
        |> put_flash(:error, gettext("That link is invalid or has expired."))
        |> redirect(to: ~p"/")
    end
  end

  @spec unsubscribe(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def unsubscribe(conn, %{"token" => token, "subscription_id" => subscription_id}) do
    Newsletters.unsubscribe_by_token(token, subscription_id)

    conn
    |> put_flash(:info, gettext("You're unsubscribed."))
    |> redirect(to: ~p"/")
  end

  @spec unsubscribe_one_click(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def unsubscribe_one_click(conn, %{"token" => token, "subscription_id" => subscription_id}) do
    Newsletters.unsubscribe_by_token(token, subscription_id)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "Unsubscribed.")
  end

  defp group_path(group) do
    case Kammer.Repo.get(Kammer.Communities.Community, group.community_id) do
      nil -> ~p"/"
      community -> ~p"/c/#{community.slug}/g/#{group.slug}"
    end
  end
end
