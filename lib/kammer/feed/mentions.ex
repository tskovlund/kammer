defmodule Kammer.Feed.Mentions do
  @moduledoc """
  Mention extraction (SPEC §5): `@everyone` and `@admins` are recognized
  as broadcast mentions (`@everyone` is gated to users with broadcast
  rights and rate-limited at post creation); `@Display Name` user
  mentions are resolved against group members at notification time.
  """

  @everyone_pattern ~r/(^|\W)@everyone(\W|$)/u
  @admins_pattern ~r/(^|\W)@admins(\W|$)/u

  @doc """
  Extracts broadcast mentions from a Markdown body.
  """
  @spec extract(String.t() | nil) :: %{everyone: boolean(), admins: boolean()}
  def extract(nil), do: %{everyone: false, admins: false}

  def extract(markdown) when is_binary(markdown) do
    %{
      everyone: Regex.match?(@everyone_pattern, markdown),
      admins: Regex.match?(@admins_pattern, markdown)
    }
  end
end
