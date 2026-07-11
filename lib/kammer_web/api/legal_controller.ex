defmodule KammerWeb.Api.LegalController do
  @moduledoc """
  Legal pages over the API (issues #185/#259, SPEC §13): the API twin
  of `LegalLive.Show`/`LegalLive.Edit`. Anyone may read the privacy
  policy or imprint — the operator's published text, or the built-in
  template until one is published. Editing is instance-operator only,
  enforced by `Kammer.Legal.upsert_page/3`. An unknown key answers 404
  to both verbs, mirroring the web page's not-found redirect.
  """

  use KammerWeb, :controller

  alias Kammer.Legal
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiError

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"key" => key}) do
    with_valid_key(conn, key, fn -> json(conn, %{data: Serializer.legal_page(key)}) end)
  end

  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"key" => key} = params) do
    with_valid_key(conn, key, fn ->
      user = conn.assigns.current_scope.user

      case Legal.upsert_page(user, key, Map.take(params, ["content_markdown"])) do
        # Serialize through the same read path the GET uses, so the
        # answer carries the freshly rendered HTML and published flag.
        {:ok, _page} -> json(conn, %{data: Serializer.legal_page(key)})
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  defp with_valid_key(conn, key, fun) do
    if Legal.valid_key?(key) do
      fun.()
    else
      ApiError.send(conn, :not_found, "Not found.")
    end
  end
end
