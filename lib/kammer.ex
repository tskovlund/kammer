defmodule Kammer do
  @moduledoc """
  Kammer keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  @doc """
  The product version this instance is built from.

  `mix.exs` is the single source of truth (issue #204); runtime code
  reads it from the loaded application spec instead of hardcoding it
  anywhere else.
  """
  @spec version() :: String.t()
  def version do
    Application.spec(:kammer, :vsn) |> to_string()
  end

  @doc """
  The advertised minimum client version — the native-app handshake
  foundation (issues #203/#204). This is the deliberate seam the
  future handshake plugs into; it exists now so the field is stable in
  the API contract before native work starts (#131).

  Advisory, not enforced: the server never rejects a client over it.
  Clients compare their own version against this SemVer floor and
  fence themselves (prompt for an update, degrade, or refuse). `nil` —
  the default, and what an unset `MIN_CLIENT_VERSION` env var yields
  (`config/runtime.exs`) — means any client is fine. A release that
  needs to fence out old clients sets `MIN_CLIENT_VERSION=x.y.z`.
  """
  @spec min_client_version() :: String.t() | nil
  def min_client_version do
    Application.get_env(:kammer, :min_client_version)
  end

  @doc """
  The instance's display name (SPEC §15), shown in emails, page
  titles, and the PWA shell. `config/config.exs` sets the `"Kammer"`
  default; this is the one place that reads it, so renaming the
  product is a single-config-key change instead of re-typing the
  fallback at every call site (issue #234).
  """
  @spec product_name() :: String.t()
  def product_name do
    Application.get_env(:kammer, :product_name, "Kammer")
  end
end
