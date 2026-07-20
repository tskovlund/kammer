defmodule KammerWeb.Api.RealtimeTest do
  @moduledoc """
  Channels for API clients (ADR 0014): short-lived-token connects
  (issue #175), join
  authorization on both topics in both directions, and end-to-end
  delivery — a post created through the context arrives on the wire
  in the exact REST serializer shape, and never to a viewer the feed
  itself would hide it from.
  """

  use KammerWeb.ChannelCase, async: false

  import Kammer.CommunitiesFixtures
  import Kammer.ModerationFixtures

  alias Kammer.Accounts.UserToken
  alias Kammer.Feed
  alias Kammer.Notifications
  alias Kammer.Repo
  alias KammerWeb.Api.SocketToken
  alias KammerWeb.Api.UserSocket

  # The socket connects with a short-lived token minted from the device token
  # (issue #175), not the device token itself — mirror that here.
  defp connect_as(user) do
    {_token, user_token} = UserToken.build_device_token(user, "test device")
    device_token = Repo.insert!(user_token)

    {:ok, socket} = connect(UserSocket, %{"token" => SocketToken.sign(user.id, device_token.id)})
    socket
  end

  defp realtime_context do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community, visibility: :private)
    author = group_member_fixture(group)
    member = group_member_fixture(group)
    %{community: community, group: group, author: author, member: member}
  end

  describe "socket connect" do
    test "a valid short-lived token connects; garbage, absence, and the raw device token do not" do
      %{member: member} = realtime_context()
      {device_token, user_token} = UserToken.build_device_token(member, "test device")
      Repo.insert!(user_token)

      assert %Phoenix.Socket{} = connect_as(member)
      assert :error = connect(UserSocket, %{"token" => "garbage"})
      assert :error = connect(UserSocket, %{})
      # The device token is no longer a valid socket credential — only a token
      # minted by SocketToken is (issue #175).
      assert :error = connect(UserSocket, %{"token" => device_token})
    end

    test "a socket token older than its max age is refused (#175)" do
      %{member: member} = realtime_context()
      {_token, user_token} = UserToken.build_device_token(member, "test device")
      device_token = Repo.insert!(user_token)

      # Sign with a stale timestamp so the connect-time max_age check rejects it,
      # even though the device is still active.
      stale =
        Phoenix.Token.sign(
          KammerWeb.Endpoint,
          "api socket token",
          {member.id, device_token.id},
          signed_at: System.system_time(:second) - SocketToken.max_age_seconds() - 5
        )

      assert :error = connect(UserSocket, %{"token" => stale})
    end

    test "a socket token whose device was revoked is refused within its window (#175)" do
      %{member: member} = realtime_context()
      {_token, user_token} = UserToken.build_device_token(member, "test device")
      device_token = Repo.insert!(user_token)
      socket_token = SocketToken.sign(member.id, device_token.id)

      # Revoke the device (delete the row). The socket token is still unexpired,
      # but the connect-time device-active check must refuse it — revoking a
      # device kills its realtime access, not just its REST access.
      Repo.delete!(device_token)

      assert :error = connect(UserSocket, %{"token" => socket_token})
    end

    test "a token pairing a valid device with a different user is refused (#175)" do
      %{author: author, member: member} = realtime_context()
      {_token, user_token} = UserToken.build_device_token(member, "test device")
      device_token = Repo.insert!(user_token)

      # The device belongs to `member`, but the token claims `author`. The
      # connect gate binds the claimed user to the device it names, so a token
      # that pairs one user with another's still-active device id is refused —
      # the socket path never has to trust the minting endpoint paired them.
      forged = SocketToken.sign(author.id, device_token.id)

      assert :error = connect(UserSocket, %{"token" => forged})
    end

    test "a socket token is refused once the account email changed out from under the device (#175)" do
      %{member: member} = realtime_context()
      {_token, user_token} = UserToken.build_device_token(member, "test device")
      device_token = Repo.insert!(user_token)
      socket_token = SocketToken.sign(member.id, device_token.id)

      # Change the email directly, leaving the device row in place: the
      # stale-device purge runs post-commit in the account controller, not
      # atomically with the email change, so a device row with the old
      # `sent_to` can briefly outlive the change. The connect gate binds
      # `sent_to == user.email` exactly as the REST device-token check does, so
      # it refuses the stale device here without leaning on the purge.
      member |> Ecto.Changeset.change(email: "moved@example.com") |> Repo.update!()

      assert :error = connect(UserSocket, %{"token" => socket_token})
    end

    test "a banned account's surviving token is refused at connect (#377)" do
      %{member: member} = realtime_context()
      {_token, user_token} = UserToken.build_device_token(member, "test device")
      device_token = Repo.insert!(user_token)
      socket_token = SocketToken.sign(member.id, device_token.id)

      # Ban WITHOUT ban_instance's token revocation, so the device (and its
      # minted socket token) survive: the connect gate itself must refuse it.
      # The ban's disconnect broadcast severs live sockets, but the client
      # auto-reconnects, so connect can't lean on revocation alone.
      instance_ban_fixture(member.email)

      assert :error = connect(UserSocket, %{"token" => socket_token})
    end
  end

  describe "feed:group:* join authorization" do
    test "viewable group joins; hidden group answers not_found either way" do
      %{community: community, group: group, member: member} = realtime_context()
      outsider = member_fixture(community)

      assert {:ok, _reply, _socket} =
               member |> connect_as() |> subscribe_and_join("feed:group:#{group.id}")

      assert {:error, %{error: %{code: "not_found"}}} =
               outsider |> connect_as() |> subscribe_and_join("feed:group:#{group.id}")

      assert {:error, %{error: %{code: "not_found"}}} =
               member
               |> connect_as()
               |> subscribe_and_join("feed:group:#{Ecto.UUID.generate()}")
    end
  end

  describe "feed events end to end" do
    test "a created post is pushed in the REST serializer shape" do
      %{group: group, author: author, member: member} = realtime_context()

      {:ok, _reply, _socket} =
        member |> connect_as() |> subscribe_and_join("feed:group:#{group.id}")

      {:ok, post} = Feed.create_post(author, group, %{"body_markdown" => "Realtime *hello*"})

      assert_push "post_created", payload
      assert payload.id == post.id
      assert payload.group_id == group.id
      assert payload.body_markdown == "Realtime *hello*"
      assert payload.author == %{type: "user", id: author.id, display_name: author.display_name}
      assert payload.deleted == false
      assert payload.comments == []

      # Soft delete broadcasts an update — the feed keeps a stub.
      {:ok, _stub} = Feed.soft_delete_post(author, post)
      assert_push "post_updated", stub_payload
      assert stub_payload.deleted == true
      assert stub_payload.body_markdown == nil

      # Hard delete broadcasts the removal itself.
      admin = group_member_fixture(group, :admin)
      {:ok, _removed} = Feed.hard_delete_post(admin, post)
      post_id = post.id
      assert_push "post_deleted", %{id: ^post_id}
    end

    test "a pending-approval post is never pushed to a plain member" do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community, approval_queue: true)
      author = group_member_fixture(group)
      member = group_member_fixture(group)

      {:ok, _reply, _socket} =
        member |> connect_as() |> subscribe_and_join("feed:group:#{group.id}")

      {:ok, pending} = Feed.create_post(author, group, %{"body_markdown" => "Held back"})
      assert pending.pending_approval

      # Ordering proof, not just a timing window: an admin post
      # published AFTER the pending one arrives as the FIRST push —
      # so the pending post's broadcast was genuinely filtered, not
      # merely slower than refute_push's patience.
      admin = group_member_fixture(group, :admin)
      {:ok, visible} = Feed.create_post(admin, group, %{"body_markdown" => "Public"})
      visible_id = visible.id

      assert_push "post_created", %{id: ^visible_id}
      refute_push "post_created", %{}
    end

    test "a removed member's channel stops pushing on the next event" do
      %{community: community, group: group, author: author, member: member} = realtime_context()

      {:ok, _reply, _socket} =
        member |> connect_as() |> subscribe_and_join("feed:group:#{group.id}")

      membership =
        Kammer.Repo.get_by!(Kammer.Communities.CommunityMembership,
          community_id: community.id,
          user_id: member.id
        )

      {:ok, _removed} = Kammer.Communities.remove_member(member, community, membership)

      {:ok, _post} = Feed.create_post(author, group, %{"body_markdown" => "After removal"})

      # The join-time grant doesn't outlive access: the per-push
      # re-fetch re-authorizes :view_group against fresh state.
      refute_push "post_created", %{}
    end
  end

  describe "notifications:user:* topic" do
    test "only the user themself may join their topic" do
      %{author: author, member: member} = realtime_context()

      assert {:ok, _reply, _socket} =
               member
               |> connect_as()
               |> subscribe_and_join("notifications:user:#{member.id}")

      assert {:error, %{error: %{code: "not_found"}}} =
               author
               |> connect_as()
               |> subscribe_and_join("notifications:user:#{member.id}")
    end

    test "a delivered notification is pushed in the REST serializer shape" do
      %{group: group, author: author, member: member} = realtime_context()

      {:ok, _reply, _socket} =
        member
        |> connect_as()
        |> subscribe_and_join("notifications:user:#{member.id}")

      {:ok, post} =
        Feed.create_post(author, group, %{
          "body_markdown" => "Please read",
          "acknowledgment_required" => "true"
        })

      :ok = Notifications.fanout_post(post)

      assert_push "notification_created", payload
      assert payload.kind == :acknowledgment_required
      assert payload.read == false
      assert payload.post_id == post.id
      assert payload.actor == %{type: "user", id: author.id, display_name: author.display_name}
      assert payload.group == %{id: group.id, name: group.name, slug: group.slug}
      assert payload.community.id == group.community_id
    end

    test "a member who loses group access stops receiving pushes on the next one (#377)" do
      %{community: community, group: group, member: member} = realtime_context()

      {:ok, _reply, _socket} =
        member
        |> connect_as()
        |> subscribe_and_join("notifications:user:#{member.id}")

      # While a member, the notification reaches the stream.
      Notifications.insert_notification!(%{
        user_id: member.id,
        community_id: community.id,
        group_id: group.id,
        kind: :post
      })

      assert_push "notification_created", _first

      membership =
        Repo.get_by!(Kammer.Communities.CommunityMembership,
          community_id: community.id,
          user_id: member.id
        )

      {:ok, _removed} = Kammer.Communities.remove_member(member, community, membership)

      # A second notification for the same (now-unviewable) group must not
      # push: the per-push :view_group re-check decides, so the ban
      # `disconnect` broadcast is no longer the only thing cutting the
      # stream (#377).
      Notifications.insert_notification!(%{
        user_id: member.id,
        community_id: community.id,
        group_id: group.id,
        kind: :post
      })

      refute_push "notification_created", %{}
    end
  end
end
