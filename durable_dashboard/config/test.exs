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
