defmodule KammerWeb.Api.LegalController do
  @moduledoc """
  Legal pages over the API (issues #185/#259, SPEC §13): the API twin
  of `LegalLive.Show`/`LegalLive.Edit`. Anyone may read the privacy
  policy or imprint — the operator's published text, or the built-in
  template until one is published. Editing is instance-operator only,
  enforced by `Kammer.Legal.upsert_page/4`. An unknown key answers 404
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
      expected_version = lock_version(params["lock_version"])

      case Legal.upsert_page(user, key, Map.take(params, ["content_markdown"]), expected_version) do
        # Serialize through the same read path the GET uses, so the
        # answer carries the freshly rendered HTML and published flag.
        {:ok, _page} -> json(conn, %{data: Serializer.legal_page(key)})
        # A stale write (another operator saved first) folds to a 409
        # through `ApiError.from_result/2`.
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

  # The largest value the `int4` `lock_version` column can hold; a request
  # value past it would raise a Postgrex encode error (a 500) at the
  # optimistic-lock WHERE clause instead of a clean conflict (#276 item 4).
  @max_lock_version 2_147_483_647

  # The `lock_version` the editor last read (#276 item 4). A missing, malformed,
  # or out-of-range value defaults to 0 — the template/unpublished version —
  # which can never match a published row (those start at 1), so a versionless
  # or bogus write to an existing page safely conflicts (409) instead of
  # silently clobbering or, for an out-of-int4-range value, 500ing.
  defp lock_version(version)
       when is_integer(version) and version >= 0 and version <= @max_lock_version,
       do: version

  defp lock_version(version) when is_binary(version) do
    case Integer.parse(version) do
      {parsed, ""} -> lock_version(parsed)
      _ -> 0
    end
  end

  defp lock_version(_version), do: 0
end
