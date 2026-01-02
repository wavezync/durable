defmodule Durable.Application do
  @moduledoc false

  use Application

  alias Durable.LogCapture.Handler

  @impl true
  def start(_type, _args) do
    # Register log capture handler for workflow step logging
    :ok = Handler.attach()

    # Start a minimal supervisor - the actual Durable processes are started
    # when users add Durable to their own supervision tree
    opts = [strategy: :one_for_one, name: Durable.Application.Supervisor]
    Supervisor.start_link([], opts)
  end
end
