defmodule Kammer.Repo.Migrations.AddSearchToStoredFiles do
  use Ecto.Migration

  # File search (SPEC §10/§16): extracted text plus the same 'simple'
  # GIN-index pattern the posts/comments/events search indexes already
  # use (see 20260706230923_add_search_indexes.exs) — no stemming,
  # instances mix Danish and English. Dots/underscores/hyphens in the
  # filename are normalized to spaces first: Postgres' 'simple' parser
  # otherwise tokenizes "budget.pdf" as one opaque "file" token, so a
  # search for "budget" would never match it.

  def up do
    alter table(:stored_files) do
      add :extracted_text, :text
      add :text_extracted_at, :utc_datetime
    end

    execute("""
    CREATE INDEX stored_files_search_index ON stored_files
    USING gin (to_tsvector('simple', regexp_replace(coalesce(filename, ''), '[._-]', ' ', 'g') || ' ' || coalesce(extracted_text, '')))
    """)
  end

  def down do
    execute("DROP INDEX stored_files_search_index")

    alter table(:stored_files) do
      remove :extracted_text
      remove :text_extracted_at
    end
  end
end
