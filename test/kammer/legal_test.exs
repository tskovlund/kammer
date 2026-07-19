defmodule Kammer.LegalTest do
  use Kammer.DataCase, async: true

  import Kammer.AccountsFixtures

  alias Kammer.Legal
  alias Kammer.Repo

  defp operator_fixture do
    user_fixture()
    |> Ecto.Changeset.change(instance_operator: true)
    |> Repo.update!()
  end

  test "valid keys are exactly privacy and imprint" do
    assert Legal.keys() == ["privacy", "imprint"]
    assert Legal.valid_key?("privacy")
    refute Legal.valid_key?("terms")
  end

  test "unpublished pages fall back to the built-in template" do
    refute Legal.published?("imprint")

    page = Legal.get_page("imprint")
    assert page.id == nil
    assert page.content_markdown =~ "template"
  end

  test "operators publish their own text; others may not" do
    operator = operator_fixture()
    plain_user = user_fixture()

    assert {:error, :unauthorized} =
             Legal.upsert_page(plain_user, "imprint", %{"content_markdown" => "Mine now"}, 0)

    assert {:ok, page} =
             Legal.upsert_page(
               operator,
               "imprint",
               %{"content_markdown" => "## Responsible\n\nThe Kammer Club, Aarhus."},
               0
             )

    assert Legal.published?("imprint")
    assert Legal.get_page("imprint").id == page.id
    assert Legal.get_page("imprint").content_markdown =~ "Kammer Club"

    # Updating replaces in place — still one row — at the current version.
    assert {:ok, _page} =
             Legal.upsert_page(operator, "imprint", %{"content_markdown" => "Updated."}, 1)

    assert Repo.aggregate(Kammer.Legal.LegalPage, :count) == 1
  end

  test "content cannot be emptied out" do
    operator = operator_fixture()

    assert {:error, changeset} =
             Legal.upsert_page(operator, "privacy", %{"content_markdown" => ""}, 0)

    assert %{content_markdown: _messages} = errors_on(changeset)
  end

  test "updated_by_user_id is set by the context, never cast from the body (#276)" do
    operator = operator_fixture()

    # The context records who edited.
    assert {:ok, page} =
             Legal.upsert_page(operator, "privacy", %{"content_markdown" => "Ours."}, 0)

    assert page.updated_by_user_id == operator.id

    # And the changeset never casts the field, so a crafted body can't spoof
    # the attribution for any caller (the load-bearing guard).
    attacker = user_fixture()

    changeset =
      Kammer.Legal.LegalPage.changeset(%Kammer.Legal.LegalPage{key: "privacy"}, %{
        "content_markdown" => "x",
        "updated_by_user_id" => attacker.id
      })

    refute Ecto.Changeset.get_change(changeset, :updated_by_user_id)
  end

  describe "optimistic concurrency (#276 item 4)" do
    test "the template reports version 0; a first publish lands at 1; each edit bumps" do
      operator = operator_fixture()

      assert Legal.get_page("privacy").lock_version == 0

      assert {:ok, published} =
               Legal.upsert_page(operator, "privacy", %{"content_markdown" => "First"}, 0)

      assert published.lock_version == 1

      assert {:ok, edited} =
               Legal.upsert_page(operator, "privacy", %{"content_markdown" => "Second"}, 1)

      assert edited.lock_version == 2
      assert Legal.get_page("privacy").lock_version == 2
    end

    test "an edit whose version is behind the stored one is refused via the lock, not applied" do
      operator = operator_fixture()

      {:ok, _v1} = Legal.upsert_page(operator, "privacy", %{"content_markdown" => "First"}, 0)
      {:ok, _v2} = Legal.upsert_page(operator, "privacy", %{"content_markdown" => "Second"}, 1)

      # A second operator still holding version 1 saves — the stored version is
      # now 2, so `optimistic_lock` matches no row (WHERE lock_version = 1),
      # Ecto raises StaleEntryError, and it folds to :stale. This is the
      # load-bearing branch: it exercises the actual lock, not a pre-check.
      assert {:error, :stale} =
               Legal.upsert_page(operator, "privacy", %{"content_markdown" => "Racing"}, 1)

      assert Legal.get_page("privacy").content_markdown == "Second"
    end

    test "an operator editing from the template when a page already exists conflicts" do
      operator = operator_fixture()

      # A first publish lands (row now at version 1).
      {:ok, _winner} =
        Legal.upsert_page(operator, "imprint", %{"content_markdown" => "Winner"}, 0)

      # A second operator was still editing the built-in template (version 0);
      # publishing must conflict rather than silently overwrite the live text —
      # their expected 0 no longer matches the stored 1. (The other race, two
      # truly simultaneous first inserts, is caught by the unique key in
      # `first_publish`; see the note there.)
      assert {:error, :stale} =
               Legal.upsert_page(operator, "imprint", %{"content_markdown" => "Loser"}, 0)

      assert Legal.get_page("imprint").content_markdown == "Winner"
    end

    test "invalid content on an existing page is a validation error even with a stale version" do
      operator = operator_fixture()

      {:ok, _v1} = Legal.upsert_page(operator, "privacy", %{"content_markdown" => "First"}, 0)
      {:ok, _v2} = Legal.upsert_page(operator, "privacy", %{"content_markdown" => "Second"}, 1)

      # Empty content AND a stale version (stored is 2): the changeset validation
      # short-circuits before optimistic_lock runs, so the caller gets a
      # changeset error (422), not :stale (409) — content wins over the lock.
      assert {:error, %Ecto.Changeset{}} =
               Legal.upsert_page(operator, "privacy", %{"content_markdown" => ""}, 1)
    end
  end
end
