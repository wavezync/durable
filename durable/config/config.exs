import Config

# Durable is now an embeddable library - this config is for development/testing only.
# In production, users provide their own repo when adding Durable to their supervision tree.

config :durable,
  # Test repo for library's internal tests
  ecto_repos: [Durable.TestRepo],

  # Log capture configuration
  # Captures Logger and IO output during workflow step execution
  log_capture: [
    enabled: true,
    levels: [:debug, :info, :warning, :error],
    io_capture: true,
    io_passthrough: false,
    max_log_entries: 1000,
    max_message_length: 10_000,
    metadata_filter: [:request_id, :user_id, :module, :function, :line]
  ]

config :durable, Durable.TestRepo,
  migration_primary_key: [type: :binary_id],
  migration_timestamps: [type: :utc_datetime_usec]

import_config "#{config_env()}.exs"
