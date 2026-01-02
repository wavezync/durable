defmodule Durable.TestRepo do
  use Ecto.Repo,
    otp_app: :durable,
    adapter: Ecto.Adapters.Postgres
end
