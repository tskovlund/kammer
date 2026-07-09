defmodule Kammer.FeedTest do
  use Kammer.DataCase, async: true

  import Kammer.CommunitiesFixtures

  alias Kammer.Feed
  alias Kammer.Feed.Post

  defp group_with_members do
    {community, community_owner} = community_with_owner_fixture()
    group = group_fixture(community)
    group_owner = group_member_fixture(group, :owner)
    member = group_member_fixture(group)

    %{
      community: community,
      community_owner: community_owner,
      group: group,
      group_owner: group_owner,
      member: member
    }
  end

  describe "fetch_visible_post/3" do
    setup do
      group_with_members()
    end

    test "returns a published post with the feed's preloads", %{group: group, member: member} do
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "Visible"})

      assert {:ok, fetched} = Feed.fetch_visible_post(member, group, post.id)
      assert fetched.author_user.id == member.id
      assert is_list(fetched.comments)
      assert is_list(fetched.reactions)
    end

    test "hides scheduled and pending posts exactly like the feed", %{community: community} do
      group = group_fixture(community, approval_queue: true)
      admin = group_member_fixture(group, :admin)
      author = group_member_fixture(group)
      other_member = group_member_fixture(group)

      {:ok, pending} = Feed.create_post(author, group, %{"body_markdown" => "Held"})
      assert pending.pending_approval

      assert {:error, :not_found} = Feed.fetch_visible_post(other_member, group, pending.id)
      assert {:ok, _own} = Feed.fetch_visible_post(author, group, pending.id)
      assert {:ok, _moderated} = Feed.fetch_visible_post(admin, group, pending.id)

      future = DateTime.add(DateTime.utc_now(:second), 3600, :second)

      {:ok, scheduled} =
        Feed.create_post(admin, group, %{"body_markdown" => "Later", "published_at" => future})

      assert {:error, :not_found} = Feed.fetch_visible_post(other_member, group, scheduled.id)
      assert {:ok, _own_scheduled} = Feed.fetch_visible_post(admin, group, scheduled.id)

      # Nonexistent ids read the same as hidden ones.
      assert {:error, :not_found} =
               Feed.fetch_visible_post(other_member, group, Ecto.UUID.generate())

      # As do malformed ones — the API passes raw path segments in.
      assert {:error, :not_found} =
               Feed.fetch_visible_post(other_member, group, "not-a-uuid")
    end
  end

  describe "create_post/3" do
    setup do
      group_with_members()
    end

    test "members post; non-members don't", %{group: group, member: member, community: community} do
      outsider = member_fixture(community)

      assert {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "Hello *world*"})
      assert post.author_user_id == member.id

      assert {:error, :unauthorized} =
               Feed.create_post(outsider, group, %{"body_markdown" => "Nope"})
    end

    test "admins-only posting policy", %{community: community} do
      group = group_fixture(community, posting_policy: :admins_only)
      admin = group_member_fixture(group, :admin)
      member = group_member_fixture(group)

      assert {:error, :unauthorized} = Feed.create_post(member, group, %{"body_markdown" => "Hi"})
      assert {:ok, _post} = Feed.create_post(admin, group, %{"body_markdown" => "Announcement"})
    end

    test "post-as-group requires admin powers", %{
      group: group,
      member: member,
      group_owner: group_owner
    } do
      assert {:error, :unauthorized} =
               Feed.create_post(member, group, %{
                 "body_markdown" => "As group",
                 "author_type" => "group"
               })

      assert {:ok, post} =
               Feed.create_post(group_owner, group, %{
                 "body_markdown" => "As group",
                 "author_type" => "group"
               })

      assert post.author_type == :group
    end

    test "approval queue holds member posts, not admin posts", %{community: community} do
      group = group_fixture(community, approval_queue: true)
      admin = group_member_fixture(group, :admin)
      member = group_member_fixture(group)

      assert {:ok, member_post} = Feed.create_post(member, group, %{"body_markdown" => "Hold me"})
      assert member_post.pending_approval

      assert {:ok, admin_post} = Feed.create_post(admin, group, %{"body_markdown" => "Direct"})
      refute admin_post.pending_approval

      # Other members don't see pending posts; the author and admins do.
      other_member = group_member_fixture(group)
      other_feed = Feed.list_group_feed(other_member, group)
      refute Enum.any?(other_feed, fn post -> post.id == member_post.id end)

      author_feed = Feed.list_group_feed(member, group)
      assert Enum.any?(author_feed, fn post -> post.id == member_post.id end)

      admin_feed = Feed.list_group_feed(admin, group)
      assert Enum.any?(admin_feed, fn post -> post.id == member_post.id end)

      # Approval publishes it.
      assert {:ok, approved} = Feed.approve_post(admin, member_post)
      refute approved.pending_approval
    end

    test "archived groups refuse posts", %{group: group, group_owner: group_owner, member: member} do
      {:ok, _archived} = Kammer.Groups.archive_group(group_owner, group)
      archived_group = Kammer.Repo.get!(Kammer.Groups.Group, group.id)

      assert {:error, :unauthorized} =
               Feed.create_post(member, archived_group, %{"body_markdown" => "No"})
    end

    test "scheduled posts stay hidden until publish time", %{group: group, member: member} do
      future = DateTime.add(DateTime.utc_now(:second), 3600, :second)

      assert {:ok, scheduled_post} =
               Feed.create_post(member, group, %{
                 "body_markdown" => "Later",
                 "published_at" => future
               })

      assert Post.scheduled?(scheduled_post, DateTime.utc_now(:second))

      other_member = group_member_fixture(group)
      other_feed = Feed.list_group_feed(other_member, group)
      refute Enum.any?(other_feed, fn post -> post.id == scheduled_post.id end)

      # The author sees their own scheduled post.
      author_feed = Feed.list_group_feed(member, group)
      assert Enum.any?(author_feed, fn post -> post.id == scheduled_post.id end)
    end

    test "@everyone is gated to broadcast rights and rate limited", %{
      group: group,
      member: member,
      group_owner: group_owner
    } do
      assert {:error, :unauthorized} =
               Feed.create_post(member, group, %{"body_markdown" => "Hey @everyone!"})

      assert {:ok, _post} =
               Feed.create_post(group_owner, group, %{"body_markdown" => "Hey @everyone :1"})

      assert {:ok, _post} =
               Feed.create_post(group_owner, group, %{"body_markdown" => "Hey @everyone :2"})

      assert {:error, :rate_limited} =
               Feed.create_post(group_owner, group, %{"body_markdown" => "Hey @everyone :3"})
    end

    test "posting is rate limited per author", %{group: group, member: member} do
      for i <- 1..10 do
        assert {:ok, _post} = Feed.create_post(member, group, %{"body_markdown" => "Post #{i}"})
      end

      assert {:error, :rate_limited} =
               Feed.create_post(member, group, %{"body_markdown" => "One too many"})
    end

    test "creates a poll with options", %{group: group, member: member} do
      assert {:ok, post} =
               Feed.create_post(member, group, %{
                 "body_markdown" => "Which date?",
                 "poll" => %{
                   "multiple_choice" => "false",
                   "anonymous" => "true",
                   "options" => %{
                     "0" => %{"text" => "Friday", "position" => 0},
                     "1" => %{"text" => "Saturday", "position" => 1}
                   }
                 }
               })

      assert post.poll
      assert length(post.poll.options) == 2
      assert post.poll.anonymous
    end
  end

  describe "pins and chronology" do
    setup do
      group_with_members()
    end

    test "feed is chronological with pinned posts first", %{
      group: group,
      member: member,
      group_owner: group_owner
    } do
      {:ok, first_post} = Feed.create_post(member, group, %{"body_markdown" => "first"})
      {:ok, _second_post} = Feed.create_post(member, group, %{"body_markdown" => "second"})
      {:ok, _pinned} = Feed.set_pinned(group_owner, first_post, true)

      feed = Feed.list_group_feed(member, group)
      assert [%{body_markdown: "first"}, %{body_markdown: "second"}] = feed
    end

    test "plain members cannot pin", %{group: group, member: member} do
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "pin me"})
      assert {:error, :unauthorized} = Feed.set_pinned(member, post, true)
    end
  end

  describe "activity sort (ADR 0006 — the only alternate ordering)" do
    setup do
      group_with_members()
    end

    test "activity mode bumps the post with the newest comment; chronological ignores it", %{
      group: group,
      member: member
    } do
      now = DateTime.utc_now(:second)

      {:ok, older} =
        Feed.create_post(member, group, %{
          "body_markdown" => "older",
          "published_at" => DateTime.add(now, -2, :hour)
        })

      {:ok, newer} =
        Feed.create_post(member, group, %{
          "body_markdown" => "newer",
          "published_at" => DateTime.add(now, -1, :hour)
        })

      {:ok, _comment} = Feed.create_comment(member, older, %{"body_markdown" => "bumping this"})

      older_id = older.id
      newer_id = newer.id

      assert [%{id: ^newer_id}, %{id: ^older_id}] =
               Feed.list_group_feed(member, group, :chronological)

      assert [%{id: ^older_id}, %{id: ^newer_id}] = Feed.list_group_feed(member, group, :activity)
    end

    test "a pinned post still sorts first in activity mode", %{
      group: group,
      member: member,
      group_owner: group_owner
    } do
      {:ok, quiet} = Feed.create_post(member, group, %{"body_markdown" => "quiet"})
      {:ok, busy} = Feed.create_post(member, group, %{"body_markdown" => "busy"})
      {:ok, _pinned} = Feed.set_pinned(group_owner, quiet, true)
      {:ok, _comment} = Feed.create_comment(member, busy, %{"body_markdown" => "reply"})

      assert [%{body_markdown: "quiet"}, %{body_markdown: "busy"}] =
               Feed.list_group_feed(member, group, :activity)
    end
  end

  describe "editing" do
    setup do
      group_with_members()
    end

    test "author edits with history; admins cannot rewrite", %{
      group: group,
      member: member,
      group_owner: group_owner
    } do
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "original"})

      assert {:ok, edited} = Feed.edit_post(member, post, %{"body_markdown" => "revised"})
      assert edited.edited_at

      assert {:error, :unauthorized} =
               Feed.edit_post(group_owner, edited, %{"body_markdown" => "hijacked"})

      assert {:ok, [edit]} = Feed.list_post_edits(member, edited)
      assert edit.previous_body_markdown == "original"

      # History is visible to admins but not other members.
      assert {:ok, _edits} = Feed.list_post_edits(group_owner, edited)
      other_member = group_member_fixture(group)
      assert {:error, :unauthorized} = Feed.list_post_edits(other_member, edited)
    end
  end

  describe "deletion" do
    setup do
      group_with_members()
    end

    test "author soft-deletes; admin hard-deletes", %{
      group: group,
      member: member,
      group_owner: group_owner
    } do
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "delete me"})

      assert {:error, :unauthorized} = Feed.soft_delete_post(group_owner, post)
      assert {:ok, deleted} = Feed.soft_delete_post(member, post)
      assert Post.deleted?(deleted)

      {:ok, second_post} = Feed.create_post(member, group, %{"body_markdown" => "gone"})
      assert {:error, :unauthorized} = Feed.hard_delete_post(member, second_post)
      assert {:ok, _deleted} = Feed.hard_delete_post(group_owner, second_post)
      assert Kammer.Repo.get(Post, second_post.id) == nil
    end

    test "purge clears content of old soft-deleted posts", %{group: group, member: member} do
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "old secret"})
      {:ok, deleted} = Feed.soft_delete_post(member, post)

      old_deleted_at = DateTime.add(DateTime.utc_now(:second), -31, :day)

      deleted
      |> Ecto.Changeset.change(deleted_at: old_deleted_at)
      |> Kammer.Repo.update!()

      assert Feed.purge_old_deleted_content() >= 1

      purged = Kammer.Repo.get!(Post, post.id)
      assert purged.body_markdown == ""
      assert purged.purged_at
    end
  end

  describe "comments" do
    setup do
      group_with_members()
    end

    test "pending and scheduled posts take comments only from their author or moderators", %{
      community: community,
      group: group,
      group_owner: group_owner,
      member: member
    } do
      approval_group = group_fixture(community, approval_queue: true)
      poster = group_member_fixture(approval_group)
      onlooker = group_member_fixture(approval_group)
      moderator = group_member_fixture(approval_group, :owner)

      {:ok, pending} = Feed.create_post(poster, approval_group, %{"body_markdown" => "queued"})
      assert pending.pending_approval

      assert {:error, :not_found} =
               Feed.create_comment(onlooker, pending, %{"body_markdown" => "sneaky"})

      assert {:ok, _comment} = Feed.create_comment(poster, pending, %{"body_markdown" => "own"})

      assert {:ok, _comment} =
               Feed.create_comment(moderator, pending, %{"body_markdown" => "review note"})

      future = DateTime.add(DateTime.utc_now(:second), 3600, :second)

      {:ok, scheduled} =
        Feed.create_post(member, group, %{"body_markdown" => "later", "published_at" => future})

      other_member = group_member_fixture(group)

      assert {:error, :not_found} =
               Feed.create_comment(other_member, scheduled, %{"body_markdown" => "early"})

      # Moderators don't see others' scheduled posts (visible_posts/4),
      # so they can't comment on them either — only the author can. The
      # error is :not_found, not :unauthorized: an invisible post must
      # answer like a nonexistent one.
      assert {:error, :not_found} =
               Feed.create_comment(group_owner, scheduled, %{"body_markdown" => "mod note"})

      assert {:ok, _comment} =
               Feed.create_comment(member, scheduled, %{"body_markdown" => "own note"})
    end

    test "a hidden post answers not_found even to viewers who couldn't comment anyway", %{
      community: community
    } do
      # Community-visible group: a community member can *view* it
      # without being a group member, but can't comment. For a hidden
      # (pending) post they must get :not_found — :unauthorized would
      # confirm the hidden post exists, which no read path does.
      open_group = group_fixture(community, visibility: :community, approval_queue: true)
      poster = group_member_fixture(open_group)
      viewer = member_fixture(community)

      {:ok, pending} = Feed.create_post(poster, open_group, %{"body_markdown" => "queued"})
      assert pending.pending_approval

      assert {:error, :not_found} =
               Feed.create_comment(viewer, pending, %{"body_markdown" => "probe"})

      # A *visible* post they can't comment on stays :unauthorized —
      # its existence is no secret. (Admin posts bypass the queue.)
      admin = group_member_fixture(open_group, :admin)
      {:ok, published} = Feed.create_post(admin, open_group, %{"body_markdown" => "public"})
      refute published.pending_approval

      assert {:error, :unauthorized} =
               Feed.create_comment(viewer, published, %{"body_markdown" => "still no"})
    end

    test "a created comment carries its author preloaded", %{group: group, member: member} do
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "root"})
      {:ok, comment} = Feed.create_comment(member, post, %{"body_markdown" => "hello"})

      assert comment.author_user.id == member.id
    end

    test "one reply level is enforced by reparenting", %{group: group, member: member} do
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "root"})

      {:ok, top_comment} = Feed.create_comment(member, post, %{"body_markdown" => "top"})

      {:ok, reply} =
        Feed.create_comment(member, post, %{
          "body_markdown" => "reply",
          "parent_comment_id" => top_comment.id
        })

      assert reply.parent_comment_id == top_comment.id

      {:ok, reply_to_reply} =
        Feed.create_comment(member, post, %{
          "body_markdown" => "reply to reply",
          "parent_comment_id" => reply.id
        })

      assert reply_to_reply.parent_comment_id == top_comment.id
    end

    test "a parent_comment_id from a different post is rejected, not adopted", %{
      group: group,
      member: member
    } do
      {:ok, other_post} = Feed.create_post(member, group, %{"body_markdown" => "other post"})
      {:ok, foreign_comment} = Feed.create_comment(member, other_post, %{"body_markdown" => "x"})

      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "root"})

      {:ok, comment} =
        Feed.create_comment(member, post, %{
          "body_markdown" => "trying to reply into another post's thread",
          "parent_comment_id" => foreign_comment.id
        })

      assert comment.parent_comment_id == nil
    end

    test "a parent_comment_id from a different subject (an event) is rejected", %{
      group: group,
      member: member
    } do
      {:ok, event} =
        Kammer.Events.create_event(member, group, %{
          "title" => "Elsewhere",
          "starts_at" => DateTime.add(DateTime.utc_now(:second), 24, :hour)
        })

      {:ok, event_comment} =
        Kammer.Events.create_comment(member, event, %{"body_markdown" => "x"})

      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "root"})

      {:ok, comment} =
        Feed.create_comment(member, post, %{
          "body_markdown" => "trying to reply into an event's thread",
          "parent_comment_id" => event_comment.id
        })

      assert comment.parent_comment_id == nil
    end

    test "comment lock blocks new comments; author and admins can lock", %{
      group: group,
      member: member,
      group_owner: group_owner
    } do
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "lockable"})

      other_member = group_member_fixture(group)
      assert {:error, :unauthorized} = Feed.set_comments_locked(other_member, post, true)

      assert {:ok, locked_post} = Feed.set_comments_locked(member, post, true)

      assert {:error, :comments_locked} =
               Feed.create_comment(group_owner, locked_post, %{"body_markdown" => "too late"})
    end

    test "comments off policy blocks commenting", %{community: community} do
      group = group_fixture(community, comment_policy: :off)
      group_owner = group_member_fixture(group, :owner)
      {:ok, post} = Feed.create_post(group_owner, group, %{"body_markdown" => "no comments"})

      assert {:error, :unauthorized} =
               Feed.create_comment(group_owner, post, %{"body_markdown" => "hi"})
    end

    test "author soft-deletes own comment; moderator removes others'", %{
      group: group,
      member: member,
      group_owner: group_owner
    } do
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "root"})
      {:ok, comment} = Feed.create_comment(member, post, %{"body_markdown" => "mine"})

      other_member = group_member_fixture(group)
      assert {:error, :unauthorized} = Feed.delete_comment(other_member, comment)

      assert {:ok, deleted} = Feed.delete_comment(member, comment)
      assert deleted.deleted_at

      {:ok, second_comment} = Feed.create_comment(member, post, %{"body_markdown" => "again"})
      assert {:ok, _removed} = Feed.delete_comment(group_owner, second_comment)
      assert Kammer.Repo.get(Kammer.Feed.Comment, second_comment.id) == nil
    end

    test "@everyone in a comment is gated to broadcast rights and rate limited — fanout_comment/1 escalates it to a full-group broadcast, so this is a real authorization gate, not polish",
         %{group: group, member: member, group_owner: group_owner} do
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "root"})

      assert {:error, :unauthorized} =
               Feed.create_comment(member, post, %{"body_markdown" => "Hey @everyone!"})

      assert {:ok, _comment} =
               Feed.create_comment(group_owner, post, %{"body_markdown" => "Hey @everyone :1"})

      assert {:ok, _comment} =
               Feed.create_comment(group_owner, post, %{"body_markdown" => "Hey @everyone :2"})

      assert {:error, :rate_limited} =
               Feed.create_comment(group_owner, post, %{"body_markdown" => "Hey @everyone :3"})
    end

    test "commenting is rate limited per author", %{group: group, member: member} do
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "root"})

      for i <- 1..20 do
        assert {:ok, _comment} =
                 Feed.create_comment(member, post, %{"body_markdown" => "Comment #{i}"})
      end

      assert {:error, :rate_limited} =
               Feed.create_comment(member, post, %{"body_markdown" => "One too many"})
    end
  end

  describe "comment editing" do
    setup do
      group_with_members()
    end

    test "author edits with an edited marker; nobody else may rewrite", %{
      group: group,
      member: member,
      group_owner: group_owner
    } do
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "root"})
      {:ok, comment} = Feed.create_comment(member, post, %{"body_markdown" => "first"})

      assert {:ok, edited} = Feed.edit_comment(member, comment, %{"body_markdown" => "revised"})
      assert edited.body_markdown == "revised"
      assert edited.edited_at

      # Admins moderate (delete) but never rewrite someone's words —
      # the same rule as posts.
      assert {:error, :unauthorized} =
               Feed.edit_comment(group_owner, edited, %{"body_markdown" => "hijacked"})

      other_member = group_member_fixture(group)

      assert {:error, :unauthorized} =
               Feed.edit_comment(other_member, edited, %{"body_markdown" => "hijacked"})
    end

    test "a deleted comment cannot be edited", %{group: group, member: member} do
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "root"})
      {:ok, comment} = Feed.create_comment(member, post, %{"body_markdown" => "oops"})
      {:ok, deleted} = Feed.delete_comment(member, comment)

      assert {:error, :unauthorized} =
               Feed.edit_comment(member, deleted, %{"body_markdown" => "resurrect"})
    end
  end

  defp stored_file_fixture(group, uploader) do
    Kammer.Repo.insert!(%Kammer.Files.StoredFile{
      filename: "file-#{System.unique_integer([:positive])}.txt",
      content_type: "text/plain",
      byte_size: 7,
      storage_key: "test/#{Ecto.UUID.generate()}.txt",
      kind: :file,
      community_id: group.community_id,
      group_id: group.id,
      uploader_user_id: uploader.id
    })
  end

  describe "post attachments" do
    setup do
      group_with_members()
    end

    test "create_post links the author's own uploads in order", %{
      group: group,
      member: member
    } do
      first = stored_file_fixture(group, member)
      second = stored_file_fixture(group, member)

      {:ok, post} =
        Feed.create_post(member, group, %{
          "body_markdown" => "with files",
          "stored_file_ids" => [first.id, second.id]
        })

      assert [%{position: 0} = a, %{position: 1} = b] =
               Enum.sort_by(post.attachments, & &1.position)

      assert a.stored_file_id == first.id
      assert b.stored_file_id == second.id
    end

    test "rejects files the author didn't upload into this group", %{
      community: community,
      group: group,
      member: member
    } do
      someone_else = group_member_fixture(group)
      not_yours = stored_file_fixture(group, someone_else)

      assert {:error, :invalid_attachment} =
               Feed.create_post(member, group, %{
                 "body_markdown" => "sneaky",
                 "stored_file_ids" => [not_yours.id]
               })

      other_group = group_fixture(community)
      group_membership_fixture(other_group, member)
      elsewhere = stored_file_fixture(other_group, member)

      assert {:error, :invalid_attachment} =
               Feed.create_post(member, group, %{
                 "body_markdown" => "cross-group",
                 "stored_file_ids" => [elsewhere.id]
               })

      assert {:error, :invalid_attachment} =
               Feed.create_post(member, group, %{
                 "body_markdown" => "malformed",
                 "stored_file_ids" => ["not-a-uuid"]
               })

      assert {:error, :invalid_attachment} =
               Feed.create_post(member, group, %{
                 "body_markdown" => "not a list",
                 "stored_file_ids" => "nope"
               })
    end
  end

  describe "reactions" do
    setup do
      group_with_members()
    end

    test "toggle on post and comment; members only", %{
      group: group,
      member: member,
      community: community
    } do
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "react"})
      {:ok, comment} = Feed.create_comment(member, post, %{"body_markdown" => "me too"})

      assert {:ok, :added} = Feed.toggle_reaction(member, post, "👍")
      assert {:ok, :removed} = Feed.toggle_reaction(member, post, "👍")
      assert {:ok, :added} = Feed.toggle_reaction(member, comment, "❤️")

      non_member = member_fixture(community)
      assert {:error, :unauthorized} = Feed.toggle_reaction(non_member, post, "👍")

      assert {:error, %Ecto.Changeset{}} = Feed.toggle_reaction(member, post, "�তারা")
    end
  end

  describe "polls" do
    setup do
      context = group_with_members()

      {:ok, post} =
        Feed.create_post(context.member, context.group, %{
          "body_markdown" => "vote",
          "poll" => %{
            "multiple_choice" => "false",
            "options" => %{
              "0" => %{"text" => "A", "position" => 0},
              "1" => %{"text" => "B", "position" => 1}
            }
          }
        })

      Map.merge(context, %{post: post, poll: post.poll})
    end

    test "single choice replaces previous vote", %{poll: poll, member: member} do
      [option_a, option_b] = Enum.sort_by(poll.options, & &1.position)

      assert :ok = Feed.vote(member, poll, [option_a.id])
      assert :ok = Feed.vote(member, poll, [option_b.id])

      votes = Kammer.Repo.all(Kammer.Feed.PollVote)
      assert [%{option_id: option_id}] = votes
      assert option_id == option_b.id
    end

    test "closed polls refuse votes", %{poll: poll, member: member} do
      past = DateTime.add(DateTime.utc_now(:second), -60, :second)
      closed_poll = poll |> Ecto.Changeset.change(closes_at: past) |> Kammer.Repo.update!()

      [option_a, _option_b] = closed_poll.options |> Enum.sort_by(& &1.position)
      assert {:error, :poll_closed} = Feed.vote(member, closed_poll, [option_a.id])
    end

    test "non-members cannot vote", %{poll: poll, community: community} do
      outsider = member_fixture(community)
      [option_a, _option_b] = Enum.sort_by(poll.options, & &1.position)
      assert {:error, :unauthorized} = Feed.vote(outsider, poll, [option_a.id])
    end
  end

  describe "acknowledgments" do
    setup do
      group_with_members()
    end

    test "members acknowledge; author sees status", %{
      group: group,
      member: member,
      group_owner: group_owner
    } do
      {:ok, post} =
        Feed.create_post(group_owner, group, %{
          "body_markdown" => "Important!",
          "acknowledgment_required" => "true"
        })

      assert {:ok, _acknowledgment} = Feed.acknowledge_post(member, post)

      assert {:ok, status} = Feed.acknowledgment_status(group_owner, post)
      acknowledged_ids = Enum.map(status.acknowledged, & &1.id)
      assert member.id in acknowledged_ids
      assert Enum.any?(status.pending, fn user -> user.id == group_owner.id end)

      # Plain members can't see who hasn't acknowledged.
      assert {:error, :unauthorized} = Feed.acknowledgment_status(member, post)
    end
  end

  describe "home feed and visit markers" do
    test "aggregates member groups chronologically" do
      {community, _owner} = community_with_owner_fixture()
      group_one = group_fixture(community)
      group_two = group_fixture(community)
      member = group_member_fixture(group_one)
      group_membership_fixture(group_two, member)
      other_group = group_fixture(community)
      other_member = group_member_fixture(other_group)

      {:ok, _post_one} = Feed.create_post(member, group_one, %{"body_markdown" => "in one"})
      {:ok, _post_two} = Feed.create_post(member, group_two, %{"body_markdown" => "in two"})

      {:ok, _other} =
        Feed.create_post(other_member, other_group, %{"body_markdown" => "elsewhere"})

      home_feed = Feed.list_home_feed(member, community)
      bodies = Enum.map(home_feed, & &1.body_markdown)
      assert "in one" in bodies
      assert "in two" in bodies
      refute "elsewhere" in bodies
    end

    test "record_visit returns the previous visit time" do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community)
      member = group_member_fixture(group)

      assert Feed.record_visit(member, group) == nil
      assert %DateTime{} = Feed.record_visit(member, group)
    end
  end

  describe "comment_context/1" do
    test "raises Ecto.NoResultsError (not MatchError) for a comment on a missing assignment" do
      comment = %Kammer.Feed.Comment{assignment_id: Ecto.UUID.generate()}

      assert_raise Ecto.NoResultsError, fn -> Feed.comment_context(comment) end
    end

    test "raises Ecto.NoResultsError (not MatchError) for a comment on a missing event" do
      comment = %Kammer.Feed.Comment{event_id: Ecto.UUID.generate()}

      assert_raise Ecto.NoResultsError, fn -> Feed.comment_context(comment) end
    end
  end
end
