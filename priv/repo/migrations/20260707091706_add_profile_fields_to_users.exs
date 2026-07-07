defmodule Kammer.Repo.Migrations.AddProfileFieldsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :bio, :string
      add :pronouns, :string

      add :contact_phone, :string
      add :contact_phone_visibility, :string, default: "hidden", null: false

      add :contact_email, :string
      add :contact_email_visibility, :string, default: "hidden", null: false

      add :contact_note, :string
      add :contact_note_visibility, :string, default: "hidden", null: false
    end
  end
end
