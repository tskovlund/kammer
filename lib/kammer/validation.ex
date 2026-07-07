defmodule Kammer.Validation do
  @moduledoc """
  Shared changeset validators for fields duplicated across every
  contact-only actor in the product: guest identities, newsletter
  subscribers, and event/post guest requests, plus registered users.
  Deliberately narrow — just the format/length rules, not
  normalization (e.g. downcasing email), since not every caller wants
  the same normalization.
  """

  import Ecto.Changeset

  @email_format ~r/^[^@,;\s]+@[^@,;\s]+$/

  @doc """
  Validates `field` is a well-formed email address, at most 160
  characters. Accepts the same options as `validate_format/4` (e.g.
  `:message`).
  """
  @spec validate_email_format(Ecto.Changeset.t(), atom(), keyword()) :: Ecto.Changeset.t()
  def validate_email_format(changeset, field \\ :email, opts \\ []) do
    changeset
    |> validate_format(field, @email_format, opts)
    |> validate_length(field, max: 160)
  end

  @doc """
  Validates `field` is a non-blank display name of at most `max`
  characters (120 by default).
  """
  @spec validate_display_name_length(Ecto.Changeset.t(), atom(), pos_integer()) ::
          Ecto.Changeset.t()
  def validate_display_name_length(changeset, field \\ :display_name, max \\ 120) do
    validate_length(changeset, field, min: 1, max: max)
  end
end
