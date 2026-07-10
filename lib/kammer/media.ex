defmodule Kammer.Media do
  @moduledoc """
  Image processing pipeline via libvips (SPEC §19): every uploaded image
  is **re-encoded** (destroying embedded payloads, SPEC §11), stripped of
  EXIF metadata (GPS, serials) with orientation preserved via the
  re-encode, HEIC/HEIF converted to web formats, and thumbnailed.
  """

  alias Vix.Vips.Image
  alias Vix.Vips.Operation

  # Deliberately fixed, not tier-2 config (ADR 0027): changing these
  # widths doesn't regenerate already-stored images, so a runtime
  # knob here would silently desync existing thumbnails/display
  # copies from freshly-processed ones — a backfill hazard, not a
  # free operator knob. Revisit only alongside an actual backfill job.
  @display_max_width 1600
  @thumbnail_width 480

  @image_content_types ~w(image/jpeg image/png image/webp image/gif image/heic image/heif)

  @doc "Content types treated as processable images."
  @spec image_content_type?(String.t()) :: boolean()
  def image_content_type?(content_type), do: content_type in @image_content_types

  @doc """
  Processes an uploaded image file on disk: re-encodes the display
  version to JPEG (max #{@display_max_width}px wide) and produces a WebP
  thumbnail, both metadata-stripped and auto-rotated.

  Returns `{:ok, %{display: {path, "image/jpeg", width, height}, thumbnail: path}}`
  with paths in the same temporary directory.
  """
  @spec process_image(Path.t()) ::
          {:ok,
           %{
             display_path: Path.t(),
             content_type: String.t(),
             width: pos_integer(),
             height: pos_integer(),
             thumbnail_path: Path.t()
           }}
          | {:error, term()}
  def process_image(source_path) do
    display_path = source_path <> "_display.jpg"
    thumbnail_path = source_path <> "_thumb.webp"

    with {:ok, display_image} <-
           Operation.thumbnail(source_path, @display_max_width,
             size: :VIPS_SIZE_DOWN,
             "no-rotate": false
           ),
         :ok <- Image.write_to_file(display_image, display_path <> "[Q=85,strip]"),
         {:ok, thumbnail_image} <-
           Operation.thumbnail(source_path, @thumbnail_width,
             size: :VIPS_SIZE_DOWN,
             "no-rotate": false
           ),
         :ok <- Image.write_to_file(thumbnail_image, thumbnail_path <> "[Q=80,strip]") do
      {:ok,
       %{
         display_path: display_path,
         content_type: "image/jpeg",
         width: Image.width(display_image),
         height: Image.height(display_image),
         thumbnail_path: thumbnail_path
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end
end
