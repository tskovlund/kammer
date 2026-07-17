defmodule KammerWeb.Api.AvailabilityController do
  @moduledoc """
  Date-finding polls over the API (RFC 0001, issue #184): list the open
  polls of a community, create a poll in a group, read one, answer a
  candidate date, and close it — plainly, or by converting the winning
  date into a real event. Every decision runs through
  `Kammer.Availability` and `Kammer.Authorization`; the controller adds
  transport, never policy.

  The poll tool is feature-gated per group (`:availability`, ADR 0016):
  a group without it is unreachable — creating 404s, and a poll in a
  since-disabled group 404s to every verb. No-oracle (#156/#161): a poll
  the caller may not see answers 404 (indistinguishable from a
  nonexistent one), while a visible poll the caller may not close/convert
  still 403s.
  """

  use KammerWeb, :controller

  alias Kammer.Authorization
  alias Kammer.Availability
  alias Kammer.Availability.AvailabilityOption
  alias Kammer.Communities
  alias KammerWeb.Api.GroupGate
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiError

  @feature :availability
  @answers ~w(yes if_needed no)

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"community_slug" => slug}) do
    with_community(conn, slug, fn community ->
      user = conn.assigns.current_scope.user
      polls = Availability.list_open_polls(user, community)
      json(conn, %{data: Enum.map(polls, &poll_data(&1, &1.group, user))})
    end)
  end

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"community_slug" => slug, "group_slug" => group_slug} = params) do
    with_feature_group(conn, slug, group_slug, fn _community, group, user ->
      option_starts = parse_option_starts(params["options"])

      with {:ok, poll} <-
             Availability.create_poll(user, group, Map.take(params, ["title"]), option_starts) do
        conn
        |> put_status(201)
        |> json(%{data: poll_data(poll, group, user)})
      end
    end)
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, params) do
    with_poll(conn, params, fn poll, group, user ->
      json(conn, %{data: poll_data(poll, group, user)})
    end)
  end

  @spec respond(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def respond(conn, %{"option_id" => option_id, "answer" => answer} = params)
      when answer in @answers do
    with_poll(conn, params, fn poll, _group, user ->
      with %AvailabilityOption{poll_id: poll_id} = option <- Availability.get_option(option_id),
           true <- poll_id == poll.id,
           {:ok, _response} <- Availability.respond(user, option, String.to_existing_atom(answer)) do
        respond_with_poll(conn, poll.id, user)
      else
        nil -> {:error, :not_found}
        false -> {:error, :not_found}
        error -> error
      end
    end)
  end

  def respond(conn, _params),
    do:
      ApiError.send(
        conn,
        :bad_request,
        "option_id is required and answer must be one of yes, if_needed, no."
      )

  @spec close(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def close(conn, params) do
    with_poll(conn, params, fn poll, _group, user ->
      with {:ok, _closed} <- Availability.close_poll(user, poll) do
        respond_with_poll(conn, poll.id, user)
      end
    end)
  end

  @spec convert(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def convert(conn, %{"option_id" => option_id} = params) do
    with_poll(conn, params, fn poll, _group, user ->
      with %AvailabilityOption{poll_id: poll_id} = option <- Availability.get_option(option_id),
           true <- poll_id == poll.id,
           {:ok, _closed, _event} <- Availability.convert_to_event(user, poll, option) do
        respond_with_poll(conn, poll.id, user)
      else
        nil -> {:error, :not_found}
        false -> {:error, :not_found}
        error -> error
      end
    end)
  end

  def convert(conn, _params),
    do: ApiError.send(conn, :bad_request, "option_id is required.")

  ## Internals

  defp poll_data(poll, group, user) do
    Serializer.availability_poll(poll, user, group, Authorization.relationship(user, group))
  end

  # Candidate dates arrive as ISO 8601 strings; invalid entries are
  # dropped, and an empty result lets the context answer :no_options.
  defp parse_option_starts(options) when is_list(options) do
    options
    |> Enum.map(&parse_datetime/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_option_starts(_options), do: []

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _invalid -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp with_community(conn, slug, fun) do
    case Communities.get_community_by_slug(slug) do
      nil -> ApiError.send(conn, :not_found, "Not found.")
      community -> fun.(community)
    end
  end

  # No-oracle (#156/#161, #339): a missing community, a missing group,
  # a group the caller may not even *view*, and a group with the tool
  # off all fold into the same 404 via `GroupGate.fetch/4`.
  defp with_feature_group(conn, community_slug, group_slug, fun) do
    user = conn.assigns.current_scope.user

    case GroupGate.fetch(user, community_slug, group_slug, feature: @feature) do
      {:ok, community, group} -> fun.(community, group, user)
      {:error, :not_found} -> ApiError.send(conn, :not_found, "Not found.")
    end
  end

  # The shared head of every poll-addressed request: resolve the poll
  # exactly as the caller sees it (feature-gated, view-checked), confirm
  # it lives in the addressed community, then run the callback. A hidden
  # or foreign poll 404s before any write check runs.
  defp with_poll(conn, %{"community_slug" => slug, "poll_id" => poll_id}, fun) do
    with_community(conn, slug, fn community ->
      user = conn.assigns.current_scope.user

      with {:ok, poll, group} <- fetch_visible_poll(user, poll_id),
           true <- poll.community_id == community.id,
           %Plug.Conn{} = responded <- fun.(poll, group, user) do
        responded
      else
        false -> ApiError.send(conn, :not_found, "Not found.")
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  defp fetch_visible_poll(user, poll_id) do
    case Availability.fetch_viewable_poll(user, poll_id) do
      {:error, :unauthorized} -> {:error, :not_found}
      other -> other
    end
  end

  defp respond_with_poll(conn, poll_id, user) do
    case fetch_visible_poll(user, poll_id) do
      {:ok, poll, group} -> json(conn, %{data: poll_data(poll, group, user)})
      error -> ApiError.from_result(conn, error)
    end
  end
end
