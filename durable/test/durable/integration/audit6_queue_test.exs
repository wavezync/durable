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
      [repo: Audit6QueueRepo, queues: queue_opts(%{default: 2})] ++ durable_opts
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
end
