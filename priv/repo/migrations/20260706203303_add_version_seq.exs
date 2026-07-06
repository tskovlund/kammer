defmodule Kammer.Repo.Migrations.AddVersionSeq do
  use Ecto.Migration

  def change do
    # Version history needs deterministic order; second-granular
    # timestamps tie under rapid uploads, and UUID tiebreaks are
    # arbitrary. A bigserial is monotonic by insertion, always.
    alter table(:stored_files) do
      add :version_seq, :bigserial
    end
  end
end
