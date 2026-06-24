# Start the test repo
{:ok, _} = Durable.TestRepo.start_link()

# `:integration` tests use REAL (committed) connections via
# `Sandbox.unboxed_run/2` to exercise genuine multi-backend concurrency
# (FOR UPDATE SKIP LOCKED, FOR UPDATE row locks) that the shared SQL Sandbox
# structurally cannot. They truncate tables, so they must run in isolation —
# excluded from the default suite, run with `mix test --only integration`.
ExUnit.start(exclude: [:integration])

Ecto.Adapters.SQL.Sandbox.mode(Durable.TestRepo, :manual)

# Cold builds + the highly parallel suite can race the BEAM's on-demand code
# loader: the first dynamic reference to a freshly-compiled module can transiently
# fail with "module ... is not available". We've seen it hit Durable mix tasks
# (called directly as `<Task>.run/1`, e.g. `MigrationsTask.run/1`) and Postgrex's
# lazily-loaded error-code table (`Postgrex.ErrorCode`, used when mapping a DB
# error such as a unique violation). The build is settled here and we're still
# single-threaded, so eagerly load those apps' modules before any test runs.
for app <- [:durable, :postgrex],
    mod <- Application.spec(app, :modules) || [] do
  Code.ensure_loaded(mod)
end
