defmodule Kammer.Repo.Migrations.AddFeedSortToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :feed_sort, :string, default: "chronological", null: false
    end
  end
end
