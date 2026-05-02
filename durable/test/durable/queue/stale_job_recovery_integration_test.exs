defmodule Durable.Queue.StaleJobRecoveryIntegrationTest do
  @moduledoc """
  Drives the live `Durable.Queue.StaleJobRecovery` GenServer (not the adapter
  function in isolation — that path is covered by
  `test/durable/queue/adapters/postgres_test.exs`).

  These tests exist to verify the wiring around the recovery sweep:
  - `recover_now/1` triggers a synchronous run while the GenServer is alive
  - Telemetry fires with the right counts
  - Both stale-lock recovery AND zombie detection happen on a single tick
  - Recently-locked / healthy rows are left alone

  All `async: false` — we rely on a globally-named supervised Durable instance
  under the shared sandbox.
  """

  use Durable.DataCase, async: false

  @moduletag :supervised

  alias Durable.Config
  alias Durable.Queue.StaleJobRecovery
  alias Durable.Storage.Schemas.{PendingEvent, WorkflowExecution}
  alias Durable.TelemetryHandler

  setup do
    # `stale_lock_timeout: 1` (seconds) lets us age a row past the cutoff in
    # ~1.1s of sleep without dragging the suite.
    Durable.DataCase.start_supervised_durable!(stale_lock_timeout: 1)
    TelemetryHandler.attach_events()
    :ok
  end

  describe "stale-lock recovery via recover_now/1" do
    test "rescues a row with a stale lock and emits :stale_recovered telemetry" do
      config = Config.get(Durable)
      repo = config.repo

      # Stale: locked 10s ago.
      stale =
        insert_execution(repo,
          workflow_name: "stale_one",
          status: :running,
          locked_by: "dead_node",
          locked_at: DateTime.add(DateTime.utc_now(), -10, :second)
        )

      # Healthy: locked just now. Should be left alone.
      healthy =
        insert_execution(repo,
          workflow_name: "healthy_one",
          status: :running,
          locked_by: "live_node",
          locked_at: DateTime.utc_now()
        )

      assert {:ok, count} = StaleJobRecovery.recover_now(Durable)
      assert count >= 1

      assert_receive {:event, :stale_recovered, %{count: ^count}, %{durable: Durable}}, 500

      # Stale row reset.
      stale_after = repo.get!(WorkflowExecution, stale.id)
      assert stale_after.status == :pending
      assert stale_after.locked_by == nil
      assert stale_after.locked_at == nil

      # Healthy row untouched.
      healthy_after = repo.get!(WorkflowExecution, healthy.id)
      assert healthy_after.status == :running
      assert healthy_after.locked_by == "live_node"
    end

    test "no stale rows → no :stale_recovered telemetry" do
      assert {:ok, 0} = StaleJobRecovery.recover_now(Durable)
      refute_receive {:event, :stale_recovered, _, _}, 100
    end
  end

  describe "zombie detection via recover_now/1" do
    test "marks :waiting workflows with no pending events/inputs as :failed and emits :zombie_recovered" do
      config = Config.get(Durable)
      repo = config.repo

      # Insert a :waiting row, then backdate updated_at past the stale cutoff.
      zombie =
        insert_execution(repo,
          workflow_name: "zombie_one",
          status: :waiting,
          locked_by: nil,
          locked_at: nil
        )

      long_ago = DateTime.add(DateTime.utc_now(), -3600, :second)

      {1, _} =
        repo.update_all(
          Ecto.Query.from(w in WorkflowExecution, where: w.id == ^zombie.id),
          set: [updated_at: long_ago]
        )

      # Healthy waiter: same shape but with a pending event keeping it alive.
      healthy_waiter =
        insert_execution(repo,
          workflow_name: "healthy_waiter",
          status: :waiting,
          locked_by: nil,
          locked_at: nil
        )

      {1, _} =
        repo.update_all(
          Ecto.Query.from(w in WorkflowExecution, where: w.id == ^healthy_waiter.id),
          set: [updated_at: long_ago]
        )

      {:ok, _} =
        %PendingEvent{}
        |> PendingEvent.changeset(%{
          workflow_id: healthy_waiter.id,
          event_name: "alive",
          step_name: "await",
          status: :pending
        })
        |> repo.insert()

      assert {:ok, _stale_count} = StaleJobRecovery.recover_now(Durable)

      assert_receive {:event, :zombie_recovered, %{count: zc}, %{durable: Durable}}
                     when zc >= 1,
                     500

      zombie_after = repo.get!(WorkflowExecution, zombie.id)
      assert zombie_after.status == :failed
      assert zombie_after.error["type"] == "zombie_detected"

      healthy_after = repo.get!(WorkflowExecution, healthy_waiter.id)
      assert healthy_after.status == :waiting
    end
  end

  describe "background tick" do
    test "GenServer survives an empty sweep (smoke test that the live process is healthy)" do
      pid = Process.whereis(Durable.Queue.StaleJobRecovery)
      assert is_pid(pid)
      assert Process.alive?(pid)

      # Run a sweep, then a fence call to confirm the GenServer is still
      # responsive and didn't crash.
      assert {:ok, 0} = StaleJobRecovery.recover_now(Durable)
      assert :sys.get_state(pid).config.name == Durable
    end
  end

  defp insert_execution(repo, opts) do
    attrs = %{
      workflow_module: "TestWorkflow",
      workflow_name: Keyword.get(opts, :workflow_name, "test"),
      status: Keyword.get(opts, :status, :pending),
      queue: "default",
      priority: 0,
      input: %{},
      context: %{},
      locked_by: Keyword.get(opts, :locked_by),
      locked_at: Keyword.get(opts, :locked_at)
    }

    %WorkflowExecution{}
    |> WorkflowExecution.changeset(attrs)
    |> repo.insert!()
  end
end
