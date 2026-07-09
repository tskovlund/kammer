defmodule KammerWeb.Api.FeedWritesTest do
  @moduledoc """
  Feed write parity over the API (issue #178): reactions, poll votes,
  acknowledgments, post/comment edit + delete, pin/unpin — every write
  through the same context functions the UI uses, and the no-oracle
  guarantee extended to writes (#161): a post the caller cannot see
  answers 404 to every verb, exactly like one that doesn't exist.
  """

  use KammerWeb.ConnCase, async: true
  use ExUnitProperties

  import Kammer.CommunitiesFixtures
  import KammerWeb.ApiHelpers
  import OpenApiSpex.TestAssertions

  alias Kammer.Feed

  defp context(_tags) do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community)
    member = group_member_fixture(group)

    %{
      community: community,
      group: group,
      member: member,
      posts_path: ~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/posts"
    }
  end

  setup :context

  describe "post edit and delete" do
    test "the author edits; others may not", %{group: group, member: member, posts_path: path} do
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "original"})

      body =
        member
        |> api_conn()
        |> put("#{path}/#{post.id}", %{"body_markdown" => "revised"})
        |> tap(&assert_operation_response(&1, "posts_update"))
        |> json_response(200)

      assert body["data"]["body_markdown"] == "revised"
      assert body["data"]["edited_at"]

      other = group_member_fixture(group)

      other
      |> api_conn()
      |> put("#{path}/#{post.id}", %{"body_markdown" => "hijacked"})
      |> json_response(403)
    end

    test "the author soft-deletes to a tombstone", %{
      group: group,
      member: member,
      posts_path: path
    } do
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "goodbye"})

      body =
        member
        |> api_conn()
        |> delete("#{path}/#{post.id}")
        |> tap(&assert_operation_response(&1, "posts_delete"))
        |> json_response(200)

      assert body["data"]["deleted"] == true
      assert body["data"]["body_markdown"] == nil

      # The stub stays in the feed for thread coherence.
      %{"data" => [listed]} = member |> api_conn() |> get(path) |> json_response(200)
      assert listed["deleted"] == true
    end

    test "moderators hard-delete with ?hard=true; soft delete stays author-only", %{
      group: group,
      member: member,
      posts_path: path
    } do
      moderator = group_member_fixture(group, :admin)
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "removed"})

      # A moderator cannot soft-delete someone else's post (that's the
      # author's stub) — same rule as the UI's two delete actions.
      moderator |> api_conn() |> delete("#{path}/#{post.id}") |> json_response(403)

      # And a plain member cannot hard-delete.
      member |> api_conn() |> delete("#{path}/#{post.id}?hard=true") |> json_response(403)

      body =
        moderator
        |> api_conn()
        |> delete("#{path}/#{post.id}?hard=true")
        |> json_response(200)

      assert body["data"]["deleted"] == true
      assert Feed.get_post(post.id) == nil
    end
  end

  describe "pin and unpin" do
    test "moderators pin and unpin; members may not", %{
      group: group,
      member: member,
      posts_path: path
    } do
      moderator = group_member_fixture(group, :admin)
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "important"})

      member |> api_conn() |> put("#{path}/#{post.id}/pin") |> json_response(403)

      body =
        moderator
        |> api_conn()
        |> put("#{path}/#{post.id}/pin")
        |> tap(&assert_operation_response(&1, "posts_pin"))
        |> json_response(200)

      assert body["data"]["pinned"] == true

      body =
        moderator
        |> api_conn()
        |> delete("#{path}/#{post.id}/pin")
        |> tap(&assert_operation_response(&1, "posts_unpin"))
        |> json_response(200)

      assert body["data"]["pinned"] == false
    end
  end

  describe "reactions" do
    test "toggle on a post: add, then remove", %{
      group: group,
      member: member,
      posts_path: path
    } do
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "react to me"})

      body =
        member
        |> api_conn()
        |> post("#{path}/#{post.id}/reactions", %{"emoji" => "👍"})
        |> tap(&assert_operation_response(&1, "posts_react"))
        |> json_response(200)

      assert body["data"]["reactions"] == %{"👍" => 1}
      assert body["data"]["my_reactions"] == ["👍"]

      body =
        member
        |> api_conn()
        |> post("#{path}/#{post.id}/reactions", %{"emoji" => "👍"})
        |> json_response(200)

      assert body["data"]["reactions"] == %{}
      assert body["data"]["my_reactions"] == []
    end

    test "toggle on a comment", %{group: group, member: member, posts_path: path} do
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "root"})
      {:ok, comment} = Feed.create_comment(member, post, %{"body_markdown" => "me too"})

      body =
        member
        |> api_conn()
        |> post("#{path}/#{post.id}/comments/#{comment.id}/reactions", %{"emoji" => "❤️"})
        |> tap(&assert_operation_response(&1, "comments_react"))
        |> json_response(200)

      assert body["data"]["id"] == comment.id
      assert body["data"]["reactions"] == %{"❤️" => 1}
      assert body["data"]["my_reactions"] == ["❤️"]
    end

    test "refusals: outside the palette, missing emoji, non-members", %{
      community: community,
      group: group,
      member: member,
      posts_path: path
    } do
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "calm"})

      member
      |> api_conn()
      |> post("#{path}/#{post.id}/reactions", %{"emoji" => "🤡"})
      |> json_response(422)

      member
      |> api_conn()
      |> post("#{path}/#{post.id}/reactions", %{})
      |> json_response(400)

      # A community member can *see* a community-visible group's posts
      # without membership, but reacting is members-only — 403, not
      # 404: the post's existence is no secret.
      onlooker = member_fixture(community)

      onlooker
      |> api_conn()
      |> post("#{path}/#{post.id}/reactions", %{"emoji" => "👍"})
      |> json_response(403)
    end
  end

  describe "polls" do
    test "create with a poll, then vote, revote, and unvote (single choice)", %{
      member: member,
      posts_path: path
    } do
      %{"data" => created} =
        member
        |> api_conn()
        |> post(path, %{
          "body_markdown" => "Which night works?",
          "poll" => %{"options" => [%{"text" => "Friday"}, %{"text" => "Saturday"}]}
        })
        |> json_response(201)

      assert %{"poll" => %{"id" => _poll_id, "options" => [friday, saturday]}} = created
      assert friday["text"] == "Friday"
      assert created["poll"]["my_votes"] == []

      votes_path = "#{path}/#{created["id"]}/poll/votes"

      body =
        member
        |> api_conn()
        |> put(votes_path, %{"option_ids" => [friday["id"]]})
        |> tap(&assert_operation_response(&1, "poll_vote"))
        |> json_response(200)

      assert body["data"]["my_votes"] == [friday["id"]]

      # Single choice: a new selection replaces the old one.
      body =
        member
        |> api_conn()
        |> put(votes_path, %{"option_ids" => [saturday["id"], friday["id"]]})
        |> json_response(200)

      assert body["data"]["my_votes"] == [saturday["id"]]

      # Empty selection = unvote.
      body = member |> api_conn() |> put(votes_path, %{"option_ids" => []}) |> json_response(200)
      assert body["data"]["my_votes"] == []
      assert Enum.all?(body["data"]["options"], &(&1["votes"] == 0))
    end

    test "multiple choice keeps the whole selection", %{
      member: member,
      posts_path: path
    } do
      %{"data" => created} =
        member
        |> api_conn()
        |> post(path, %{
          "body_markdown" => "Bring what?",
          "poll" => %{
            "multiple_choice" => true,
            "options" => [%{"text" => "Cake"}, %{"text" => "Coffee"}]
          }
        })
        |> json_response(201)

      option_ids = Enum.map(created["poll"]["options"], & &1["id"])

      body =
        member
        |> api_conn()
        |> put("#{path}/#{created["id"]}/poll/votes", %{"option_ids" => option_ids})
        |> json_response(200)

      assert Enum.sort(body["data"]["my_votes"]) == Enum.sort(option_ids)
    end

    test "a closed poll refuses votes with a stable code", %{
      group: group,
      member: member,
      posts_path: path
    } do
      {:ok, post} =
        Feed.create_post(member, group, %{
          "body_markdown" => "too late",
          "poll" => %{
            "closes_at" => DateTime.add(DateTime.utc_now(:second), -3600, :second),
            "options" => %{
              "0" => %{"text" => "A", "position" => 0},
              "1" => %{"text" => "B", "position" => 1}
            }
          }
        })

      option_id = hd(post.poll.options).id

      body =
        member
        |> api_conn()
        |> put("#{path}/#{post.id}/poll/votes", %{"option_ids" => [option_id]})
        |> json_response(422)

      assert body["error"]["code"] == "poll_closed"
    end

    test "voting on a post without a poll is a 404; malformed bodies are 400", %{
      group: group,
      member: member,
      posts_path: path
    } do
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "no poll here"})

      member
      |> api_conn()
      |> put("#{path}/#{post.id}/poll/votes", %{"option_ids" => []})
      |> json_response(404)

      member
      |> api_conn()
      |> put("#{path}/#{post.id}/poll/votes", %{"option_ids" => "first"})
      |> json_response(400)
    end
  end

  describe "acknowledgments" do
    test "acknowledge is idempotent and reflected on the post", %{
      group: group,
      member: member,
      posts_path: path
    } do
      author = group_member_fixture(group)

      {:ok, post} =
        Feed.create_post(author, group, %{
          "body_markdown" => "Please read",
          "acknowledgment_required" => true
        })

      body =
        member
        |> api_conn()
        |> put("#{path}/#{post.id}/acknowledgment")
        |> tap(&assert_operation_response(&1, "posts_acknowledge"))
        |> json_response(200)

      assert body["data"]["my_acknowledged"] == true
      assert body["data"]["acknowledged_count"] == 1

      body =
        member |> api_conn() |> put("#{path}/#{post.id}/acknowledgment") |> json_response(200)

      assert body["data"]["acknowledged_count"] == 1
    end

    test "the author sees who acked and who's pending; others don't", %{
      group: group,
      member: member,
      posts_path: path
    } do
      author = group_member_fixture(group)

      {:ok, post} =
        Feed.create_post(author, group, %{
          "body_markdown" => "Please read",
          "acknowledgment_required" => true
        })

      {:ok, _acknowledgment} = Feed.acknowledge_post(member, post)

      body =
        author
        |> api_conn()
        |> get("#{path}/#{post.id}/acknowledgments")
        |> tap(&assert_operation_response(&1, "posts_acknowledgments"))
        |> json_response(200)

      acked_ids = Enum.map(body["data"]["acknowledged"], & &1["id"])
      pending_ids = Enum.map(body["data"]["pending"], & &1["id"])
      assert member.id in acked_ids
      assert author.id in pending_ids

      member |> api_conn() |> get("#{path}/#{post.id}/acknowledgments") |> json_response(403)
    end

    test "a post that doesn't require acknowledgment refuses", %{
      group: group,
      member: member,
      posts_path: path
    } do
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "plain"})

      member
      |> api_conn()
      |> put("#{path}/#{post.id}/acknowledgment")
      |> json_response(422)
    end
  end

  describe "comment edit and delete" do
    test "the author edits; others may not", %{group: group, member: member, posts_path: path} do
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "root"})
      {:ok, comment} = Feed.create_comment(member, post, %{"body_markdown" => "first"})

      body =
        member
        |> api_conn()
        |> put("#{path}/#{post.id}/comments/#{comment.id}", %{"body_markdown" => "revised"})
        |> tap(&assert_operation_response(&1, "comments_update"))
        |> json_response(200)

      assert body["data"]["body_markdown"] == "revised"
      assert body["data"]["edited_at"]

      other = group_member_fixture(group)

      other
      |> api_conn()
      |> put("#{path}/#{post.id}/comments/#{comment.id}", %{"body_markdown" => "hijacked"})
      |> json_response(403)
    end

    test "author soft-deletes to a tombstone; moderators remove outright", %{
      group: group,
      member: member,
      posts_path: path
    } do
      moderator = group_member_fixture(group, :admin)
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "root"})
      {:ok, mine} = Feed.create_comment(member, post, %{"body_markdown" => "mine"})
      {:ok, theirs} = Feed.create_comment(member, post, %{"body_markdown" => "theirs"})

      body =
        member
        |> api_conn()
        |> delete("#{path}/#{post.id}/comments/#{mine.id}")
        |> tap(&assert_operation_response(&1, "comments_delete"))
        |> json_response(200)

      assert body["data"]["deleted"] == true
      assert body["data"]["body_markdown"] == nil

      body =
        moderator
        |> api_conn()
        |> delete("#{path}/#{post.id}/comments/#{theirs.id}")
        |> json_response(200)

      assert body["data"]["deleted"] == true
      # Moderator removal is a hard delete — the comment is gone, while
      # the author's own delete left a stub.
      assert Feed.get_comment(theirs.id) == nil
      assert Feed.get_comment(mine.id)
    end
  end

  describe "no-oracle 404s for invisible posts (#156, extended to writes)" do
    test "every write verb answers 404 for a post the caller can't see", %{community: community} do
      approval_group = group_fixture(community, approval_queue: true)
      poster = group_member_fixture(approval_group)
      onlooker = group_member_fixture(approval_group)

      {:ok, pending} =
        Feed.create_post(poster, approval_group, %{
          "body_markdown" => "queued",
          "acknowledgment_required" => true
        })

      {:ok, comment} = Feed.create_comment(poster, pending, %{"body_markdown" => "own note"})
      assert pending.pending_approval

      base = ~p"/api/v1/communities/#{community.slug}/groups/#{approval_group.slug}/posts"

      requests = [
        {:put, "#{base}/#{pending.id}", %{"body_markdown" => "x"}},
        {:delete, "#{base}/#{pending.id}", nil},
        {:put, "#{base}/#{pending.id}/pin", nil},
        {:delete, "#{base}/#{pending.id}/pin", nil},
        {:post, "#{base}/#{pending.id}/reactions", %{"emoji" => "👍"}},
        {:put, "#{base}/#{pending.id}/poll/votes", %{"option_ids" => []}},
        {:put, "#{base}/#{pending.id}/acknowledgment", nil},
        {:get, "#{base}/#{pending.id}/acknowledgments", nil},
        {:put, "#{base}/#{pending.id}/comments/#{comment.id}", %{"body_markdown" => "x"}},
        {:delete, "#{base}/#{pending.id}/comments/#{comment.id}", nil},
        {:post, "#{base}/#{pending.id}/comments/#{comment.id}/reactions", %{"emoji" => "👍"}}
      ]

      for {method, url, request_body} <- requests do
        conn = api_conn(onlooker)

        response =
          case method do
            :get -> get(conn, url)
            :post -> post(conn, url, request_body)
            :put -> if request_body, do: put(conn, url, request_body), else: put(conn, url)
            :delete -> delete(conn, url)
          end

        assert response.status == 404,
               "#{method} #{url} answered #{response.status}, expected 404"
      end
    end

    test "a comment invisible to the caller (pending guest) 404s on comment writes", %{
      group: group,
      member: member,
      posts_path: path
    } do
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "root"})

      pending_comment =
        Kammer.Repo.insert!(%Kammer.Feed.Comment{
          post_id: post.id,
          body_markdown: "awaiting approval",
          pending_approval: true,
          guest_identity_id:
            Kammer.Repo.insert!(%Kammer.Guests.GuestIdentity{
              email: "guest#{System.unique_integer([:positive])}@example.org",
              display_name: "Guest",
              verified_at: DateTime.utc_now(:second)
            }).id
        })

      other = group_member_fixture(group)

      other
      |> api_conn()
      |> post("#{path}/#{post.id}/comments/#{pending_comment.id}/reactions", %{"emoji" => "👍"})
      |> json_response(404)
    end
  end

  property "write parity: reacting through the API mirrors UI visibility" do
    {community, _owner} = community_with_owner_fixture()

    check all(
            visibility <- member_of([:private, :community, :public_link, :public_listed]),
            sealed <- boolean(),
            viewer_kind <- member_of([:group_member, :community_member, :outsider]),
            max_runs: 25
          ) do
      group = group_fixture(community, visibility: visibility, sealed: sealed)
      author = group_member_fixture(group)
      {:ok, post} = Feed.create_post(author, group, %{"body_markdown" => "Parity"})

      viewer =
        case viewer_kind do
          :group_member -> author
          :community_member -> member_fixture(community)
          :outsider -> Kammer.AccountsFixtures.user_fixture()
        end

      ui_visible? =
        match?({:ok, _group}, Kammer.Groups.fetch_viewable_group(viewer, community, group.slug))

      response =
        viewer
        |> api_conn()
        |> post(
          ~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/posts/#{post.id}/reactions",
          %{"emoji" => "👍"}
        )

      case {viewer_kind, ui_visible?, response.status} do
        # Group members write through; non-member viewers get an
        # honest 403 (they can see the post, reacting is members-only);
        # whoever can't see the group can't learn the post exists.
        {:group_member, true, 200} -> :ok
        {_viewer, true, 403} -> :ok
        {_viewer, false, status} when status in [403, 404] -> :ok
        mismatch -> flunk("UI/API write-parity mismatch: #{inspect(mismatch)}")
      end
    end
  end
end
