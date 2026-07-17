defmodule KammerWeb.Api.UploadController do
  @moduledoc """
  Feed-attachment uploads over the API (issue #178): multipart, the
  same `Kammer.Files.create_from_upload/5` path the LiveView composer
  consumes its uploads through — image re-encoding, rate limit, quota,
  and posting-rights authorization all enforced in the context. The
  returned `stored_file_id` goes into a subsequent create-post body's
  `stored_file_ids`.
  """

  use KammerWeb, :controller

  alias Kammer.Files
  alias KammerWeb.Api.GroupGate
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiError

  # No-oracle (#339): a missing community, a missing group, and a group
  # the caller may not even *view* all fold into the same 404 via
  # `GroupGate.fetch/3`; a viewer without posting rights in a visible
  # group still gets the context's honest 403.
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"community_slug" => slug, "group_slug" => group_slug} = params) do
    user = conn.assigns.current_scope.user

    with {:ok, _community, group} <- GroupGate.fetch(user, slug, group_slug),
         %Plug.Upload{} = upload <- params["file"] || {:error, :missing_file},
         {:ok, stored_file} <-
           Files.create_from_upload(
             user,
             group,
             upload.path,
             %{filename: upload.filename, content_type: upload.content_type},
             transient: params["transient"] in [true, "true"]
           ) do
      conn
      |> put_status(201)
      |> json(%{data: Serializer.stored_file(stored_file)})
    else
      {:error, :missing_file} -> ApiError.send(conn, :bad_request, "Send a `file` part.")
      error -> ApiError.from_result(conn, error)
    end
  end
end
