defmodule Kammer.GuestCommentsTest do
  @moduledoc """
  Guest comments end to end (SPEC §3 `members_and_guests`, rides
  ADR 0013): the two-link confirm flow, the moderator approval queue,
  the pending-invisibility invariant across viewer kinds, claiming, and
  erasure.
  """

  use Kammer.DataCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures
  import Swoosh.TestAssertions

  alias Kammer.Authorization
  alias Kammer.Feed
  alias Kammer.Feed.Comment
  alias Kammer.Guests
  alias Kammer.Guests.GuestIdentity
  alias Kammer.Repo

  defp guest_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "email" => "gaest#{System.unique_integer([:positive])}@example.org",
        "display_name" => "Gæsten",
        "body_markdown" => "Sikke en fin koncert det bliver!"
      },
      overrides
    )
  end

  defp public_post_context(group_attrs \\ []) do
    {community, _owner} = community_with_owner_fixture()

    group =
      group_fixture(
        community,
        Keyword.merge(
          [visibility: :public_listed, comment_policy: :members_and_guests],
          group_attrs
        )
      )

    member = group_member_fixture(group)
    moderator = group_member_fixture(group, :admin)
    {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "Velkommen til!"})

    drain_delivered_emails()

    %{
      community: community,
      group: group,
      member: member,
      moderator: moderator,
      post: post
    }
  end

  defp drain_delivered_emails do
    receive do
      {:email, _email} -> drain_delivered_emails()
    after
      0 -> :ok
    end
  end

  defp request!(post, group, attrs) do
    assert :ok =
             Feed.request_guest_comment(post, group, attrs,
               client_ip: nil,
               confirm_url_fun: fn token -> "http://test/confirm/#{token}" end
             )

    assert_email_sent(fn email ->
      [url] = Regex.run(~r{http://test/confirm/(\S+)}, email.text_body, capture: :all_but_first)
      send(self(), {:confirm_token, url})
      true
    end)

    assert_received {:confirm_token, token}
    token
  end

  defp confirm!(token) do
    assert {:ok, post, identity} =
             Feed.confirm_guest_comment(token, fn manage_token ->
               "http://test/manage/#{manage_token}"
             end)

    assert_email_sent(fn email ->
      [url] = Regex.run(~r{http://test/manage/(\S+)}, email.text_body, capture: :all_but_first)
      send(self(), {:manage_token, url})
      true
    end)

    assert_received {:manage_token, manage_token}
    {post, identity, manage_token}
  end

  describe "authorization" do
    test "guest comments need a public group that opted in, and a live one" do
      {community, _owner} = community_with_owner_fixture()

      for {attrs, allowed?} <- [
            {[visibility: :public_listed, comment_policy: :members_and_guests], true},
            {[visibility: :public_link, comment_policy: :members_and_guests], true},
            {[visibility: :public_listed, comment_policy: :members], false},
            {[visibility: :public_listed, comment_policy: :off], false},
            {[visibility: :community, comment_policy: :members_and_guests], false},
            {[visibility: :private, comment_policy: :members_and_guests], false}
          ] do
        group = group_fixture(community, attrs)
        assert Authorization.can_guest_comment?(group) == allowed?
      end

      archived =
        group_fixture(community,
          visibility: :public_listed,
          comment_policy: :members_and_guests
        )
        |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second))
        |> Repo.update!()

      refute Authorization.can_guest_comment?(archived)
    end

    test "requests against members-only groups are refused" do
      %{post: post} = public_post_context(comment_policy: :members)
      group = Repo.get!(Kammer.Groups.Group, post.group_id)

      assert {:error, :unauthorized} =
               Feed.request_guest_comment(post, group, guest_attrs(),
                 client_ip: nil,
                 confirm_url_fun: fn _token -> "unused" end
               )
    end

    test "locked comments refuse guests at request AND confirm time" do
      %{post: post, group: group, moderator: moderator} = public_post_context()

      token = request!(post, group, guest_attrs())

      {:ok, _post} = Feed.set_comments_locked(moderator, post, true)

      assert {:error, :invalid} =
               Feed.confirm_guest_comment(token, fn _manage -> "unused" end)

      locked_post = Feed.get_post!(group, post.id)

      assert {:error, :unauthorized} =
               Feed.request_guest_comment(locked_post, group, guest_attrs(),
                 client_ip: nil,
                 confirm_url_fun: fn _token -> "unused" end
               )
    end
  end

  describe "the confirm flow" do
    test "records nothing until the emailed link is followed, then a pending comment" do
      %{post: post, group: group} = public_post_context()
      attrs = guest_attrs()

      token = request!(post, group, attrs)
      assert Repo.aggregate(GuestIdentity, :count) == 0
      assert Repo.aggregate(Comment, :count) == 0

      {confirmed_post, identity, _manage} = confirm!(token)
      assert confirmed_post.id == post.id
      assert identity.email == attrs["email"]
      assert identity.verified_at

      comment = Repo.get_by!(Comment, guest_identity_id: identity.id)
      assert comment.pending_approval
      assert comment.body_markdown == attrs["body_markdown"]
      assert comment.author_user_id == nil
      assert comment.parent_comment_id == nil
    end

    test "rejects garbage tokens and validates the request" do
      %{post: post, group: group} = public_post_context()

      assert {:error, :invalid} =
               Feed.confirm_guest_comment("garbage", fn _token -> "unused" end)

      assert {:error, %Ecto.Changeset{}} =
               Feed.request_guest_comment(post, group, guest_attrs(%{"email" => "not an email"}),
                 client_ip: nil,
                 confirm_url_fun: fn _token -> "unused" end
               )

      too_long = String.duplicate("a", 2_001)

      assert {:error, %Ecto.Changeset{}} =
               Feed.request_guest_comment(
                 post,
                 group,
                 guest_attrs(%{"body_markdown" => too_long}),
                 client_ip: nil,
                 confirm_url_fun: fn _token -> "unused" end
               )
    end

    test "rate-limits per email" do
      %{post: post, group: group} = public_post_context()
      attrs = guest_attrs()

      for _attempt <- 1..3, do: request!(post, group, attrs)

      assert {:error, :rate_limited} =
               Feed.request_guest_comment(post, group, attrs,
                 client_ip: nil,
                 confirm_url_fun: fn _token -> "unused" end
               )
    end
  end

  describe "pending invisibility (the §3 invariant)" do
    test "pending comments exist only for moderators, across viewer kinds" do
      %{post: post, group: group, member: member, moderator: moderator} = public_post_context()

      {_post, _identity, _manage} = post |> request!(group, guest_attrs()) |> confirm!()

      non_member = user_fixture()

      for {viewer, sees_pending?} <- [
            {moderator, true},
            {member, false},
            {non_member, false},
            {nil, false}
          ] do
        [feed_post] = Feed.list_group_feed(viewer, group)

        pending_visible? = Enum.any?(feed_post.comments, & &1.pending_approval)

        assert pending_visible? == sees_pending?,
               "viewer #{inspect(viewer && viewer.email)} expected pending " <>
                 "visibility #{sees_pending?}"

        {[page_post], _cursor} = Feed.list_group_feed_page(viewer, group, nil, 25)
        assert Enum.any?(page_post.comments, & &1.pending_approval) == sees_pending?
      end
    end
  end

  describe "moderation" do
    test "approve makes the comment visible to everyone", %{} do
      %{post: post, group: group, member: member, moderator: moderator} = public_post_context()
      {_post, identity, _manage} = post |> request!(group, guest_attrs()) |> confirm!()

      comment = Repo.get_by!(Comment, guest_identity_id: identity.id)

      assert {:error, :unauthorized} = Feed.approve_guest_comment(member, comment)

      assert {:ok, approved} = Feed.approve_guest_comment(moderator, comment)
      refute approved.pending_approval

      [feed_post] = Feed.list_group_feed(member, group)
      assert Enum.any?(feed_post.comments, &(&1.id == comment.id))
    end

    test "reject hard-deletes; approved comments cannot be re-rejected" do
      %{post: post, group: group, member: member, moderator: moderator} = public_post_context()
      {_post, identity, _manage} = post |> request!(group, guest_attrs()) |> confirm!()

      comment = Repo.get_by!(Comment, guest_identity_id: identity.id)

      assert {:error, :unauthorized} = Feed.reject_guest_comment(member, comment)
      assert {:ok, _deleted} = Feed.reject_guest_comment(moderator, comment)
      assert Repo.get(Comment, comment.id) == nil

      {_post, identity_two, _manage} = post |> request!(group, guest_attrs()) |> confirm!()
      comment_two = Repo.get_by!(Comment, guest_identity_id: identity_two.id)
      assert {:ok, approved} = Feed.approve_guest_comment(moderator, comment_two)
      assert {:error, :unauthorized} = Feed.reject_guest_comment(moderator, approved)
    end
  end

  describe "management, claiming, and erasure" do
    test "the manage link lists comments; erasing removes them" do
      %{post: post, group: group} = public_post_context()
      {_post, identity, manage_token} = post |> request!(group, guest_attrs()) |> confirm!()

      assert {:ok, %{identity: loaded, rsvps: [], comments: [comment]}} =
               Guests.fetch_manage_state(manage_token)

      assert loaded.id == identity.id
      assert comment.pending_approval
      assert comment.post.group.id == group.id

      assert :ok = Guests.erase_by_token(manage_token)
      assert Repo.aggregate(GuestIdentity, :count) == 0
      assert Repo.aggregate(Comment, :count) == 0
    end

    test "signing in with the guest's email claims comments" do
      %{post: post, group: group, moderator: moderator} = public_post_context()
      {_post, identity, _manage} = post |> request!(group, guest_attrs()) |> confirm!()

      comment = Repo.get_by!(Comment, guest_identity_id: identity.id)
      {:ok, _approved} = Feed.approve_guest_comment(moderator, comment)

      user = user_fixture(email: identity.email)
      assert :ok = Guests.claim_history(user)

      assert Repo.get_by(GuestIdentity, email: identity.email) == nil
      claimed = Repo.get!(Comment, comment.id)
      assert claimed.author_user_id == user.id
      assert claimed.guest_identity_id == nil
      refute claimed.pending_approval
    end
  end
end
