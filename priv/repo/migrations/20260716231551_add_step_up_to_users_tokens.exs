defmodule Kammer.Repo.Migrations.AddStepUpToUsersTokens do
  use Ecto.Migration

  # Step-up re-auth (issue #294, ADR 0029): `stepped_up_at` marks an
  # api-device token row as recently re-authenticated; `target_token_id`
  # points a single-use "step-up" email token at the device-token row it
  # steps up. The self-referential FK cascades, so revoking a device
  # kills any step-up link still in flight for it.
  def change do
    alter table(:users_tokens) do
      add :stepped_up_at, :utc_datetime
      add :target_token_id, references(:users_tokens, type: :binary_id, on_delete: :delete_all)
    end

    create index(:users_tokens, [:target_token_id])
  end
end
