import Config

config :durable,
  ecto_repos: [Durable.Repo],

  # Queue adapter (default: PostgreSQL)
  queue_adapter: Durable.Queue.Adapters.Postgres,

  # Queue configuration
  queues: %{
    default: [concurrency: 10, poll_interval: 1000]
  },

  # Stale lock recovery timeout (seconds)
  stale_lock_timeout: 300,

  # Heartbeat interval (milliseconds)
  # Workers send heartbeats to update locked_at and prevent stale lock recovery
  # Should be less than stale_lock_timeout / 2
  heartbeat_interval: 30_000

config :durable, Durable.Repo,
  migration_primary_key: [type: :binary_id],
  migration_timestamps: [type: :utc_datetime_usec]

import_config "#{config_env()}.exs"
