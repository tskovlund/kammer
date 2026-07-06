defmodule Kammer.Repo.Migrations.AddSearchIndexes do
  use Ecto.Migration

  # GIN indexes for global search (SPEC §16). The 'simple' configuration
  # is deliberate: instances mix Danish and English freely, and
  # language-specific stemming on the wrong language hurts more than no
  # stemming at all. Queries use the same configuration — they must, or
  # the indexes are dead weight.

  def up do
    execute("""
    CREATE INDEX posts_search_index ON posts
    USING gin (to_tsvector('simple', coalesce(body_markdown, '')))
    """)

    execute("""
    CREATE INDEX comments_search_index ON comments
    USING gin (to_tsvector('simple', coalesce(body_markdown, '')))
    """)

    execute("""
    CREATE INDEX events_search_index ON events
    USING gin (to_tsvector('simple', coalesce(title, '') || ' ' || coalesce(description_markdown, '')))
    """)
  end

  def down do
    execute("DROP INDEX posts_search_index")
    execute("DROP INDEX comments_search_index")
    execute("DROP INDEX events_search_index")
  end
end
