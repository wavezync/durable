import Config

config :durable, Durable.TestRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 54321,
  database: "durable_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Log level for tests - keep higher to reduce noise, but allow info for log capture tests
config :logger, level: :info
