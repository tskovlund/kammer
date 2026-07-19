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
             Legal.upsert_page(plain_user, "imprint", %{"content_markdown" => "Mine now"})

    assert {:ok, page} =
             Legal.upsert_page(operator, "imprint", %{
               "content_markdown" => "## Responsible\n\nThe Kammer Club, Aarhus."
             })

    assert Legal.published?("imprint")
    assert Legal.get_page("imprint").id == page.id
    assert Legal.get_page("imprint").content_markdown =~ "Kammer Club"

    # Updating replaces in place — still one row.
    assert {:ok, _page} =
             Legal.upsert_page(operator, "imprint", %{"content_markdown" => "Updated."})

    assert Repo.aggregate(Kammer.Legal.LegalPage, :count) == 1
  end

  test "content cannot be emptied out" do
    operator = operator_fixture()

    assert {:error, changeset} =
             Legal.upsert_page(operator, "privacy", %{"content_markdown" => ""})

    assert %{content_markdown: _messages} = errors_on(changeset)
  end

  test "updated_by_user_id is set by the context, never cast from the body (#276)" do
    operator = operator_fixture()

    # The context records who edited.
    assert {:ok, page} =
             Legal.upsert_page(operator, "privacy", %{"content_markdown" => "Ours."})

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
end
