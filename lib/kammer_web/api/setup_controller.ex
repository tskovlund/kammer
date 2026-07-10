defmodule KammerWeb.Api.SetupController do
  @moduledoc """
  First-run setup over the API (issue #185, SPEC §13, ADR 0010): the
  API twin of `SetupLive.Wizard`. It exposes the *existing* setup flow
  and its *existing* operator-bootstrap credential — the setup token
  printed to the server logs at boot (`Kammer.Setup.ensure_setup_token/0`,
  verified in constant time by `Kammer.Setup.valid_token?/1`). No new
  secret, no Bearer scheme: guests and pre-setup operators hold no
  device token, so these routes live in the public `:api` pipeline.

  `status` reports whether setup is done (the same bit the browser's
  `require_setup` redirect reveals — not a secret); `complete` runs the
  one-shot `Kammer.Setup.complete/2` transaction — operator account,
  instance settings, first community and group, invite link, optional
  demo data — and locks setup. There is deliberately no separate
  token-check endpoint (issue #230): it would be a boolean oracle over
  the setup credential, and `complete` already validates the token
  server-side on every submission, so the wizard validates on submit
  instead of pre-flighting a check. `complete` is also rate-limited per
  IP (`Kammer.RateLimit.hit_setup_ip/1`) as defense-in-depth for the
  pre-setup window, when the instance otherwise has no operator around
  to notice abuse.

  Once `setup_completed_at` is set, the token is erased from
  `:persistent_term`, so `valid_token?` returns false forever and
  `complete` answers a neutral 403 for any further attempt.
  """

  use KammerWeb, :controller

  alias Kammer.RateLimit
  alias Kammer.Setup
  alias KammerWeb.Api.PublicLinks
  alias KammerWeb.ApiError

  @spec status(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def status(conn, _params) do
    json(conn, %{setup_completed: Setup.completed?()})
  end

  @spec complete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def complete(conn, params) do
    # Every completion attempt burns per-IP budget before the body is
    # even inspected — a malformed or token-less body must not be a
    # free way around the limiter.
    case RateLimit.hit_setup_ip(conn.remote_ip) do
      {:allow, _count} -> attempt_completion(conn, params)
      {:deny, _retry_after} -> ApiError.from_result(conn, {:error, :rate_limited})
    end
  end

  defp attempt_completion(conn, %{"token" => token} = params) when is_binary(token) do
    # The setup token is the whole credential; a bad one is refused
    # with one neutral answer (also covers the post-completion case
    # — the token is erased on lock, so this can never re-open a
    # live instance).
    if Setup.valid_token?(String.trim(token)) do
      run_completion(conn, params)
    else
      ApiError.send(conn, :forbidden, "Setup is not available.")
    end
  end

  defp attempt_completion(conn, _params),
    do: ApiError.send(conn, :bad_request, "A setup token is required.")

  defp run_completion(conn, params) do
    case Setup.complete(build_attrs(params), &PublicLinks.sign_in_url(conn, &1)) do
      {:ok, result} ->
        conn
        |> put_status(201)
        |> json(%{
          data: %{
            community_slug: result.community_slug,
            group_slug: result.group_slug,
            invite_token: result.invite_token,
            invite_url: url(~p"/invite/#{result.invite_token}"),
            magic_link_sent: result.magic_link_sent
          }
        })

      {:error, :operator_email_required} ->
        ApiError.send(conn, :unprocessable, "An operator email is required.")

      {:error, :already_completed} ->
        ApiError.send(conn, :forbidden, "Setup is not available.")

      error ->
        ApiError.from_result(conn, error)
    end
  end

  # Reshapes the JSON body into the attrs `Kammer.Setup.complete/2`
  # already expects — the same map `SetupLive.Wizard` builds, so the
  # context path is identical for both transports. The community
  # inherits the instance's chosen locale exactly as the wizard does,
  # and the checkbox-shaped `demo_data == "true"` flag is derived from a
  # plain JSON boolean.
  defp build_attrs(params) do
    instance = Map.get(params, "instance", %{})

    %{
      "operator" => Map.take(Map.get(params, "operator", %{}), ~w(email display_name)),
      "instance" =>
        Map.take(instance, ~w(instance_name default_locale community_creation_policy)),
      "community" =>
        params
        |> Map.get("community", %{})
        |> Map.take(~w(name slug accent_color))
        |> Map.put("default_locale", instance["default_locale"]),
      "group" => Map.take(Map.get(params, "group", %{}), ~w(name slug)),
      "demo_data" => if(params["demo_data"] == true, do: "true", else: "false")
    }
  end
end
