defmodule Kammer.Repo.Migrations.CreateUserPasskeys do
  use Ecto.Migration

  def change do
    create table(:user_passkeys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      # The credential id is the lookup key for usernameless sign-in
      # (we don't know the user until we've found their credential), so
      # it is unique instance-wide, not just per user.
      add :credential_id, :binary, null: false
      # `:erlang.term_to_binary/1` of the COSE key map Wax returns —
      # opaque on purpose, Wax.CoseKey.verify/3 is the only reader.
      add :public_key_cose, :binary, null: false
      add :aaguid, :binary
      add :sign_count, :integer, null: false, default: 0
      add :nickname, :string
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_passkeys, [:credential_id])
    create index(:user_passkeys, [:user_id])
  end
end
