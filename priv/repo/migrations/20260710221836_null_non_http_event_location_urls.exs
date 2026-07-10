defmodule Kammer.Repo.Migrations.NullNonHttpEventLocationUrls do
  use Ecto.Migration

  # Rows written before Event.location_url was scheme-validated (issue
  # #247) can hold values a raw <a href> must never receive
  # (javascript:, data:, ...). The render guards protect the app's own
  # surfaces, but the stored value also flows into the ICS export and
  # any future consumer — cleaning the data ends that class at the
  # source. Approximates Kammer.Validation.http_url?/1's rule in SQL
  # (optionally space-padded, then http(s)://<non-space, non-slash>);
  # [[:space:]] is ASCII-only, so a safe row padded with exotic
  # Unicode whitespace could be over-nulled — conservative on
  # purpose: this may null a safe row, never keep an unsafe one.
  def up do
    execute """
    UPDATE events SET location_url = NULL
    WHERE location_url IS NOT NULL
      AND location_url !~* '^[[:space:]]*https?://[^[:space:]/]'
    """
  end

  # The overwritten values are unrecoverable by design (they were
  # unsafe to render); nothing to restore.
  def down, do: :ok
end
