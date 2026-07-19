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

  defp url_changeset(url) do
    {%{}, %{url: :string}} |> change() |> put_change(:url, url)
  end

  describe "validate_email_format/3" do
    test "accepts a well-formed address, including a Unicode/IDN one" do
      assert email_changeset("a@b.com") |> Validation.validate_email_format() |> valid?()
      # The #334 control-char exclusion is ASCII-only, so non-ASCII local
      # parts and IDN hosts must still pass (this is a Danish-facing app).
      assert email_changeset("bruger@øl.dk") |> Validation.validate_email_format() |> valid?()
    end

    test "rejects control characters, so a value can't pass then 500 at the DB (issue #334)" do
      # A NUL survives a naive format check but raises Postgrex.Error at
      # insert (Postgres text columns reject it) — an unhandled 500 from
      # any JSON body. The shared rule must reject it and its C0/DEL kin.
      refute email_changeset("ab" <> <<0>> <> "@c.d")
             |> Validation.validate_email_format()
             |> valid?()

      refute email_changeset("a@b.c" <> <<0x1F>>)
             |> Validation.validate_email_format()
             |> valid?()

      # DEL (0x7F) is its own literal in the excluded class, so it gets
      # its own guard — dropping it from the regex must fail a test.
      refute email_changeset("a@b.c" <> <<0x7F>>)
             |> Validation.validate_email_format()
             |> valid?()

      # A trailing newline slips past `$`, which matches before a final
      # `\n`; the `\A…\z` anchors close that.
      refute email_changeset("a@b.c\n") |> Validation.validate_email_format() |> valid?()
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

  describe "email_format?/1" do
    test "true for a well-formed address, false for malformed/control-char/nil" do
      assert Validation.email_format?("a@b.com")
      assert Validation.email_format?("bruger@øl.dk")
      refute Validation.email_format?("not-an-email")
      # The guard that keeps a control char out of a raw email lookup
      # (issue #334) — a NUL here would 500 a `where email = ?` query.
      refute Validation.email_format?("x" <> <<0>> <> "@y.z")
      refute Validation.email_format?(nil)
      refute Validation.email_format?(:not_a_string)
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

  # The accepted/rejected matrix lives on `http_url?/1` (the primitive
  # both the changeset validator and every render guard delegate to);
  # the validate_http_url/3 tests below only cover the changeset wiring.
  describe "http_url?/1" do
    test "true for http(s) URLs, including IDN hosts and pasted padding" do
      assert Validation.http_url?("https://example.com/path")
      assert Validation.http_url?("http://example.com")
      assert Validation.http_url?("https://øl.dk")
      assert Validation.http_url?("https://example.com ")
    end

    test "false for executable and scheme-less forms, and nil (issue #247)" do
      refute Validation.http_url?("javascript:alert(1)")
      refute Validation.http_url?("data:text/html,x")
      refute Validation.http_url?("not a url")
      refute Validation.http_url?("//example.com")
      refute Validation.http_url?("https:example.com")
      refute Validation.http_url?(nil)
    end
  end

  describe "validate_http_url/3" do
    test "wires http_url?/1 into a changeset error" do
      assert url_changeset("https://example.com")
             |> Validation.validate_http_url(:url)
             |> valid?()

      changeset = url_changeset("javascript:alert(1)") |> Validation.validate_http_url(:url)
      assert "must be a valid http(s) URL" in errors_on(changeset, :url)
    end

    test "passes through a custom message" do
      changeset =
        url_changeset("javascript:x") |> Validation.validate_http_url(:url, message: "nope")

      assert "nope" in errors_on(changeset, :url)
    end
  end

  defp valid?(changeset), do: changeset.valid?

  defp errors_on(changeset, field),
    do: Enum.map(Keyword.get_values(changeset.errors, field), &elem(&1, 0))
end
