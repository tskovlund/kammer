defmodule Kammer.SetupTest do
  # async: false — the setup token lives in :persistent_term and the
  # env-wins test mutates OS environment variables.
  use Kammer.DataCase, async: false

  import Kammer.AccountsFixtures

  alias Kammer.Accounts
  alias Kammer.Communities
  alias Kammer.Repo
  alias Kammer.Setup
  alias Kammer.Setup.DemoData

  @env_keys ~w(INSTANCE_NAME DEFAULT_LOCALE COMMUNITY_CREATION_POLICY OPERATOR_EMAIL)

  defp operator_fixture do
    user_fixture()
    |> Ecto.Changeset.change(instance_operator: true)
    |> Repo.update!()
  end

  defp drain_emails do
    receive do
      {:email, _email} -> drain_emails()
    after
      0 -> :ok
    end
  end

  describe "setup token" do
    test "ensure_setup_token is stable and verifies" do
      token = Setup.ensure_setup_token()

      assert Setup.ensure_setup_token() == token
      assert Setup.valid_token?(token)
      refute Setup.valid_token?("not-the-token")
      refute Setup.valid_token?(nil)
    end
  end

  describe "initialize/0 — env always wins (SPEC §13)" do
    test "applies environment-provided settings and promotes the operator" do
      System.put_env("INSTANCE_NAME", "Env Instance")
      System.put_env("DEFAULT_LOCALE", "da")
      System.put_env("COMMUNITY_CREATION_POLICY", "any_user")
      System.put_env("OPERATOR_EMAIL", "boss@example.org")
      on_exit(fn -> Enum.each(@env_keys, &System.delete_env/1) end)

      assert :ok = Setup.initialize()

      settings = Communities.get_instance_settings()
      assert settings.instance_name == "Env Instance"
      assert settings.default_locale == "da"
      assert settings.community_creation_policy == :any_user

      operator = Accounts.get_user_by_email("boss@example.org")
      assert operator.instance_operator
    end

    test "leaves settings alone when the environment provides nothing" do
      Enum.each(@env_keys, &System.delete_env/1)

      assert :ok = Setup.initialize()

      settings = Communities.get_instance_settings()
      assert settings.instance_name == nil
      assert settings.community_creation_policy == :operators_only
    end
  end

  describe "complete/2" do
    @complete_attrs %{
      "operator" => %{"email" => "op@example.org", "display_name" => "The Operator"},
      "instance" => %{"instance_name" => "Kammeret", "default_locale" => "en"},
      "community" => %{"name" => "First Community", "slug" => "first"},
      "group" => %{"name" => "General", "slug" => "general"},
      "demo_data" => "true"
    }

    test "creates everything in one go, locks setup, and emails the magic link" do
      drain_emails()

      assert {:ok, result} =
               Setup.complete(@complete_attrs, &("http://localhost/users/log-in/" <> &1))

      assert Setup.completed?()
      assert result.community_slug == "first"
      assert result.group_slug == "general"
      assert is_binary(result.invite_token)

      operator = Accounts.get_user_by_email("op@example.org")
      assert operator.instance_operator
      assert operator.display_name == "The Operator"

      settings = Communities.get_instance_settings()
      assert settings.instance_name == "Kammeret"
      assert settings.setup_completed_at
      assert settings.demo_community_id, "demo data was requested"

      community = Communities.get_community_by_slug("first")
      assert Communities.get_membership(community, operator).role == :owner

      # The operator's first magic link doubles as the SMTP test.
      assert_receive {:email, %Swoosh.Email{to: [{_name, "op@example.org"}]}}

      # The wizard locks permanently: token gone, second run refused.
      refute Setup.valid_token?("anything")
      assert {:error, :already_completed} = Setup.complete(@complete_attrs, & &1)
    end

    test "requires an operator email" do
      attrs = Map.put(@complete_attrs, "operator", %{})
      assert {:error, :operator_email_required} = Setup.complete(attrs, & &1)
      refute Setup.completed?()
    end

    test "rolls back completely on invalid community input" do
      attrs = put_in(@complete_attrs["community"], %{"name" => "Bad", "slug" => "!!"})

      assert {:error, %Ecto.Changeset{}} = Setup.complete(attrs, & &1)
      refute Setup.completed?()
      assert Accounts.get_user_by_email("op@example.org") == nil
    end
  end

  describe "demo data" do
    test "create builds a browsable community and is idempotent" do
      operator = operator_fixture()

      assert {:ok, community} = DemoData.create(operator)
      assert {:ok, same} = DemoData.create(operator)
      assert same.id == community.id

      settings = Communities.get_instance_settings()
      assert settings.demo_community_id == community.id

      [group] = Repo.preload(community, :groups).groups
      assert group.slug == "welcome"

      posts = Repo.all(Kammer.Feed.Post)
      assert length(posts) == 2
      assert Repo.aggregate(Kammer.Feed.Poll, :count) == 1
      assert Repo.aggregate(Kammer.Events.Event, :count) == 1
    end

    test "purge deletes the community and clears the reference" do
      operator = operator_fixture()
      plain_user = user_fixture()

      {:ok, community} = DemoData.create(operator)

      assert {:error, :unauthorized} = DemoData.purge(plain_user)
      assert {:ok, _community} = DemoData.purge(operator)

      assert Repo.get(Kammer.Communities.Community, community.id) == nil
      assert Communities.get_instance_settings().demo_community_id == nil
      assert {:error, :no_demo_community} = DemoData.purge(operator)
    end
  end
end
