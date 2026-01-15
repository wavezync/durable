defmodule PhoenixDemo.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PhoenixDemoWeb.Telemetry,
      PhoenixDemo.Repo,
      {DNSCluster, query: Application.get_env(:phoenix_demo, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: PhoenixDemo.PubSub},
      # Durable workflow engine
      {Durable, repo: PhoenixDemo.Repo, queues: %{default: [concurrency: 5]}},
      # Start to serve requests, typically the last entry
      PhoenixDemoWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PhoenixDemo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PhoenixDemoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
