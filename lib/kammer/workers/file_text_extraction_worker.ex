defmodule Kammer.Workers.FileTextExtractionWorker do
  @moduledoc """
  Extracts a stored file's searchable text (SPEC §10/§16) after
  upload, off the request path. `text_extracted_at` is stamped
  whether extraction produced text or was skipped, so a file is never
  retried forever for a content type with no extractor.
  """

  use Oban.Worker, queue: :media, max_attempts: 3

  require Logger

  alias Kammer.Files.StoredFile
  alias Kammer.Files.TextExtraction
  alias Kammer.Repo
  alias Kammer.Storage

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{args: %{"stored_file_id" => stored_file_id}}) do
    case Repo.get(StoredFile, stored_file_id) do
      nil ->
        :ok

      %StoredFile{} = stored_file ->
        with {:ok, path} <- Storage.path_for(stored_file.storage_key) do
          extracted_text =
            case TextExtraction.extract(stored_file.content_type, path) do
              {:ok, text} ->
                text

              :skip ->
                nil

              {:error, reason} ->
                Logger.warning(
                  "text extraction for stored file #{stored_file_id} failed: #{inspect(reason)}"
                )

                nil
            end

          stored_file
          |> Ecto.Changeset.change(
            extracted_text: extracted_text,
            text_extracted_at: DateTime.utc_now(:second)
          )
          |> Repo.update!()

          :ok
        end
    end
  end
end
