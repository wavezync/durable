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
