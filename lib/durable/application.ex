defmodule Durable.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Durable.Repo,
      Durable.Queue.Manager
    ]

    opts = [strategy: :one_for_one, name: Durable.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
