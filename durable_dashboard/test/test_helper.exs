{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: DurableDashboard.TestPubSub)
{:ok, _} = DurableDashboard.TestEndpoint.start_link()

ExUnit.start()
