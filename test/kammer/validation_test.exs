defmodule Kammer.ValidationTest do
  @moduledoc """
  The shared email/display-name validators (issue #74's DRY audit)
  used by guest identities, newsletter subscriptions, event/post guest
  requests, and registered users. Each caller keeps its own field
  names, messages, and length limits — these tests cover the shared
  logic itself, not every call site (already covered by each
  context's own tests).
  """

  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias Kammer.Validation

  # `put_change/3` rather than `cast/3` — cast treats an empty-string
  # param as absent by default, which would mask the min-length case.
  defp email_changeset(email) do
    {%{}, %{email: :string}} |> change() |> put_change(:email, email)
  end

  defp display_name_changeset(display_name) do
    {%{}, %{display_name: :string}} |> change() |> put_change(:display_name, display_name)
  end

  describe "validate_email_format/3" do
    test "accepts a well-formed address" do
      assert email_changeset("a@b.com") |> Validation.validate_email_format() |> valid?()
    end

    test "rejects an address without an @ sign" do
      refute email_changeset("not-an-email") |> Validation.validate_email_format() |> valid?()
    end

    test "rejects an address containing whitespace" do
      refute email_changeset("a b@example.com") |> Validation.validate_email_format() |> valid?()
    end

    test "rejects an address over 160 characters" do
      long_email = String.duplicate("a", 156) <> "@b.co"
      assert String.length(long_email) == 161

      refute email_changeset(long_email) |> Validation.validate_email_format() |> valid?()
    end

    test "passes validate_format/4 options through, e.g. a custom message" do
      changeset =
        email_changeset("bad")
        |> Validation.validate_email_format(:email, message: "custom message")

      assert "custom message" in errors_on(changeset, :email)
    end
  end

  describe "validate_display_name_length/3" do
    test "accepts a name within the default 120-character bound" do
      assert display_name_changeset("Alex")
             |> Validation.validate_display_name_length()
             |> valid?()
    end

    test "rejects a blank name" do
      refute display_name_changeset("") |> Validation.validate_display_name_length() |> valid?()
    end

    test "rejects a name over the default bound" do
      refute display_name_changeset(String.duplicate("a", 121))
             |> Validation.validate_display_name_length()
             |> valid?()
    end

    test "respects a caller-supplied max, e.g. User's 100-character bound" do
      name_101_chars = String.duplicate("a", 101)

      refute display_name_changeset(name_101_chars)
             |> Validation.validate_display_name_length(:display_name, 100)
             |> valid?()

      assert display_name_changeset(String.duplicate("a", 100))
             |> Validation.validate_display_name_length(:display_name, 100)
             |> valid?()
    end
  end

  defp valid?(changeset), do: changeset.valid?

  defp errors_on(changeset, field),
    do: Enum.map(Keyword.get_values(changeset.errors, field), &elem(&1, 0))
end
