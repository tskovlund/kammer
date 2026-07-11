defmodule KammerWeb.Api.ReportIntake do
  @moduledoc """
  The neutral report acknowledgement every intake endpoint shares
  (issues #256/#262): posts, feed comments, event comments, and
  assignment comments all answer a report with the same
  `201 {status: "reported"}`. A repeat report of the same subject
  answers exactly like the first — the moderators already have it, and
  the LiveView flow treats that the same way — so only the
  unique-constraint changeset (`Moderation.duplicate_report?/1`)
  collapses into success; a genuinely invalid reason still answers 422.

  Deleted (tombstoned) comments stay reportable here on purpose —
  moderators can still read the body, and the tombstone may itself be
  what needs reporting — while the PWA hides the affordance on deleted
  rows; a deliberate server/client divergence, not an oversight.
  """

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn, only: [put_status: 2]

  alias Kammer.Moderation
  alias KammerWeb.ApiError

  @doc """
  Turns a `Moderation.report_post/3`/`report_comment/3` result into the
  neutral response; other errors pass through to the caller's error
  envelope.
  """
  @spec respond(Plug.Conn.t(), {:ok, term()} | {:error, term()}) ::
          Plug.Conn.t() | {:error, term()}
  def respond(conn, result) do
    case result do
      {:ok, _report} ->
        reported(conn)

      {:error, %Ecto.Changeset{} = changeset} ->
        if Moderation.duplicate_report?(changeset), do: reported(conn), else: {:error, changeset}

      error ->
        error
    end
  end

  defp reported(conn) do
    conn |> put_status(201) |> json(%{data: %{status: "reported"}})
  end

  @doc """
  The shared 400 for a missing/non-string `reason` — one message across
  all four intake endpoints, fired uniformly before any lookup so it
  can never become a visibility oracle.
  """
  @spec reject_missing_reason(Plug.Conn.t()) :: Plug.Conn.t()
  def reject_missing_reason(conn),
    do: ApiError.send(conn, :bad_request, "Send a `reason` string.")
end
