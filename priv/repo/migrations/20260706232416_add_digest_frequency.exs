defmodule Kammer.Repo.Migrations.AddDigestFrequency do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Digests are opt-in (SPEC §9's calm-by-default stance): nobody
      # gets scheduled email they didn't ask for.
      add :digest_frequency, :string, null: false, default: "off"
      add :last_digest_at, :utc_datetime
    end
  end
end
