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

defmodule Durable.Integration.Audit6QueueTest do
  @moduledoc """
  Audit 6: the queue and recovery under load. Workers that can't reach the
  database, nodes that stop, and sweeps on many nodes.
  """
  use Durable.IntegrationCase, async: false

  alias Durable.Queue.StaleJobRecovery

  @moduletag :capture_log

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
