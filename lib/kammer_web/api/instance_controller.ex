defmodule KammerWeb.Api.InstanceController do
  @moduledoc """
  Capability discovery (RFC 0001): clients ask the instance what it is
  and what it can do instead of assuming — the piece that lets one
  multi-instance client talk to servers running different versions.
  """

  use KammerWeb, :controller

  alias Kammer.Communities

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    settings = Communities.get_instance_settings()

    json(conn, %{
      instance_name: settings.instance_name || "Kammer",
      version: Application.spec(:kammer, :vsn) |> to_string(),
      api_versions: ["v1"],
      default_locale: settings.default_locale,
      features: %{
        guest_rsvp: true,
        web_push: true,
        registration: "web_only"
      }
    })
  end
end
