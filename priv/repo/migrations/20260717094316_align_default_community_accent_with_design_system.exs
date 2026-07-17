defmodule Kammer.Repo.Migrations.AlignDefaultCommunityAccentWithDesignSystem do
  use Ecto.Migration

  # The default community accent flips from the legacy green (#3E6B48)
  # to the design-system accent (#8a4b24, issue #328), so a
  # never-customized community renders monotone with the chrome and a
  # tint is always a deliberate admin choice. Rows still on the old
  # default follow: the Ecto schema default stored the uppercase
  # literal, but a browser color input emits lowercase for the same
  # untouched default, so the match is case-insensitive.
  def up do
    alter table(:communities) do
      modify :accent_color, :string, null: false, default: "#8a4b24"
    end

    execute """
    UPDATE communities SET accent_color = '#8a4b24'
    WHERE lower(accent_color) = '#3e6b48'
    """
  end

  # Row data is deliberately not reverted: after the flip, a row on
  # #8a4b24 that was migrated is indistinguishable from one whose
  # admin chose it on purpose — the data migration is one-way.
  def down do
    alter table(:communities) do
      modify :accent_color, :string, null: false, default: "#3E6B48"
    end
  end
end
