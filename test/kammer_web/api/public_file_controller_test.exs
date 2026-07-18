defmodule KammerWeb.Api.PublicFileControllerTest do
  @moduledoc """
  Tokenless public post-attachment reads (issue #185 slice B): a
  post's attachment is fetchable without a device token exactly when
  the post itself is reachable through `PublicController.post/2` —
  published, not pending approval, not deleted — and its group passes
  `Kammer.Authorization.publicly_readable?/1`. Everything else
  (library files not attached to a visible post, a file whose post or
  group stops qualifying, a nonexistent or malformed id) answers the
  same neutral 404 `Kammer.Files.fetch_accessible_file/2`'s
  Bearer-authenticated twin gives for "not yours to see" — no
  existence oracle (issue #156/#161), asserted by comparing full
  response bodies.
  """

  use KammerWeb.ConnCase, async: false

  import Kammer.CommunitiesFixtures

  alias Kammer.Feed
  alias Kammer.Files
  alias Kammer.Repo

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous_uploads_path = Application.get_env(:kammer, :uploads_path)
    Application.put_env(:kammer, :uploads_path, Path.join(tmp_dir, "uploads"))

    on_exit(fn ->
      if previous_uploads_path do
        Application.put_env(:kammer, :uploads_path, previous_uploads_path)
      else
        Application.delete_env(:kammer, :uploads_path)
      end
    end)

    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community, visibility: :public_listed)
    author = group_member_fixture(group)

    %{community: community, group: group, author: author, tmp_dir: tmp_dir}
  end

  defp upload!(tmp_dir, group, uploader, contents \\ "hello band") do
    source = Path.join(tmp_dir, "upload-#{System.unique_integer([:positive])}.txt")
    File.write!(source, contents)

    {:ok, stored_file} =
      Files.upload_to_space(uploader, group, nil, source, %{
        filename: "attachment.txt",
        content_type: "text/plain"
      })

    stored_file
  end

  defp post_with_attachment!(group, author, stored_file) do
    {:ok, post} =
      Feed.create_post(author, group, %{
        "body_markdown" => "See attached",
        "stored_file_ids" => [stored_file.id]
      })

    post
  end

  defp archive!(group) do
    group
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second))
    |> Repo.update!()
  end

  defp public_conn, do: put_req_header(build_conn(), "accept", "application/json")

  describe "GET /api/v1/public/files/:file_id" do
    test "a public post's attachment is fetchable tokenlessly", %{
      group: group,
      author: author,
      tmp_dir: tmp_dir
    } do
      stored_file = upload!(tmp_dir, group, author, "hello band")
      post_with_attachment!(group, author, stored_file)

      response = get(public_conn(), ~p"/api/v1/public/files/#{stored_file.id}")

      assert response.status == 200
      assert response.resp_body == "hello band"
      # Unlike the authed twin, this tokenless surface never gets the
      # `private, no-store` directive — it keeps the framework's default
      # caching, so public attachments aren't forced out of caches (#315).
      refute "private, no-store" in get_resp_header(response, "cache-control")
    end

    test "download and thumbnail modes work the same as the Bearer-authenticated route", %{
      group: group,
      author: author,
      tmp_dir: tmp_dir
    } do
      stored_file = upload!(tmp_dir, group, author, "downloadable")
      post_with_attachment!(group, author, stored_file)

      response = get(public_conn(), ~p"/api/v1/public/files/#{stored_file.id}/download")

      assert response.status == 200

      assert Enum.any?(response.resp_headers, fn {name, value} ->
               name == "content-disposition" and value =~ "attachment"
             end)

      # A non-image has no thumbnail — same 404 the Bearer-authenticated
      # `/api/v1/files/:id/thumbnail` route answers (`uploads_test.exs`),
      # exercising `serve_public/3`'s :thumbnail branch.
      assert public_conn()
             |> get(~p"/api/v1/public/files/#{stored_file.id}/thumbnail")
             |> Map.fetch!(:status) == 404
    end

    test "an attachment on a post still awaiting moderator approval 404s like a nonexistent one",
         %{community: community, tmp_dir: tmp_dir} do
      # `approval_queue` marks a non-moderator's post `pending_approval`
      # at creation (`Feed.create_post`) — the one post-visibility flag
      # the deleted/unpublished tests don't reach. Its attachment must
      # stay hidden until a moderator approves the post.
      queued_group =
        group_fixture(community, visibility: :public_listed, approval_queue: true)

      poster = group_member_fixture(queued_group)
      stored_file = upload!(tmp_dir, queued_group, poster, "not approved yet")
      pending_post = post_with_attachment!(queued_group, poster, stored_file)
      assert pending_post.pending_approval

      baseline =
        public_conn()
        |> get(~p"/api/v1/public/files/#{Ecto.UUID.generate()}")
        |> json_response(404)

      response =
        public_conn()
        |> get(~p"/api/v1/public/files/#{stored_file.id}")
        |> json_response(404)

      assert response == baseline
    end

    test "a file on both a qualifying and a non-qualifying post still serves (any-post rule)",
         %{group: group, author: author, tmp_dir: tmp_dir} do
      stored_file = upload!(tmp_dir, group, author, "shared attachment")
      post_with_attachment!(group, author, stored_file)

      # Same file also attached to a post that will never qualify — the
      # rule is ANY visible post makes it public, so a regression to
      # "all posts must qualify" must fail here.
      hidden_post = post_with_attachment!(group, author, stored_file)
      {:ok, _deleted} = Feed.soft_delete_post(author, hidden_post)

      response = get(public_conn(), ~p"/api/v1/public/files/#{stored_file.id}")

      assert response.status == 200
      assert response.resp_body == "shared attachment"
    end

    test "the serialized post's attachment URL already points at the public route", %{
      community: community,
      group: group,
      author: author,
      tmp_dir: tmp_dir
    } do
      stored_file = upload!(tmp_dir, group, author, "hi")
      post = post_with_attachment!(group, author, stored_file)

      body =
        public_conn()
        |> get(
          ~p"/api/v1/public/communities/#{community.slug}/groups/#{group.slug}/posts/#{post.id}"
        )
        |> json_response(200)

      assert [%{"url" => url}] = body["data"]["attachments"]
      assert url == "/api/v1/public/files/#{stored_file.id}"
    end

    test "a file not attached to any post 404s even though its group is public", %{
      group: group,
      author: author,
      tmp_dir: tmp_dir
    } do
      library_file = upload!(tmp_dir, group, author, "not attached")

      baseline =
        public_conn()
        |> get(~p"/api/v1/public/files/#{Ecto.UUID.generate()}")
        |> json_response(404)

      response =
        public_conn() |> get(~p"/api/v1/public/files/#{library_file.id}") |> json_response(404)

      assert response == baseline
    end

    test "a bad, non-UUID id 404s without crashing" do
      assert public_conn() |> get(~p"/api/v1/public/files/not-a-uuid") |> json_response(404)
    end

    test "the same file 404s identically to a nonexistent id once its post is deleted", %{
      group: group,
      author: author,
      tmp_dir: tmp_dir
    } do
      stored_file = upload!(tmp_dir, group, author, "gone soon")
      post = post_with_attachment!(group, author, stored_file)
      {:ok, _deleted} = Feed.soft_delete_post(author, post)

      baseline =
        public_conn()
        |> get(~p"/api/v1/public/files/#{Ecto.UUID.generate()}")
        |> json_response(404)

      response =
        public_conn() |> get(~p"/api/v1/public/files/#{stored_file.id}") |> json_response(404)

      assert response == baseline
    end

    test "404s identically once its post is scheduled (unpublished)", %{
      group: group,
      author: author,
      tmp_dir: tmp_dir
    } do
      stored_file = upload!(tmp_dir, group, author, "not yet")

      {:ok, _post} =
        Feed.create_post(author, group, %{
          "body_markdown" => "Future",
          "published_at" => DateTime.add(DateTime.utc_now(:second), 3600),
          "stored_file_ids" => [stored_file.id]
        })

      baseline =
        public_conn()
        |> get(~p"/api/v1/public/files/#{Ecto.UUID.generate()}")
        |> json_response(404)

      response =
        public_conn() |> get(~p"/api/v1/public/files/#{stored_file.id}") |> json_response(404)

      assert response == baseline
    end

    test "404s identically once the group turns private, sealed, or archived", %{
      community: community,
      tmp_dir: tmp_dir
    } do
      baseline =
        public_conn()
        |> get(~p"/api/v1/public/files/#{Ecto.UUID.generate()}")
        |> json_response(404)

      for group_attrs <- [
            [visibility: :private],
            [visibility: :public_listed, sealed: true]
          ] do
        group = group_fixture(community, group_attrs)
        member = group_member_fixture(group)
        stored_file = upload!(tmp_dir, group, member)
        post_with_attachment!(group, member, stored_file)

        response =
          public_conn() |> get(~p"/api/v1/public/files/#{stored_file.id}") |> json_response(404)

        assert response == baseline
      end

      archived_group = group_fixture(community, visibility: :public_listed)
      archived_member = group_member_fixture(archived_group)
      archived_stored_file = upload!(tmp_dir, archived_group, archived_member)
      post_with_attachment!(archived_group, archived_member, archived_stored_file)
      archive!(archived_group)

      response =
        public_conn()
        |> get(~p"/api/v1/public/files/#{archived_stored_file.id}")
        |> json_response(404)

      assert response == baseline
    end
  end
end
