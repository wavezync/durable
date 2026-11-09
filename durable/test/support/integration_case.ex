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
  import Ecto.Query, only: [from: 2]

  alias Durable.IntegrationRepo
  alias Durable.Storage.Schemas.WorkflowExecution

  using opts do
    quote do
      @moduletag unquote(Keyword.get(opts, :tag, :integration))

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

  @doc """
  Puts a run's deadline in the past. For a test that needs a run to get
  somewhere and then time out: with a short real `timeout:`, a slow machine
  passes the deadline first and the run never gets there.
  """
  def expire!(id) do
    {1, _} =
      IntegrationRepo.update_all(
        from(w in WorkflowExecution, where: w.id == ^id),
        set: [deadline_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

    :ok
  end

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
      name: unique_node_name(name),
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
      Supervisor.start_link(
        [IntegrationRepo, {Durable, Keyword.put_new(durable_opts, :shutdown_grace_period, 0)}],
        strategy: :one_for_one
      )

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

  @doc "Connects the nodes and waits until a broadcast from any of them reaches them all."
  def connect_nodes!(nodes) do
    for a <- nodes, b <- nodes, a != b, do: true = :erpc.call(a, Node, :connect, [b])
    Durable.DataCase.assert_eventually(fn -> Enum.all?(nodes, &pubsub_reaches?(&1, nodes)) end)
  end

  # Connected isn't enough: each node's PubSub joins its group a moment later.
  defp pubsub_reaches?(from, nodes) do
    groups = :erpc.call(from, :pg, :which_groups, [Phoenix.PubSub])

    groups != [] and
      Enum.all?(groups, fn group ->
        members = :erpc.call(from, :pg, :get_members, [Phoenix.PubSub, group])
        nodes -- Enum.map(members, &node/1) == []
      end)
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
      {:ok, _} = Node.start(:"#{unique_node_name(:durable_test)}@127.0.0.1", :longnames)
    end
  end

  # epmd allows a name once per host, so two test runs on one machine can't share one.
  defp unique_node_name(name), do: :"#{name}_#{System.pid()}"
end
