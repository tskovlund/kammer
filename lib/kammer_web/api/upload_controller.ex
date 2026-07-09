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

  alias Kammer.Communities
  alias Kammer.Files
  alias Kammer.Groups
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiError

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"community_slug" => slug, "group_slug" => group_slug} = params) do
    user = conn.assigns.current_scope.user

    with %Communities.Community{} = community <- Communities.get_community_by_slug(slug),
         {:ok, group} <- Groups.fetch_viewable_group(user, community, group_slug),
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
      nil -> ApiError.send(conn, :not_found, "Not found.")
      {:error, :missing_file} -> ApiError.send(conn, :bad_request, "Send a `file` part.")
      error -> ApiError.from_result(conn, error)
    end
  end
end
