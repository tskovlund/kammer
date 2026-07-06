defmodule KammerWeb.InviteController do
  @moduledoc """
  Invite acceptance endpoint for the signed-out flow: requiring
  authentication stores the return path, so after magic-link sign-in the
  user lands back here and the invite is redeemed.
  """

  use KammerWeb, :controller

  import KammerWeb.UserAuth, only: [require_authenticated_user: 2]

  alias Kammer.Invitations
  alias Kammer.Invitations.Invite

  plug :require_authenticated_user

  @doc """
  Redeems the invite for the signed-in user and redirects to the target.
  """
  @spec accept(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def accept(conn, %{"token" => token}) do
    current_user = conn.assigns.current_scope.user

    case Invitations.redeem_invite(current_user, token) do
      {:ok, invite} ->
        conn
        |> put_flash(:info, gettext("Welcome to %{name}!", name: target_name(invite)))
        |> redirect(to: destination(invite))

      {:error, :email_mismatch} ->
        conn
        |> put_flash(
          :error,
          gettext("This invitation was sent to a different email address.")
        )
        |> redirect(to: ~p"/")

      {:error, _reason} ->
        conn
        |> put_flash(:error, gettext("This invitation is no longer valid."))
        |> redirect(to: ~p"/")
    end
  end

  defp target_name(%Invite{group: nil, community: community}), do: community.name
  defp target_name(%Invite{group: group}), do: group.name

  defp destination(%Invite{group: nil, community: community}), do: ~p"/c/#{community.slug}"

  defp destination(%Invite{group: group, community: community}),
    do: ~p"/c/#{community.slug}/g/#{group.slug}"
end
