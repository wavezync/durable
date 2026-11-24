defmodule Audit6QueueRepo do
  @moduledoc false
  # A repo of the node's own, so a test can cut that node off from the database.
  use Ecto.Repo, otp_app: :durable, adapter: Ecto.Adapters.Postgres
end

defmodule Audit6QueueExport do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  # Streams a report to a customer's bucket for as long as it takes. It never
  # touches Durable's database while it runs.
  workflow "audit6_queue_export" do
    step :upload_report, fn report ->
      Probe.inside([:uploading], fn ->
        Probe.note(:upload_started)
        Probe.wait_for(:upload_done)
      end)

      {:ok, report}
    end
  end
end

defmodule Audit6QueueReport do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  # A report built by one long query, on the node's own repo.
  workflow "audit6_queue_report" do
    step :build_report, fn report ->
      Probe.note(:building)
      Audit6QueueRepo.query!("SELECT pg_sleep(3)", [], timeout: 10_000)
      {:ok, report}
    end
  end
end

defmodule Audit6QueueReceipt do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  workflow "audit6_queue_receipt" do
    step :email_receipt, fn order ->
      Probe.note({:receipt, order["n"]})
      {:ok, order}
    end
  end
end

defmodule Audit6QueueTrip do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  # The seat is released only once nothing can still charge for it.
  workflow "audit6_queue_trip" do
    step :hold_seat, [compensate: :release_seat], fn trip -> {:ok, trip} end

    step :charge_card, fn trip ->
      Probe.inside([:seat_and_card], fn ->
        Probe.note(:charging)
        Probe.wait_for(:gateway_answered)
        Probe.note(:charged)
      end)

      {:ok, trip}
    end

    compensate :release_seat, fn trip ->
      Probe.inside([:seat_and_card], fn -> Probe.note(:released) end)
      {:ok, trip}
    end
  end
end

defmodule Audit6QueueSync do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  # One sync of an account at a time. An edit while one runs syncs again after
  # it, with the newest edit.
  workflow "audit6_queue_sync", on_duplicate: :run_again do
    step :sync, fn account ->
      Probe.inside([:sync], fn ->
        Probe.note({:syncing, account["rev"]})
        if account["slow"], do: Probe.wait_for(:sync_done)
      end)

      {:ok, account}
    end
  end
end

defmodule Audit6QueueCheckout do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  # The stock is released only once nothing can still charge the card.
  workflow "audit6_queue_checkout" do
    step :reserve_stock, [compensate: :release_stock], fn order -> {:ok, order} end

    parallel :pay do
      step :charge_card, fn order ->
        Probe.inside([:stock_and_card], fn ->
          Probe.note(:charging)
          Probe.wait_for(:gateway_answered)
        end)

        {:ok, order}
      end

      step :email_receipt, fn order -> {:ok, order} end
    end

    compensate :release_stock, fn order ->
      Probe.inside([:stock_and_card], fn -> Probe.note(:released) end)
      {:ok, order}
    end
  end
end

defmodule Audit6QueuePayment do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  # The card is charged on its queue while the fraud check runs on its own. An
  # order flagged once is cleared on review.
  workflow "audit6_queue_payment" do
    step :reserve_stock, [compensate: :release_stock], fn order -> {:ok, order} end

    parallel :pay do
      step :charge_card, [queue: :cards], fn order ->
        Probe.inside([:card], fn ->
          Probe.note(:charging)
          Probe.wait_for(:gateway_answered)
        end)

        {:ok, order}
      end

      step :check_fraud, [queue: :fraud], fn order ->
        if Probe.hits(:flagged) == 0 do
          Probe.note(:flagged)
          {:error, "flagged for review"}
        else
          {:ok, order}
        end
      end
    end

    compensate :release_stock, fn order ->
      Probe.inside([:card], fn -> Probe.note(:released) end)
      {:ok, order}
    end
  end
end

defmodule Audit6QueueProxy do
  @moduledoc false
  # A TCP proxy in front of Postgres that can stop passing bytes without
  # closing anything: to the node behind it, a network that drops its packets.
  # Queries then hang, where a stopped repo refuses them at once.
  use GenServer

  def start_link(target), do: GenServer.start_link(__MODULE__, target, name: __MODULE__)
  def port, do: GenServer.call(__MODULE__, :port)
  def freeze, do: GenServer.call(__MODULE__, :freeze)

  @impl true
  def init(target) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    frozen = :atomics.new(1, [])
    spawn_link(fn -> accept(listen, target, frozen) end)
    {:ok, %{port: port, frozen: frozen}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call(:freeze, _from, state) do
    :atomics.put(state.frozen, 1, 1)
    {:reply, :ok, state}
  end

  defp accept(listen, target, frozen) do
    {:ok, client} = :gen_tcp.accept(listen)
    {:ok, server} = :gen_tcp.connect(~c"localhost", target, [:binary, active: false])

    for {from, to} <- [{client, server}, {server, client}] do
      pid = spawn(fn -> receive(do: (:go -> pipe(from, to, frozen))) end)
      :ok = :gen_tcp.controlling_process(from, pid)
      send(pid, :go)
    end

    accept(listen, target, frozen)
  end

  defp pipe(from, to, frozen) do
    case :gen_tcp.recv(from, 0) do
      {:ok, data} ->
        if :atomics.get(frozen, 1) == 0, do: :gen_tcp.send(to, data)
        pipe(from, to, frozen)

      {:error, _closed} ->
        :gen_tcp.close(to)
    end
  end
end

defmodule Durable.Integration.Audit6QueueTest do
  @moduledoc """
  Audit 6: the queue and recovery under load. Workers that can't reach the
  database, nodes that stop, and sweeps on many nodes.
  """
  use Durable.IntegrationCase, async: false

  alias Durable.Queue.StaleJobRecovery

  @moduletag :capture_log

  # A node on a repo of its own: stopping it is the node losing the database,
  # and a small pool is one its steps can fill.
  defp start_on_own_repo!(repo_opts, durable_opts) do
    config = Keyword.merge(Application.fetch_env!(:durable, IntegrationRepo), repo_opts)
    Application.put_env(:durable, Audit6QueueRepo, config)
    start_supervised!(Audit6QueueRepo)

    Durable.DataCase.start_supervised_durable!(
      Keyword.merge([repo: Audit6QueueRepo, queues: queue_opts(%{default: 2})], durable_opts)
    )
  end

  # Node B: a second instance, on the real repo.
  defp start_node_b!(durable_opts) do
    Durable.DataCase.start_supervised_durable!(
      Keyword.merge(
        [name: :audit6_node_b, repo: IntegrationRepo, queues: queue_opts(%{default: 1})],
        durable_opts
      )
    )
  end

  describe "a node that stops while its steps hold every connection of its pool" do
    test "still hands its runs back" do
      start_on_own_repo!([pool_size: 2], [])

      ids = for n <- 1..2, do: elem(Durable.start(Audit6QueueReport, %{"n" => n}), 1)
      assert_eventually(fn -> Probe.hits(:building) == 2 end)

      stop_supervised!(Durable)

      for id <- ids do
        assert %{status: :pending, locked_by: nil} = get(id)
      end
    end
  end

  describe "a run cancelled with rollback: true whose worker can't reach the database" do
    # The undo waits one heartbeat for the worker to hear of the cancel. A
    # worker whose heartbeats fail never hears, and its step goes on.
    test "isn't undone while its step can still finish" do
      start_on_own_repo!([], [])

      {:ok, id} = Durable.start(Audit6QueueTrip, %{"seat" => "12A"})
      assert_eventually(fn -> Probe.hits(:charging) == 1 end)
      stop_supervised!(Audit6QueueRepo)

      Durable.DataCase.start_supervised_durable!(
        name: :audit6_node_b,
        repo: IntegrationRepo,
        queues: queue_opts(%{default: 1})
      )

      :ok = Durable.cancel(id, "traveller walked away", rollback: true, durable: :audit6_node_b)
      Process.sleep(1_000)

      # The seat is released while the card is still being charged.
      assert Probe.peak(:seat_and_card) == 1
    end
  end

  describe "a claim that takes a run 2.0 wrote with a bare value for its input" do
    # 2.0 stored a child's date or decimal input as it was, not in a map. The
    # schema reads such a row (`JsonMap.load/1`); the claim has to as well.
    test "still starts the runs claimed with it" do
      start_durable!(%{default: 4})
      :ok = Durable.pause_queue(:default)

      {:ok, legacy} = Durable.start(Audit6QueueExport, %{"customer" => "c-1"})

      # Set by hand: no writer today stores a bare value.
      IntegrationRepo.query!(
        "UPDATE durable.workflow_executions SET input = '\"2026-11-23\"'::jsonb WHERE id = $1",
        [Ecto.UUID.dump!(legacy)]
      )

      ids = for n <- 1..3, do: elem(Durable.start(Audit6QueueReceipt, %{"n" => n}), 1)
      :ok = Durable.resume_queue(:default)

      for id <- ids, do: await_status(id, :completed)
      :ok = Probe.set(:upload_done)
      assert await_status(legacy, :completed).input == %{"value" => "2026-11-23"}
    end
  end

  describe "a run started inline on a node that stops past its grace period" do
    # Its caller isn't one of the node's workers: nothing stops it, and the
    # hand-back can't tell its claim from theirs.
    test "isn't handed to another node while its caller still runs the step" do
      start_durable!(%{default: 1})

      # A worker still busy at the stop, so the node hands back what it has.
      {:ok, _trip} = Durable.start(Audit6QueueTrip, %{"seat" => "3C"})
      assert_eventually(fn -> Probe.hits(:charging) == 1 end)

      spawn(fn -> Durable.start(Audit6QueueExport, %{}, inline: true, queue: :reports) end)
      assert_eventually(fn -> Probe.hits(:upload_started) == 1 end)

      stop_supervised!(Durable)

      Durable.DataCase.start_supervised_durable!(
        name: :audit6_node_b,
        repo: IntegrationRepo,
        queues: queue_opts(%{reports: 1})
      )

      Process.sleep(500)

      # The caller's upload is the only one.
      assert Probe.hits(:upload_started) == 1
      assert Probe.peak(:uploading) == 1
    end
  end

  describe "a worker cut off from the database" do
    # Node A runs on a repo of its own; stopping it is A losing the database
    # while its step goes on. Node B is a second instance on the real repo.
    test "stops its step before its claim goes stale and another node runs it" do
      Application.put_env(
        :durable,
        Audit6QueueRepo,
        Application.fetch_env!(:durable, IntegrationRepo)
      )

      start_supervised!(Audit6QueueRepo)

      Durable.DataCase.start_supervised_durable!(
        repo: Audit6QueueRepo,
        queues: queue_opts(%{default: 1}),
        stale_lock_timeout: 1
      )

      {:ok, id} = Durable.start(Audit6QueueExport, %{"customer" => "c-42"})
      assert_eventually(fn -> Probe.hits(:upload_started) == 1 end)

      # A's heartbeats fail from now on; its lock goes stale after a second.
      stop_supervised!(Audit6QueueRepo)
      Process.sleep(1_500)

      Durable.DataCase.start_supervised_durable!(
        name: :audit6_node_b,
        repo: IntegrationRepo,
        queues: queue_opts(%{default: 1}),
        stale_lock_timeout: 1
      )

      {:ok, 1} = StaleJobRecovery.recover_now(:audit6_node_b)
      assert_eventually(fn -> Probe.hits(:upload_started) == 2 end)
      Process.sleep(300)

      # B's upload is the only one: A's stopped when it lost its claim.
      assert Probe.peak(:uploading) == 1

      :ok = Probe.set(:upload_done)
      await_status(id, :completed)
    end
  end

  describe "a worker whose database stops answering mid-step" do
    # Its heartbeat hangs, where a stopped repo refuses it at once. Hung for
    # the query's timeout, it couldn't stop the step before its claim went
    # stale and another node ran it.
    test "stops its step before its claim goes stale and another node runs it" do
      db = Application.fetch_env!(:durable, IntegrationRepo)
      start_supervised!({Audit6QueueProxy, db[:port]})
      timing = [stale_lock_timeout: 2, heartbeat_interval: 200]
      start_on_own_repo!([hostname: "localhost", port: Audit6QueueProxy.port()], timing)

      {:ok, id} = Durable.start(Audit6QueueExport, %{"customer" => "c-7"})
      assert_eventually(fn -> Probe.hits(:upload_started) == 1 end)
      :ok = Audit6QueueProxy.freeze()

      start_node_b!(timing)
      Process.sleep(2_200)
      {:ok, 1} = StaleJobRecovery.recover_now(:audit6_node_b)
      assert_eventually(fn -> Probe.hits(:upload_started) == 2 end)
      Process.sleep(300)

      assert Probe.peak(:uploading) == 1

      :ok = Probe.set(:upload_done)
      await_status(id, :completed)
    end
  end

  # A cancel lets a worker running the run keep its lock. Until the worker has
  # stopped its step and let go, or the lock is stale, nothing else of the
  # key runs, nor an undo of the run's tree. They waited a heartbeat for the
  # worker to hear of the cancel; one whose heartbeats fail never hears, and
  # stops its step only before its lock goes stale.
  describe "a run cancelled while a worker that can't reach the database runs its step" do
    @timing [stale_lock_timeout: 2, heartbeat_interval: 200]

    defp cut_off_mid_step!(start, probe, queues \\ {%{default: 2}, %{default: 1}}) do
      {on_a, on_b} = queues
      start_on_own_repo!([], [queues: queue_opts(on_a)] ++ @timing)
      id = start.()
      assert_eventually(fn -> Probe.hits(probe) == 1 end)
      stop_supervised!(Audit6QueueRepo)
      start_node_b!([queues: queue_opts(on_b)] ++ @timing)
      id
    end

    # The card is charged on node A, which is then cut off. The fraud check,
    # on node B, fails the block, which stops the charge.
    defp flagged_mid_charge! do
      order =
        cut_off_mid_step!(
          fn -> elem(Durable.start(Audit6QueuePayment, %{"sku" => "mug"}), 1) end,
          :charging,
          {%{default: 1, cards: 1}, %{default: 1, cards: 1, fraud: 1}}
        )

      await_status(order, :failed)
      order
    end

    defp sync(rev, opts) do
      input = %{"rev" => rev, "slow" => Keyword.get(opts, :slow, false)}
      opts = [key: "acct:5"] ++ Keyword.delete(opts, :slow)
      elem(Durable.start(Audit6QueueSync, input, opts), 1)
    end

    test "keeps the run waiting behind it on the key until that step has stopped" do
      holder = cut_off_mid_step!(fn -> sync(1, slow: true) end, {:syncing, 1})
      waiter = sync(2, durable: :audit6_node_b)

      :ok = Durable.cancel(holder, "superseded by an edit", durable: :audit6_node_b)
      await_status(waiter, :completed, 10_000)

      assert Probe.peak(:sync) == 1
    end

    test "keeps the key's next start from running until that step has stopped" do
      holder = cut_off_mid_step!(fn -> sync(1, slow: true) end, {:syncing, 1})

      :ok = Durable.cancel(holder, "wrong account", durable: :audit6_node_b)
      next = sync(2, durable: :audit6_node_b)
      assert next != holder
      await_status(next, :completed, 10_000)

      assert Probe.peak(:sync) == 1
    end

    test "doesn't undo the run it's under while that step can still finish" do
      order =
        cut_off_mid_step!(
          fn -> elem(Durable.start(Audit6QueueCheckout, %{"sku" => "mug"}), 1) end,
          :charging
        )

      :ok = Durable.cancel(order, "customer cancelled", rollback: true, durable: :audit6_node_b)
      assert_eventually(fn -> Probe.hits(:released) == 1 end, 10_000)

      # The stock is released while the card is still being charged.
      assert Probe.peak(:stock_and_card) == 1
    end

    test "doesn't undo a run whose block stopped that step while it can still finish" do
      order = flagged_mid_charge!()

      {:ok, _} = Durable.rollback(order, durable: :audit6_node_b)
      assert_eventually(fn -> Probe.hits(:released) == 1 end, 10_000)

      assert Probe.peak(:card) == 1
    end

    test "doesn't run that step again, when its block is retried, while it can still finish" do
      order = flagged_mid_charge!()

      {:ok, _} = Durable.retry(order, durable: :audit6_node_b)
      assert_eventually(fn -> Probe.hits(:charging) == 2 end, 10_000)
      assert Probe.peak(:card) == 1

      :ok = Probe.set(:gateway_answered)
      await_status(order, :completed)
    end
  end
end
