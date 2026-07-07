defmodule Kammer.Files.TextExtraction do
  @moduledoc """
  Extracts searchable text from a stored file's bytes (SPEC §10/§16):
  plaintext is read directly, PDFs go through `pdftotext` (poppler,
  shelled out — no Elixir-native PDF library fits the codebase's
  in-process NIF pattern, and `pdftotext` is the "boring, maintained"
  choice SPEC §22 asks for). Anything else is a graceful skip, not an
  error — most stored files (images, archives, office docs) simply
  aren't searchable this way yet.
  """

  require Logger

  @plaintext_content_types ~w(text/plain text/markdown text/csv)
  @pdf_content_type "application/pdf"

  # Generous enough for full-text search over long documents without
  # letting one huge file dominate the index or the row.
  @max_chars 100_000

  @doc """
  Extracts text from the file at `path` given its `content_type`.
  Returns `:skip` for content types with no extractor, `{:error, _}`
  if a supported type's extractor fails.
  """
  @spec extract(String.t(), Path.t()) :: {:ok, String.t()} | :skip | {:error, term()}
  def extract(content_type, path) do
    cond do
      content_type in @plaintext_content_types -> extract_plaintext(path)
      content_type == @pdf_content_type -> extract_pdf(path)
      true -> :skip
    end
  end

  defp extract_plaintext(path) do
    case File.read(path) do
      {:ok, contents} ->
        if String.valid?(contents) do
          {:ok, truncate(contents)}
        else
          {:error, :invalid_encoding}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_pdf(path) do
    case System.cmd("pdftotext", ["-layout", path, "-"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, truncate(output)}
      {output, status} -> {:error, {:pdftotext_failed, status, output}}
    end
  rescue
    error in ErlangError ->
      Logger.warning("pdftotext unavailable: #{Exception.message(error)}")
      {:error, :pdftotext_unavailable}
  end

  defp truncate(text), do: String.slice(text, 0, @max_chars)
end
