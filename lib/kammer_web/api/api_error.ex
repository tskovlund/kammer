defmodule KammerWeb.ApiError do
  @moduledoc """
  The one error envelope (RFC 0001): every API error is
  `{"error": {"code": "...", "message": "..."}}` with a stable,
  machine-readable code; the HTTP status carries the class. Clients
  switch on `code`, humans read `message` — nothing else to parse.
  """

  import Plug.Conn

  @codes %{
    bad_request: {400, "bad_request"},
    unauthorized: {401, "unauthorized"},
    # 401, not 403: the request lacks a (fresh enough) authentication
    # factor, and the client can cure it by stepping up and retrying —
    # the distinct code keeps it from reading as "signed out" (#294).
    step_up_required: {401, "step_up_required"},
    forbidden: {403, "forbidden"},
    not_found: {404, "not_found"},
    unprocessable: {422, "invalid_params"},
    comments_locked: {422, "comments_locked"},
    poll_closed: {422, "poll_closed"},
    slot_full: {422, "slot_full"},
    owner_cannot_leave: {422, "owner_cannot_leave"},
    last_owner: {422, "last_owner"},
    payload_too_large: {413, "payload_too_large"},
    quota_exceeded: {413, "quota_exceeded"},
    rate_limited: {429, "rate_limited"}
  }

  @doc "Sends the standard envelope for a known error kind."
  @spec send(Plug.Conn.t(), atom(), String.t()) :: Plug.Conn.t()
  def send(conn, kind, message) do
    {status, code} = Map.fetch!(@codes, kind)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: %{code: code, message: message}}))
  end

  @doc "Maps common context error tuples onto the envelope."
  @spec from_result(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def from_result(conn, {:error, :not_found}),
    do: send(conn, :not_found, "Not found.")

  def from_result(conn, {:error, :unauthorized}),
    do: send(conn, :forbidden, "You are not allowed to do that.")

  def from_result(conn, {:error, :rate_limited}),
    do: send(conn, :rate_limited, "Too many attempts. Try again later.")

  def from_result(conn, {:error, :comments_locked}),
    do: send(conn, :comments_locked, "Comments are locked on this post.")

  def from_result(conn, {:error, :poll_closed}),
    do: send(conn, :poll_closed, "This poll is closed.")

  # Availability polls close once (issue #184): responding to, closing,
  # or converting a closed poll is refused with the same poll-closed
  # class the feed uses.
  def from_result(conn, {:error, :closed}),
    do: send(conn, :poll_closed, "This poll is closed.")

  def from_result(conn, {:error, :no_options}),
    do: send(conn, :bad_request, "Provide at least one candidate date in `options`.")

  # An assignment already marked done (issue #184) can't be claimed or
  # completed again.
  def from_result(conn, {:error, :done}),
    do: send(conn, :unprocessable, "This assignment is already done.")

  def from_result(conn, {:error, :slot_full}),
    do: send(conn, :slot_full, "This signup slot is full.")

  def from_result(conn, {:error, :owner_cannot_leave}),
    do: send(conn, :owner_cannot_leave, "Owners can't leave — transfer ownership first.")

  def from_result(conn, {:error, :last_owner}),
    do:
      send(
        conn,
        :last_owner,
        "The last owner can't be demoted — promote another owner first."
      )

  def from_result(conn, {:error, :not_a_member}),
    do: send(conn, :not_found, "Not found.")

  def from_result(conn, {:error, reason}) when reason in [:banned, :instance_banned],
    do: send(conn, :unprocessable, "That person is banned from this community.")

  def from_result(conn, {:error, :not_acknowledgment_post}),
    do: send(conn, :unprocessable, "This post does not require acknowledgment.")

  def from_result(conn, {:error, :invalid_attachment}),
    do: send(conn, :unprocessable, "stored_file_ids must be files you uploaded to this group.")

  def from_result(conn, {:error, :invalid_poll}),
    do: send(conn, :bad_request, "poll must be an object.")

  def from_result(conn, {:error, :file_too_large}),
    do: send(conn, :payload_too_large, "That file is larger than this instance allows.")

  def from_result(conn, {:error, :quota_exceeded}),
    do: send(conn, :quota_exceeded, "This group's file storage is full.")

  def from_result(conn, {:error, :too_deep}),
    do: send(conn, :unprocessable, "This folder can't hold another level of subfolders.")

  def from_result(conn, {:error, :system_folder}),
    do: send(conn, :unprocessable, "System folders can't be deleted.")

  def from_result(conn, {:error, :last_version}),
    do: send(conn, :unprocessable, "That's the only version — delete the file itself instead.")

  def from_result(conn, {:error, %Ecto.Changeset{} = changeset}) do
    details =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Regex.replace(~r"%{(\w+)}", message, fn _match, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      422,
      Jason.encode!(%{
        error: %{code: "invalid_params", message: "Validation failed.", details: details}
      })
    )
  end

  def from_result(conn, {:error, _other}),
    do: send(conn, :bad_request, "The request could not be processed.")
end
