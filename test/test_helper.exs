# Start the test repo
{:ok, _} = Durable.TestRepo.start_link()

ExUnit.start()

Ecto.Adapters.SQL.Sandbox.mode(Durable.TestRepo, :manual)
