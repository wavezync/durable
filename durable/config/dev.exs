import Config

config :durable, Durable.TestRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 54321,
  database: "durable_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :logger, :console, format: "[$level] $message\n"

# The SDK is here for dialyzer and docs; nothing in dev has an exporter to send to.
config :opentelemetry, traces_exporter: :none
