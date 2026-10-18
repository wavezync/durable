{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: DurableDashboard.TestPubSub)
{:ok, _} = DurableDashboard.TestEndpoint.start_link()

# Page tests need Postgres (compose: `docker compose up -d` in the repo root).
:ok = DurableDashboard.TestRepo.setup!()
Ecto.Adapters.SQL.Sandbox.mode(DurableDashboard.TestRepo, :manual)

# `:known_bug` marks a page test that shows a real bug not fixed yet; run
# them with `mix test --only known_bug`.
ExUnit.start(exclude: [:known_bug])
