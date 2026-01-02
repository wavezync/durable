defmodule Durable.TestRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :durable,
    adapter: Ecto.Adapters.Postgres
end
