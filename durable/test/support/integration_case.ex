defmodule Durable.IntegrationCase do
  @moduledoc """
  Live pollers, workers and sweeps over real, committed connections, with the
  real clock. Everything the SQL sandbox can't do: `NOW()` moves on, so a parked
  run comes due, and other processes (and other nodes) can see the rows.

  These tests truncate the tables, so they're tagged `:integration` and left out
  of the default suite. Run them with `mix test --only integration`.
  """

  use ExUnit.CaseTemplate

  alias Durable.IntegrationProbe
  alias Durable.IntegrationRepo
  alias Durable.Storage.Schemas.WorkflowExecution

  using do
    quote do
      @moduletag :integration

      import Durable.DataCase,
        only: [assert_eventually: 1, assert_eventually: 2, assert_eventually: 3]

      import Durable.IntegrationCase
      import Ecto.Query

      alias Durable.IntegrationProbe, as: Probe
      alias Durable.IntegrationRepo
      alias Durable.IntegrationWorkflows, as: W
      alias Durable.Storage.Schemas.{StepExecution, WorkflowExecution}
    end
  end

  setup_all do
    start_supervised!(IntegrationRepo)
    :ok
  end

  setup do
    truncate!()
    on_exit(&truncate_after_test/0)
    start_supervised!(IntegrationProbe)
    :ok
  end

  defp truncate! do
    IntegrationRepo.query!("""
    TRUNCATE durable.workflow_executions, durable.scheduled_workflows, durable.nodes,
             durable.queues, durable.queue_samples, durable.activity RESTART IDENTITY CASCADE
    """)
  end

  # The repo in `setup_all` outlives the test, so this can use it.
  defp truncate_after_test, do: truncate!()

  def get(id), do: IntegrationRepo.get!(WorkflowExecution, id)

  def await_status(id, status, timeout \\ 10_000) do
    Durable.DataCase.assert_eventually(
      fn -> get(id).status == status end,
      timeout,
      20
    )

    get(id)
  end

  @doc "Starts Durable here with live pollers on `queues` (queue => concurrency)."
  def start_durable!(queues, opts \\ []) do
    {poll_interval, opts} = Keyword.pop(opts, :poll_interval, 25)

    Durable.DataCase.start_supervised_durable!(
      [repo: IntegrationRepo, queues: queue_opts(queues, poll_interval)] ++ opts
    )
  end

  def queue_opts(queues, poll_interval \\ 25) do
    Map.new(queues, fn {queue, concurrency} ->
      {queue, [concurrency: concurrency, poll_interval: poll_interval]}
    end)
  end

  # ===========================================================================
  # Other nodes
  # ===========================================================================

  @doc """
  Starts a real second BEAM node running Durable, on the same database. Stopped
  with the test. Its Phoenix.PubSub clusters with the other nodes'.
  """
  def start_node!(name, queues, opts \\ []) do
    ensure_distributed!()

    peer = %{
      name: name,
      host: ~c"127.0.0.1",
      args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
    }

    spec = %{id: name, restart: :temporary, start: {:peer, :start_link, [peer]}}
    {:ok, _pid, node} = start_supervised(spec)

    poll_interval = Keyword.get(opts, :poll_interval, 25)

    durable_opts =
      [
        name: Durable,
        repo: IntegrationRepo,
        pubsub: :start,
        queues: queue_opts(queues, poll_interval),
        heartbeat_interval: 100
      ] ++ Keyword.delete(opts, :poll_interval)

    :erpc.call(node, :code, :add_paths, [:code.get_path()])

    :ok =
      :erpc.call(node, __MODULE__, :boot_node, [
        Application.fetch_env!(:durable, IntegrationRepo),
        durable_opts
      ])

    node
  end

  @doc false
  def boot_node(repo_config, durable_opts) do
    {:ok, _} = Application.ensure_all_started(:logger)
    Logger.configure(level: :critical)
    Application.put_env(:durable, IntegrationRepo, repo_config)

    for app <- [:postgrex, :ecto_sql, :phoenix_pubsub, :durable] do
      {:ok, _} = Application.ensure_all_started(app)
    end

    :global.sync()

    {:ok, supervisor} =
      Supervisor.start_link([IntegrationRepo, {Durable, durable_opts}], strategy: :one_for_one)

    Process.unlink(supervisor)
    :ok
  end

  @doc "Starts a run inside a transaction that stays open a while after it."
  def start_in_transaction(workflow, input) do
    {:ok, id} =
      IntegrationRepo.transaction(fn ->
        {:ok, id} = Durable.start(workflow, input)
        Process.sleep(200)
        id
      end)

    id
  end

  @doc "Waits for the nodes to see each other, so a broadcast reaches them all."
  def connect_nodes!(nodes) do
    for a <- nodes, b <- nodes, a != b, do: true = :erpc.call(a, Node, :connect, [b])
    Process.sleep(300)
  end

  @doc "Kills a node the way a crash would: no shutdown, no clean-up."
  def crash_node!(node) do
    Node.monitor(node, true)
    :erpc.cast(node, :erlang, :halt, [137])

    receive do
      {:nodedown, ^node} -> :ok
    after
      5_000 -> raise "#{node} didn't go down"
    end
  end

  defp ensure_distributed! do
    unless Node.alive?() do
      {_, 0} = System.cmd("epmd", ["-daemon"])
      {:ok, _} = Node.start(:"durable_test@127.0.0.1", :longnames)
    end
  end
end
