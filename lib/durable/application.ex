defmodule Durable.Application do
  @moduledoc false

  use Application

  alias Durable.LogCapture.Handler

  @impl true
  def start(_type, _args) do
    # Register log capture handler for workflow step logging
    :ok = Handler.attach()

    children = [
      Durable.Repo,
      Durable.Queue.Manager
    ]

    opts = [strategy: :one_for_one, name: Durable.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
