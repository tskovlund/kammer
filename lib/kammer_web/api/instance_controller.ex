defmodule KammerWeb.Api.InstanceController do
  @moduledoc """
  Capability discovery (RFC 0001): clients ask the instance what it is
  and what it can do instead of assuming — the piece that lets one
  multi-instance client talk to servers running different versions.

  The operator settings surface (issue #183) rides here too: reading and
  updating the singleton instance settings, gated to instance operators
  by `Kammer.Authorization` through `Communities.update_instance_settings/2`.
  """

  use KammerWeb, :controller

  alias Kammer.Authorization
  alias Kammer.Communities
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiError

  # The operator-editable settings; the update-check bookkeeping columns
  # and setup timestamp are written by their own flows, never the API.
  @settings_fields ~w(instance_name default_locale community_creation_policy storage_policy content_minimized_emails)

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    settings = Communities.get_instance_settings()

    json(conn, %{
      instance_name: settings.instance_name || "Kammer",
      version: Kammer.version(),
      api_versions: ["v1"],
      min_client_version: Kammer.min_client_version(),
      default_locale: settings.default_locale,
      features: %{
        guest_rsvp: true,
        web_push: true,
        registration: "open"
      }
    })
  end

  @spec settings(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def settings(conn, _params) do
    user = conn.assigns.current_scope.user

    if Authorization.instance_operator?(user) do
      json(conn, %{data: Serializer.instance_settings(Communities.get_instance_settings())})
    else
      ApiError.send(conn, :forbidden, "You are not allowed to do that.")
    end
  end

  @spec update_settings(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_settings(conn, params) do
    user = conn.assigns.current_scope.user

    case Communities.update_instance_settings(user, Map.take(params, @settings_fields)) do
      {:ok, settings} -> json(conn, %{data: Serializer.instance_settings(settings)})
      error -> ApiError.from_result(conn, error)
    end
  end
end
