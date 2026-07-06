defmodule KammerWeb.GuestCommentController do
  @moduledoc """
  Lands the guest's emailed confirm link for a comment (SPEC §3
  `members_and_guests`): creates the comment awaiting moderation and
  returns the guest to the post's group. Invalid or expired tokens get
  a friendly dead end — no information about why.
  """

  use KammerWeb, :controller

  alias Kammer.Feed

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

  defp confirmed_path(post) do
    group = Kammer.Repo.get(Kammer.Groups.Group, post.group_id)

    community =
      group && Kammer.Repo.get(Kammer.Communities.Community, group.community_id)

    if community && group do
      ~p"/c/#{community.slug}/g/#{group.slug}"
    else
      ~p"/"
    end
  end
end
