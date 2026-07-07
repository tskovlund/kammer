defmodule Kammer.Files.TextExtractionTest do
  use ExUnit.Case, async: true

  alias Kammer.Files.TextExtraction

  @moduletag :tmp_dir

  defp write(tmp_dir, name, contents) do
    path = Path.join(tmp_dir, name)
    File.write!(path, contents)
    path
  end

  # A minimal, hand-written PDF (poppler falls back to a linear scan when
  # the xref table is absent, so this needs no accurate byte offsets).
  defp write_pdf(tmp_dir, name, text) do
    stream = "BT /F1 24 Tf 20 100 Td (#{text}) Tj ET"

    contents = """
    %PDF-1.4
    1 0 obj
    << /Type /Catalog /Pages 2 0 R >>
    endobj
    2 0 obj
    << /Type /Pages /Kids [3 0 R] /Count 1 >>
    endobj
    3 0 obj
    << /Type /Page /Parent 2 0 R /Resources << /Font << /F1 4 0 R >> >> /MediaBox [0 0 200 200] /Contents 5 0 R >>
    endobj
    4 0 obj
    << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>
    endobj
    5 0 obj
    << /Length #{byte_size(stream)} >>
    stream
    #{stream}
    endstream
    endobj
    trailer
    << /Size 6 /Root 1 0 R >>
    %%EOF
    """

    write(tmp_dir, name, contents)
  end

  describe "plaintext" do
    test "reads text/plain, text/markdown, and text/csv directly", %{tmp_dir: tmp_dir} do
      path = write(tmp_dir, "notes.txt", "Generalprøven er flyttet")
      assert {:ok, "Generalprøven er flyttet"} = TextExtraction.extract("text/plain", path)

      md_path = write(tmp_dir, "notes.md", "# Referat")
      assert {:ok, "# Referat"} = TextExtraction.extract("text/markdown", md_path)

      csv_path = write(tmp_dir, "list.csv", "navn,rolle\nAnna,formand")
      assert {:ok, "navn,rolle\nAnna,formand"} = TextExtraction.extract("text/csv", csv_path)
    end

    test "rejects invalid UTF-8", %{tmp_dir: tmp_dir} do
      path = write(tmp_dir, "binary.txt", <<0xFF, 0xFE, 0x00>>)
      assert {:error, :invalid_encoding} = TextExtraction.extract("text/plain", path)
    end

    test "truncates very long plaintext", %{tmp_dir: tmp_dir} do
      path = write(tmp_dir, "huge.txt", String.duplicate("a", 200_000))
      assert {:ok, text} = TextExtraction.extract("text/plain", path)
      assert String.length(text) == 100_000
    end
  end

  describe "PDF" do
    test "extracts text via pdftotext", %{tmp_dir: tmp_dir} do
      path = write_pdf(tmp_dir, "handout.pdf", "Hello Kammer")
      assert {:ok, text} = TextExtraction.extract("application/pdf", path)
      assert text =~ "Hello Kammer"
    end
  end

  describe "unsupported types" do
    test "skips images and everything else", %{tmp_dir: tmp_dir} do
      path = write(tmp_dir, "photo.jpg", "not really a jpeg")
      assert :skip = TextExtraction.extract("image/jpeg", path)
      assert :skip = TextExtraction.extract("application/zip", path)
    end
  end
end
