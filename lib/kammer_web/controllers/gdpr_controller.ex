defmodule KammerWeb.GdprController do
  @moduledoc """
  Self-serve data export (SPEC §12): streams the signed-in user's
  complete export zip. No admin involvement, no waiting queue — the
  data is theirs.
  """

  use KammerWeb, :controller

  @spec export(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def export(conn, _params) do
    user = conn.assigns.current_scope.user

    case Kammer.Gdpr.export(user) do
      {:ok, zip_path} ->
        conn
        |> send_download({:file, zip_path},
          filename: "kammer-export-#{Date.to_iso8601(Date.utc_today())}.zip"
        )

      {:error, _reason} ->
        conn
        |> put_flash(:error, gettext("The export failed — please try again."))
        |> redirect(to: ~p"/users/settings")
    end
  end
end
