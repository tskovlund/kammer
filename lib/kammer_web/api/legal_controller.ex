defmodule KammerWeb.Api.LegalController do
  @moduledoc """
  Public legal pages over the API (issue #185, SPEC §13): the API twin
  of `LegalLive.Show`. Anyone may read the privacy policy or imprint —
  the operator's published text, or the built-in template until one is
  published. An unknown key answers 404, mirroring the web page's
  not-found redirect. Read-only; editing stays the operator settings
  surface.
  """

  use KammerWeb, :controller

  alias Kammer.Legal
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiError

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"key" => key}) do
    if Legal.valid_key?(key) do
      json(conn, %{data: Serializer.legal_page(key)})
    else
      ApiError.send(conn, :not_found, "Not found.")
    end
  end
end
