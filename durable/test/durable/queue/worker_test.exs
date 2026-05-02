defmodule Durable.Queue.WorkerTest do
  @moduledoc """
  Drives the real `Durable.Queue.Worker` GenServer end-to-end.

  Until now, the worker process was untested — `Durable.DataCase` starts
  Durable with `queue_enabled: false`, so the Poller / DynamicSupervisor /
  Worker chain never ran in CI. This file fills that gap by starting Durable
  with `queue_enabled: true` and observing real Worker lifecycles via
  telemetry, the sink workflow's test-pid messages, and DB state.

  All tests are `async: false` (mandatory — they stand up a global Durable
  supervisor with the default `Durable` name and rely on shared sandbox mode).
  """

  use Durable.DataCase, async: false

  @moduletag :supervised

  import Durable.DataCase,
    only: [pid_to_bin: 0, with_backoff: 1, with_backoff: 2]

  alias Durable.Config
  alias Durable.Queue.StaleJobRecovery
  alias Durable.Storage.Schemas.WorkflowExecution
  alias Durable.TelemetryHandler
  alias Durable.TestWorkflows.SinkWorkflow

  setup do
    Durable.DataCase.start_supervised_durable!(stale_lock_timeout: 1)
    TelemetryHandler.attach_events()
    :ok
  end

  describe "happy path" do
    test "Worker executes an OK job, emits :job_completed telemetry, and acks" do
      ref = "ok-#{System.unique_integer([:positive])}"
      input = %{"action" => "OK", "ref" => ref, "bin_pid" => pid_to_bin()}

      {:ok, wf_id} = Durable.start(SinkWorkflow, input)

      # The sink workflow's :run step sends {:done, ref} on success.
      assert_receive {:done, ^ref}, 2_000

      # Worker emitted job_completed telemetry with status=:completed.
      assert_receive {:event, :job_completed, %{duration_ms: dur},
                      %{status: :completed, job_id: ^wf_id}},
                     2_000

      assert dur >= 0

      # Persisted row reflects success and the lock is cleared.
      with_backoff(fn ->
        config = Config.get(Durable)
        exec = config.repo.get!(WorkflowExecution, wf_id)
        assert exec.status == :completed
        assert exec.locked_by == nil
        assert exec.locked_at == nil
      end)
    end
  end

  describe "step error path through the Worker" do
    @tag :capture_log
    test "RAISE inside the step → executor marks :failed → Worker emits status=:failed" do
      ref = "raise-#{System.unique_integer([:positive])}"
      input = %{"action" => "RAISE", "ref" => ref, "bin_pid" => pid_to_bin()}

      {:ok, wf_id} = Durable.start(SinkWorkflow, input)

      assert_receive {:event, :job_completed, _measure, %{status: :failed, job_id: ^wf_id}},
                     2_000

      with_backoff(fn ->
        config = Config.get(Durable)
        exec = config.repo.get!(WorkflowExecution, wf_id)
        assert exec.status == :failed
        assert exec.error["type"] == "RuntimeError"
        assert is_binary(exec.error["message"])
        assert exec.locked_by == nil
        assert exec.locked_at == nil
      end)
    end
  end

  describe "worker killed mid-step" do
    @tag :capture_log
    test "external kill leaves the lock, StaleJobRecovery rescues the row" do
      ref = "stale-#{System.unique_integer([:positive])}"

      # Long enough sleep to give us time to find and kill the worker before
      # the task finishes naturally.
      input = %{
        "action" => "SLEEP",
        "ref" => ref,
        "bin_pid" => pid_to_bin(),
        "sleep_ms" => 10_000
      }

      {:ok, wf_id} = Durable.start(SinkWorkflow, input)

      # Wait for the step to actually start.
      assert_receive {:started, ^ref}, 2_000

      worker_pid =
        with_backoff([total: 50, sleep: 10], fn ->
          pid = Durable.DataCase.get_worker_pid(Durable, "default", wf_id)
          assert is_pid(pid), "expected to find a Worker pid for job #{wf_id}"
          pid
        end)

      # Capture the locked_at before we kill — used to assert it doesn't change
      # after the kill (no further heartbeats land).
      config = Config.get(Durable)
      exec_before = config.repo.get!(WorkflowExecution, wf_id)
      assert exec_before.status == :running
      assert exec_before.locked_by != nil
      locked_at_before = exec_before.locked_at

      Process.exit(worker_pid, :kill)

      # The worker death never sends {:done, _}.
      refute_receive {:done, ^ref}, 200

      # Row remains :running with the same (or older) locked_at — recovery
      # hasn't run yet.
      exec_during = config.repo.get!(WorkflowExecution, wf_id)
      assert exec_during.status == :running
      assert DateTime.compare(exec_during.locked_at, locked_at_before) != :gt

      # Wait long enough for the lock to be considered stale (we set
      # stale_lock_timeout: 1 in the setup, in seconds). Plus margin so the
      # row's last-heartbeat `locked_at` is comfortably past the cutoff
      # before recover_now runs.
      Process.sleep(2_100)

      assert {:ok, count} = StaleJobRecovery.recover_now(Durable)
      assert count >= 1

      # Stale recovery telemetry fired.
      assert_receive {:event, :stale_recovered, %{count: c}, _meta} when c >= 1, 500

      # Row back to :pending, lock cleared. Use a generous backoff window —
      # if the previous recover_now didn't reach our row (e.g. a prior test
      # left a stale row that won the race), the test should re-trigger
      # rather than flake.
      with_backoff([total: 200, sleep: 25], fn ->
        case config.repo.get!(WorkflowExecution, wf_id) do
          %{status: :pending} = exec ->
            assert exec.locked_by == nil
            assert exec.locked_at == nil

          other ->
            # Re-trigger recovery in case our row didn't make the first sweep.
            _ = StaleJobRecovery.recover_now(Durable)
            flunk("expected :pending, got #{inspect(other.status)}")
        end
      end)
    end
  end
end
