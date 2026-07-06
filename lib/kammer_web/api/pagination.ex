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

  @doc "Clamps a client-supplied limit into [1, #{@max_limit}]."
  @spec limit(map()) :: pos_integer()
  def limit(params) do
    case Integer.parse(to_string(params["limit"] || @default_limit)) do
      {value, ""} when value in 1..@max_limit -> value
      _invalid -> @default_limit
    end
  end
end
