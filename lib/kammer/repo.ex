defmodule Kammer.Repo do
  @moduledoc "The app's Ecto repository — the single Postgres data gateway."
  use Ecto.Repo,
    otp_app: :kammer,
    adapter: Ecto.Adapters.Postgres
end
