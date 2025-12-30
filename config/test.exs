import Config

config :durable, Durable.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 54321,
  database: "durable_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Disable queue polling in tests - use inline execution instead
config :durable,
  queue_enabled: false

config :logger, level: :warning
