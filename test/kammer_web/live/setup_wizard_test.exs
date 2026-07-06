defmodule KammerWeb.SetupWizardTest do
  @moduledoc """
  The ground-truth first-run flow (SPEC §13, §16.8): fresh instance →
  setup gate → token → wizard → invite link → an invited member joins
  and posts in the first group.
  """

  # async: false — the setup token lives in :persistent_term.
  use KammerWeb.ConnCase, async: false

  import Kammer.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Kammer.Setup

  @moduletag :setup_pending

  describe "the setup gate" do
    test "redirects all ordinary routes to /setup until completed", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/")) == "/setup"
      assert redirected_to(get(conn, ~p"/users/log-in")) == "/setup"
    end

    test "leaves exempt routes reachable", %{conn: conn} do
      assert get(conn, ~p"/healthz").resp_body == "ok"

      {:ok, _lv, html} = live(conn, ~p"/setup")
      assert html =~ "Setup token" or html =~ "setup"
    end

    test "once completed, /setup bounces home and the gate opens", %{conn: conn} do
      mark_setup_completed()

      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/setup")
      assert html_response(get(conn, ~p"/"), 200)
    end
  end

  describe "the full first-run flow" do
    test "token → wizard → invite link → invited member joins and posts", %{conn: conn} do
      token = Setup.ensure_setup_token()

      {:ok, wizard, _html} = live(conn, ~p"/setup")

      # A wrong token is refused.
      html = render_submit(wizard, "verify_token", %{"token" => "wrong-token"})
      assert html =~ "Check the server logs"

      # The right token unlocks the instance step.
      html = render_submit(wizard, "verify_token", %{"token" => token})
      assert html =~ "operator_email"

      render_submit(wizard, "save_instance", %{
        "operator_email" => "operator@example.org",
        "operator_display_name" => "The Operator",
        "instance_name" => "Kammeret",
        "default_locale" => "en",
        "community_creation_policy" => "operators_only"
      })

      html =
        render_submit(wizard, "complete", %{
          "community_name" => "Sample Community",
          "community_slug" => "sample",
          "accent_color" => "#3E6B48",
          "group_name" => "General",
          "group_slug" => "general",
          "demo_data" => "false"
        })

      assert html =~ "Your instance is ready"
      assert Setup.completed?()

      # The operator's magic link went out — the live SMTP test.
      assert_receive {:email, %Swoosh.Email{to: [{_name, "operator@example.org"}]}}

      # The done screen shows a working community invite link.
      assert [_full, invite_token] = Regex.run(~r{/invite/([\w-]+)}, html)

      # An invited member signs up, accepts, joins the group, and posts.
      member = user_fixture()
      member_conn = log_in_user(build_conn(), member)

      accepted = get(member_conn, ~p"/invite/#{invite_token}/accept")
      assert redirected_to(accepted) == "/c/sample"

      {:ok, group_page, _html} = live(member_conn, ~p"/c/sample/g/general")
      render_click(group_page, "join", %{})

      render_submit(group_page, "create_post", %{
        "post" => %{"body_markdown" => "Hello from the first invited member!"}
      })

      assert render(group_page) =~ "Hello from the first invited member!"
    end
  end
end
