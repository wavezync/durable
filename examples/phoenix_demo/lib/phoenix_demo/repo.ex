defmodule PhoenixDemo.Repo do
  use Ecto.Repo,
    otp_app: :phoenix_demo,
    adapter: Ecto.Adapters.Postgres
end
