defmodule Kammer.MediaTest do
  @moduledoc """
  The libvips image pipeline (SPEC §11, §19): every uploaded image is
  re-encoded (destroying embedded payloads and EXIF/GPS metadata) and
  thumbnailed. `Kammer.FilesTest` covers this at the upload boundary
  (stored dimensions, thumbnail key); this file covers `process_image/1`
  itself — the metadata-stripping guarantee SPEC §11 credits it with,
  which nothing else exercises.
  """

  use ExUnit.Case, async: true

  alias Vix.Vips.Image
  alias Vix.Vips.MutableImage
  alias Vix.Vips.Operation
  alias Kammer.Media

  @moduletag :tmp_dir

  defp write_image(path, width, height) do
    {:ok, image} = Operation.black(width, height)
    :ok = Image.write_to_file(image, path)
    path
  end

  defp write_image_with_exif(path, width, height) do
    {:ok, image} = Operation.black(width, height)

    {:ok, with_exif} =
      Image.mutate(image, fn mut_image ->
        :ok = MutableImage.set(mut_image, "exif-data", :VipsBlob, <<1, 2, 3, 4>>)
      end)

    :ok = Image.write_to_file(with_exif, path)
    path
  end

  describe "image_content_type?/1" do
    test "accepts the supported image formats, rejects everything else" do
      for content_type <- ~w(image/jpeg image/png image/webp image/gif image/heic image/heif) do
        assert Media.image_content_type?(content_type)
      end

      refute Media.image_content_type?("application/pdf")
      refute Media.image_content_type?("text/plain")
    end
  end

  describe "process_image/1" do
    test "re-encodes to JPEG and strips embedded EXIF metadata", %{tmp_dir: tmp_dir} do
      source = write_image_with_exif(Path.join(tmp_dir, "photo.jpg"), 64, 48)

      {:ok, reloaded_source} = Image.new_from_file(source)
      assert {:ok, _exif} = Image.header_value(reloaded_source, "exif-data")

      assert {:ok, result} = Media.process_image(source)
      assert result.content_type == "image/jpeg"

      {:ok, display} = Image.new_from_file(result.display_path)
      assert {:error, _not_found} = Image.header_value(display, "exif-data")
    end

    test "reports the display image's actual dimensions, unscaled below the max width", %{
      tmp_dir: tmp_dir
    } do
      source = write_image(Path.join(tmp_dir, "small.jpg"), 64, 48)

      assert {:ok, result} = Media.process_image(source)
      assert result.width == 64
      assert result.height == 48

      {:ok, display} = Image.new_from_file(result.display_path)
      assert Image.width(display) == 64
      assert Image.height(display) == 48
    end

    test "downscales an image wider than the 1600px display max, preserving aspect ratio", %{
      tmp_dir: tmp_dir
    } do
      source = write_image(Path.join(tmp_dir, "wide.jpg"), 3200, 1600)

      assert {:ok, result} = Media.process_image(source)
      assert result.width == 1600
      assert result.height == 800
    end

    test "produces a WebP thumbnail no wider than the 480px thumbnail max", %{tmp_dir: tmp_dir} do
      source = write_image(Path.join(tmp_dir, "photo.jpg"), 2000, 1000)

      assert {:ok, result} = Media.process_image(source)
      assert File.exists?(result.thumbnail_path)

      assert <<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>> =
               File.read!(result.thumbnail_path)

      {:ok, thumbnail} = Image.new_from_file(result.thumbnail_path)
      assert Image.width(thumbnail) == 480
    end

    test "an unreadable source path is an error, not a raise" do
      assert {:error, _reason} = Media.process_image("/nonexistent/path/does-not-exist.jpg")
    end
  end
end
