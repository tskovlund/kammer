defmodule KammerWeb.GuestCommentFlowsTest do
  @moduledoc """
  The guest comment journey end to end (SPEC §3 `members_and_guests`):
  anonymous visitor on a public group feed → email confirm link →
  pending comment → moderator approves inline → visible to everyone.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias Kammer.Feed
  alias Kammer.Feed.Comment
  alias Kammer.Guests.GuestIdentity
  alias Kammer.Repo

  defp public_group_context(_context) do
    {community, _owner} = community_with_owner_fixture()

    group =
      group_fixture(community,
        visibility: :public_listed,
        comment_policy: :members_and_guests
      )

    member = group_member_fixture(group)
    moderator = group_member_fixture(group, :admin)
    {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "Velkommen til!"})

    drain_delivered_emails()

    %{community: community, group: group, member: member, moderator: moderator, post: post}
  end

  defp drain_delivered_emails do
    receive do
      {:email, _email} -> drain_delivered_emails()
    after
      0 -> :ok
    end
  end

  defp email_link(pattern) do
    assert_email_sent(fn email ->
      case Regex.run(pattern, email.text_body, capture: :all_but_first) do
        [token] ->
          send(self(), {:token, token})
          true

        nil ->
          false
      end
    end)

    assert_received {:token, token}
    token
  end

  describe "anonymous visitors on a public group feed" do
    setup :public_group_context

    test "see the guest comment form; members do not", %{
      conn: conn,
      community: community,
      group: group,
      member: member,
      post: post
    } do
      {:ok, _lv, html} = live(conn, ~p"/c/#{community.slug}/g/#{group.slug}")
      assert html =~ "guest-comment-form-#{post.id}"

      member_conn = log_in_user(build_conn(), member)
      {:ok, _lv, member_html} = live(member_conn, ~p"/c/#{community.slug}/g/#{group.slug}")
      refute member_html =~ "guest-comment-form-#{post.id}"
    end

    test "groups without the policy show no guest form", %{conn: conn} do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community, visibility: :public_listed, comment_policy: :members)
      member = group_member_fixture(group)
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "Kun medlemmer"})

      {:ok, _lv, html} = live(conn, ~p"/c/#{community.slug}/g/#{group.slug}")
      refute html =~ "guest-comment-form-#{post.id}"
    end

    test "the full journey: request, confirm, moderate, appear", %{
      conn: conn,
      community: community,
      group: group,
      member: member,
      moderator: moderator,
      post: post
    } do
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/g/#{group.slug}")

      lv
      |> form("#guest-comment-form-#{post.id}",
        guest: %{
          display_name: "Gæsten",
          email: "gaest@example.org",
          body_markdown: "Må jeg være med?"
        }
      )
      |> render_submit()

      assert Repo.aggregate(Comment, :count) == 0
      confirm_token = email_link(~r{/guest/comment/confirm/(\S+)})

      confirm_conn = get(build_conn(), ~p"/guest/comment/confirm/#{confirm_token}")
      assert redirected_to(confirm_conn) == "/c/#{community.slug}/g/#{group.slug}"

      identity = Repo.get_by!(GuestIdentity, email: "gaest@example.org")
      comment = Repo.get_by!(Comment, guest_identity_id: identity.id)
      assert comment.pending_approval

      # Members don't see it pending; the moderator sees it with controls.
      member_conn = log_in_user(build_conn(), member)
      {:ok, _member_lv, member_html} = live(member_conn, ~p"/c/#{community.slug}/g/#{group.slug}")
      refute member_html =~ "comment-#{comment.id}"

      moderator_conn = log_in_user(build_conn(), moderator)

      {:ok, moderator_lv, moderator_html} =
        live(moderator_conn, ~p"/c/#{community.slug}/g/#{group.slug}")

      assert moderator_html =~ "comment-#{comment.id}"

      moderator_lv |> element("#approve-comment-#{comment.id}") |> render_click()
      refute Repo.get!(Comment, comment.id).pending_approval

      {:ok, _member_lv, member_html} = live(member_conn, ~p"/c/#{community.slug}/g/#{group.slug}")
      assert member_html =~ "comment-#{comment.id}"

      # The guest's management page lists the comment.
      manage_token = email_link(~r{/guest/manage/([^/\s]+)$}m)
      {:ok, _manage_lv, manage_html} = live(build_conn(), ~p"/guest/manage/#{manage_token}")
      assert manage_html =~ "Må jeg være med?"
    end
  end
end
