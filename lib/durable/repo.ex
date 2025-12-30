defmodule Durable.Repo do
  use Ecto.Repo,
    otp_app: :durable,
    adapter: Ecto.Adapters.Postgres
end
