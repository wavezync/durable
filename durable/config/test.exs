import Config

config :durable, Durable.TestRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 54321,
  database: "durable_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Real, committed connections for the `:integration` tests with live pollers.
# The sandbox can't serve those: pollers and workers are other processes, and
# inside its one transaction NOW() never moves, so a parked run never comes due.
config :durable, Durable.IntegrationRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  # Point this at a PgBouncer to run the live suites through a connection pooler.
  port: String.to_integer(System.get_env("INTEGRATION_DB_PORT", "54321")),
  database: "durable_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool_size: 10

# Log level for tests - keep higher to reduce noise, but allow info for log capture tests
config :logger, level: :info

# Real spans for the OpenTelemetry tests, handed to the test that asks for them.
config :opentelemetry,
  id_generator: Durable.OpenTelemetry.IdGenerator,
  span_processor: :simple,
  traces_exporter: :none
