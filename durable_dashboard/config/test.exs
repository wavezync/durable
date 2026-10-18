import Config

# Endpoint used by `live_isolated/3` and other LV-mount tests. The library
# ships no endpoint of its own; this is purely a test fixture.
config :durable_dashboard, DurableDashboard.TestEndpoint,
  url: [host: "localhost"],
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "durable-dashboard-test"],
  pubsub_server: DurableDashboard.TestPubSub,
  server: false

config :phoenix, :json_library, Jason
config :logger, level: :warning

# Page tests (`DurableDashboard.LiveCase`) mount the real LiveViews against a
# Durable instance on this repo. Same Postgres as the core suite (compose,
# port 54321), its own database.
config :durable_dashboard, DurableDashboard.TestRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 54_321,
  database: "durable_dashboard_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10
