defmodule LostCommitRepo do
  @moduledoc false
  # Node A's own repo, through LostCommitProxy.
  use Ecto.Repo, otp_app: :durable, adapter: Ecto.Adapters.Postgres
end

defmodule LostCommitProxy do
  @moduledoc false
  # A TCP proxy in front of Postgres that can lose one COMMIT, or its reply.
  # Armed, the next COMMIT any connection sends is:
  #   :drop        never passed on; the connection closes (nothing commits)
  #   :close_reply passed on; its reply is lost and the connection closes
  #   :hang_reply  passed on; its reply, and all after, never come back
  use GenServer

  @modes %{drop: 1, close_reply: 2, hang_reply: 3}

  def start_link(target), do: GenServer.start_link(__MODULE__, target, name: __MODULE__)
  def port, do: GenServer.call(__MODULE__, :port)
  def arm(mode), do: GenServer.call(__MODULE__, {:arm, Map.fetch!(@modes, mode)})

  @impl true
  def init(target) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    armed = :atomics.new(1, [])
    spawn_link(fn -> accept(listen, target, armed) end)
    {:ok, %{port: port, armed: armed}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call({:arm, mode}, _from, state) do
    :atomics.put(state.armed, 1, mode)
    {:reply, :ok, state}
  end

  defp accept(listen, target, armed) do
    {:ok, client} = :gen_tcp.accept(listen)
    {:ok, server} = :gen_tcp.connect(~c"localhost", target, [:binary, active: false])
    conn = :atomics.new(1, [])

    up = spawn(fn -> receive(do: (:go -> up(client, server, armed, conn))) end)
    down = spawn(fn -> receive(do: (:go -> down(server, client, conn))) end)
    :ok = :gen_tcp.controlling_process(client, up)
    :ok = :gen_tcp.controlling_process(server, down)
    send(up, :go)
    send(down, :go)
    accept(listen, target, armed)
  end

  defp up(client, server, armed, conn) do
    case :gen_tcp.recv(client, 0) do
      {:ok, data} ->
        mode = if :binary.match(data, "COMMIT") != :nomatch, do: :atomics.exchange(armed, 1, 0)
        pass_up(mode, data, {client, server, armed, conn})

      {:error, _closed} ->
        :gen_tcp.close(server)
    end
  end

  defp pass_up(1, _data, {client, server, _armed, _conn}) do
    :gen_tcp.close(server)
    :gen_tcp.close(client)
  end

  defp pass_up(mode, data, {client, server, armed, conn}) do
    if mode in [2, 3], do: :atomics.put(conn, 1, mode)
    :gen_tcp.send(server, data)
    up(client, server, armed, conn)
  end

  defp down(server, client, conn) do
    case :gen_tcp.recv(server, 0) do
      {:ok, data} ->
        case :atomics.get(conn, 1) do
          0 ->
            :gen_tcp.send(client, data)
            down(server, client, conn)

          2 ->
            :gen_tcp.close(client)
            :gen_tcp.close(server)

          3 ->
            down(server, client, conn)
        end

      {:error, _closed} ->
        :gen_tcp.close(client)
    end
  end
end

defmodule LostCommitInvoice do
  @moduledoc false
  use Durable
  use Durable.Wait
  alias Durable.IntegrationProbe, as: Probe

  # The invoice is sent, then the run waits to hear it was paid, and books it.
  workflow "lost_commit_invoice" do
    step :await_payment, fn invoice ->
      Probe.note(:invoiced)
      paid = wait_for_event("lost_commit_paid")
      Probe.note(:booking)
      Probe.wait_for(:book)
      {:ok, Map.put(invoice, "paid", paid)}
    end
  end
end

defmodule LostCommitParcel do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  workflow "lost_commit_parcel" do
    step :weigh, fn parcel ->
      Probe.note(:weighed)
      {:ok, parcel}
    end
  end
end

defmodule Durable.Integration.LostCommitTest do
  use Durable.IntegrationCase, async: false

  alias Durable.Queue.Manager

  @moduletag :capture_log

  # Node A: its own repo, through the proxy.
  defp start_node_a!(repo_opts, durable_opts) do
    db = Application.fetch_env!(:durable, IntegrationRepo)
    start_supervised!({LostCommitProxy, db[:port]})

    config =
      db
      |> Keyword.merge(hostname: "localhost", port: LostCommitProxy.port())
      |> Keyword.merge(telemetry_prefix: [:lost_commit, :repo])
      |> Keyword.merge(repo_opts)

    Application.put_env(:durable, LostCommitRepo, config)
    start_supervised!(LostCommitRepo)

    Durable.DataCase.start_supervised_durable!(
      [repo: LostCommitRepo, queues: queue_opts(%{default: 1})] ++ durable_opts
    )
  end

  # Arms the proxy once node A's step has written its wait's event, inside
  # the wait's transaction: the next COMMIT is the wait's.
  def arm_at_wait(_event, _measurements, %{source: "pending_events", query: "INSERT" <> _}, mode) do
    unless Probe.set?(:armed) do
      Probe.set(:armed)
      LostCommitProxy.arm(mode)
    end
  end

  def arm_at_wait(_event, _measurements, _meta, _mode), do: :ok

  defp arm_at_wait!(mode) do
    handler = "lost_commit-wait-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler, [:lost_commit, :repo, :query], &__MODULE__.arm_at_wait/4, mode)
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp steps(id) do
    IntegrationRepo.all(
      from(s in StepExecution, where: s.workflow_id == ^id, order_by: s.inserted_at)
    )
  end

  defp worker_lost(id) do
    IntegrationRepo.aggregate(
      from(a in Durable.Storage.Schemas.ActivityEvent,
        where: a.kind == "worker_lost" and a.workflow_id == ^id
      ),
      :count
    )
  end

  describe "a wait whose COMMIT lands and whose reply is lost" do
    # The run is waiting, its wait is there: nothing was lost.
    test "leaves the run's wait and its attempt as they are" do
      arm_at_wait!(:close_reply)
      start_node_a!([], [])

      {:ok, id} = Durable.start(LostCommitInvoice, %{"invoice" => 1})
      assert_eventually(fn -> Probe.set?(:armed) end)
      assert_eventually(fn -> Manager.status(Durable, :default).active_jobs == 0 end, 5_000)

      assert get(id).status == :waiting
      assert [%{status: :waiting, error: nil}] = steps(id)
      assert worker_lost(id) == 0

      Probe.set(:book)
      :ok = Durable.send_event(id, "lost_commit_paid", %{"amount" => 1})
      await_status(id, :completed)
    end

    # The reply never comes, and the node's query times out. Meanwhile the
    # payment arrives and node B runs the step on: node A, giving up on the
    # wait, closed node B's attempt as its own lost worker's. Node B's step
    # then found its row closed and stopped, and the run stayed running, its
    # lock B's, until the stale sweep.
    test "doesn't close the attempt another node runs once the wait is answered" do
      arm_at_wait!(:hang_reply)
      # The defaults' order: its query gives up (15 s) before its heartbeat
      # would hear of node B's claim (30 s).
      start_node_a!([timeout: 3_000], heartbeat_interval: 30_000)

      {:ok, id} = Durable.start(LostCommitInvoice, %{"invoice" => 1})
      assert_eventually(fn -> Probe.set?(:armed) and get(id).status == :waiting end, 5_000)

      Durable.DataCase.start_supervised_durable!(
        name: :lost_commit_b,
        repo: IntegrationRepo,
        queues: queue_opts(%{default: 1})
      )

      :ok =
        Durable.send_event(id, "lost_commit_paid", %{"amount" => 1}, durable: :lost_commit_b)

      assert_eventually(fn -> Probe.hits(:booking) == 1 end, 3_000)

      # Node A gives up on its COMMIT.
      assert_eventually(fn -> Manager.status(Durable, :default).active_jobs == 0 end, 10_000)
      Probe.set(:book)
      assert_eventually(fn -> Manager.status(:lost_commit_b, :default).active_jobs == 0 end)

      rows = Enum.map(steps(id), &{&1.status, &1.error["type"]})
      assert {get(id).status, rows} == {:completed, [{:waiting, nil}, {:completed, nil}]}
    end
  end

  def note_attempt([:durable, :step, phase], _measurements, meta, test) do
    send(test, {:attempt, if(phase == :start, do: :start, else: :end), meta.step_execution_id})
  end

  # The step's task loses its connection as its attempt's row commits: the
  # COMMIT never reaches the database, the start event is out.
  def drop_commit(_event, _measurements, _meta, _config) do
    unless Probe.set?(:armed) do
      Probe.set(:armed)
      LostCommitProxy.arm(:drop)
    end
  end

  defp attempt_events do
    receive do
      {:attempt, kind, id} -> [{kind, id} | attempt_events()]
    after
      0 -> []
    end
  end

  describe "an attempt whose connection drops before its row commits" do
    # Nothing is killed: the task raises, its worker sends the run back.
    test "has an end for its start" do
      test = self()
      handler = "lost_commit-attempts-#{System.unique_integer([:positive])}"
      phases = for phase <- [:start, :stop, :exception], do: [:durable, :step, phase]
      :telemetry.attach_many(handler, phases, &__MODULE__.note_attempt/4, test)

      :telemetry.attach(
        "#{handler}-drop",
        [:durable, :step, :start],
        &__MODULE__.drop_commit/4,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(handler)
        :telemetry.detach("#{handler}-drop")
      end)

      start_node_a!([], [])
      {:ok, id} = Durable.start(LostCommitParcel, %{"parcel" => 1})
      await_status(id, :completed)
      Process.sleep(200)

      events = attempt_events()
      started = for {:start, attempt} <- events, do: attempt
      ended = for {:end, attempt} <- events, do: attempt

      assert length(started) == 2
      assert {started -- ended, ended -- started} == {[], []}
    end
  end

  def hold_start(_event, _measurements, _meta, test) do
    send(test, {:task, self()})
    Probe.wait_for(:never)
  end

  describe "a task killed inside its attempt's open transaction" do
    # Its transaction holds the run's row: attempt_died's barrier waits only
    # until the dead task's connection is dropped.
    test "is put back at once, nothing left running" do
      handler = "lost_commit-hold-#{System.unique_integer([:positive])}"
      :telemetry.attach(handler, [:durable, :step, :start], &__MODULE__.hold_start/4, self())
      on_exit(fn -> :telemetry.detach(handler) end)
      start_durable!(%{default: 1}, heartbeat_interval: 30_000)

      {:ok, id} = Durable.start(LostCommitParcel, %{"parcel" => 1})
      assert_receive {:task, task}, 5_000
      :ok = Durable.pause_queue(:default)
      at = System.monotonic_time(:millisecond)
      Process.exit(task, :kill)

      assert_eventually(fn -> get(id).status == :pending end, 2_000)
      assert System.monotonic_time(:millisecond) - at < 2_000

      running = from(s in StepExecution, where: s.workflow_id == ^id and s.status == :running)
      assert IntegrationRepo.all(running) == []
    end
  end
end
