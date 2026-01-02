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
