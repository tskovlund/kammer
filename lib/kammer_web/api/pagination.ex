defmodule KammerWeb.Api.Pagination do
  @moduledoc """
  Opaque cursors (RFC 0001): base64 of `{timestamp, id}` — clients pass
  them back verbatim and never construct them. Opaque by contract so
  the ordering key can change without breaking anyone.
  """

  @default_limit 25
  @max_limit 100

  @doc "Encodes a `{DateTime, id}` cursor for the wire."
  @spec encode({DateTime.t(), Ecto.UUID.t()} | nil) :: String.t() | nil
  def encode(nil), do: nil

  def encode({%DateTime{} = at, id}) do
    Base.url_encode64(Jason.encode!([DateTime.to_iso8601(at), id]), padding: false)
  end

  @doc "Decodes a client cursor; invalid input reads as no cursor."
  @spec decode(String.t() | nil) :: {DateTime.t(), Ecto.UUID.t()} | nil
  def decode(nil), do: nil

  def decode(encoded) when is_binary(encoded) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, [iso, id]} <- Jason.decode(json),
         {:ok, at, _offset} <- DateTime.from_iso8601(iso),
         {:ok, uuid} <- Ecto.UUID.cast(id) do
      {at, uuid}
    else
      _invalid -> nil
    end
  end

  # Phoenix parses `after[]=x` / `after[k]=v` into lists and maps —
  # shapes a hand-crafted query string can always produce, so they must
  # read as "no cursor", never crash the endpoint.
  def decode(_other), do: nil

  @doc """
  Clamps a client-supplied limit into [1, #{@max_limit}]. `default` is
  what an absent or unparsable `limit` falls back to — most endpoints
  want the shared #{@default_limit}, but a couple (the audit log) keep
  a larger pre-existing default (issue #340). The default itself is
  clamped into the same range, so no caller can widen the ceiling.
  """
  @spec limit(map(), pos_integer()) :: pos_integer()
  def limit(params, default \\ @default_limit) do
    default = min(max(default, 1), @max_limit)

    case params["limit"] do
      value when is_binary(value) or is_integer(value) ->
        case Integer.parse(to_string(value)) do
          {parsed, ""} when parsed in 1..@max_limit -> parsed
          _invalid -> default
        end

      # Absent, or a list/map from `limit[]=`-style query strings —
      # anything non-scalar falls back rather than crashing.
      _absent_or_nonscalar ->
        default
    end
  end
end
