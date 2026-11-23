defmodule Audit5QueueRestock do
  @moduledoc false
  use Durable

  # Out of stock: tries again in a minute, without using an attempt.
  workflow "audit5_queue_restock" do
    step :reserve_stock, fn _order -> {:snooze, 60_000} end
  end
end

defmodule Durable.Audit5QueueTest do
  @moduledoc "Audit 5: what a worker's heartbeat makes of a claim it no longer has."
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Queue.Adapters.Postgres
  alias Durable.Storage.Schemas.WorkflowExecution

  defp claim!(input) do
    config = Config.get(Durable)
    {:ok, id} = Durable.start(Audit5QueueRestock, input)
    [job] = Postgres.fetch_jobs(config, "default", 1, "node-a")
    {config, id, job.lock_token}
  end

  describe "a heartbeat" do
    # Seen as nothing to refresh, the step ran on, holding its worker's slot.
    test "from a worker whose claim the stale sweep released stops the step" do
      {config, id, token} = claim!(%{"order" => 7})

      {1, _} =
        Durable.TestRepo.update_all(
          from(w in WorkflowExecution, where: w.id == ^id),
          set: [locked_at: DateTime.add(DateTime.utc_now(), -3_600, :second)]
        )

      {:ok, 1} = Postgres.recover_stale_locks(config, 300)

      assert Postgres.heartbeat(config, id, token) == {:error, :fenced}
    end

    test "from a worker whose own run just parked doesn't stop it" do
      {config, id, token} = claim!(%{"order" => 8})

      assert {:waiting, %{status: :pending}} = Executor.execute_workflow(id, config, token)
      assert Postgres.heartbeat(config, id, token) == {:error, :not_found}
    end
  end

  describe "a node with no queues of its own" do
    # A node that only starts runs and keeps time, its sweeps on.
    @tag :supervised
    test "drains, and stops, without raising" do
      Durable.DataCase.start_supervised_durable!(queues: %{}, shutdown_grace_period: 100)

      assert Durable.drain() == :ok

      log = ExUnit.CaptureLog.capture_log(fn -> stop_supervised!(Durable) end)
      refute log =~ "max_concurrency"
    end
  end
end
