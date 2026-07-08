defmodule KammerWeb.GuestCommentController do
  @moduledoc """
  Lands the guest's emailed confirm link for a comment (SPEC §3
  `members_and_guests`): creates the comment awaiting moderation and
  returns the guest to the post's group. Invalid or expired tokens get
  a friendly dead end — no information about why.
  """

  use KammerWeb, :controller

  alias Kammer.Communities.Community
  alias Kammer.Feed
  alias Kammer.Feed.Post
  alias Kammer.Groups.Group

  @spec confirm(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def confirm(conn, %{"token" => token}) do
    case Feed.confirm_guest_comment(token, fn manage_token ->
           url(~p"/guest/manage/#{manage_token}")
         end) do
      {:ok, post, identity} ->
        conn
        |> put_flash(
          :info,
          gettext(
            "Thanks %{name} — your comment is submitted and will appear once a moderator approves it.",
            name: identity.display_name
          )
        )
        |> redirect(to: confirmed_path(post))

      {:error, :invalid} ->
        conn
        |> put_flash(:error, gettext("That link is invalid or has expired."))
        |> redirect(to: ~p"/")
    end
  end

  defp confirmed_path(%Post{group: %Group{}, community: %Community{}} = post) do
    ~p"/c/#{post.community.slug}/g/#{post.group.slug}"
  end

  defp confirmed_path(_post), do: ~p"/"
end
