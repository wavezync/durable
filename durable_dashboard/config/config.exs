import Config

# Test-only configuration. Production users of `:durable_dashboard` configure
# their own host endpoint; nothing here ships in the Hex package (the `:files`
# in mix.exs excludes `config/`).

if config_env() == :test do
  import_config "test.exs"
end
