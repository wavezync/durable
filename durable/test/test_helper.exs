# Start the test repo
{:ok, _} = Durable.TestRepo.start_link()

# `:integration` tests use REAL (committed) connections via
# `Sandbox.unboxed_run/2` to exercise genuine multi-backend concurrency
# (FOR UPDATE SKIP LOCKED, FOR UPDATE row locks) that the shared SQL Sandbox
# structurally cannot. They truncate tables, so they must run in isolation —
# excluded from the default suite, run with `mix test --only integration`.
ExUnit.start(exclude: [:integration])

Ecto.Adapters.SQL.Sandbox.mode(Durable.TestRepo, :manual)
