defmodule Kammer.Repo do
  use Ecto.Repo,
    otp_app: :kammer,
    adapter: Ecto.Adapters.Postgres
end
