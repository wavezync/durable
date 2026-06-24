defmodule Durable.Wait.TimeoutWorkerIntegrationTest do
  @moduledoc """
  End-to-end coverage for `Durable.Wait.TimeoutWorker` driving a real workflow
  through the timeout → resume path. Closes the TODO at
  `test/durable/wait_test.exs:568` ("would require queue_enabled: true").

  The TimeoutWorker only exposes `check_timeouts/1` as a `cast`. We use
  `:sys.get_state/1` as a synchronization fence: the OTP message queue
  serializes the trailing `call` behind any pending `cast`, so when
  `:sys.get_state` returns, the cast has been fully processed.
  """

  use Durable.DataCase, async: false

  @moduletag :supervised

  import Durable.DataCase, only: [pid_to_bin: 0, with_backoff: 1, with_backoff: 2]

  alias Durable.Config
  alias Durable.Storage.Schemas.{PendingEvent, WorkflowExecution}
  alias Durable.TestWorkflows.SinkWorkflow
  alias Durable.Wait.TimeoutWorker

  setup do
    Durable.DataCase.start_supervised_durable!()
    :ok
  end

  describe "PendingEvent timeout → resume" do
    test "workflow waiting on an event past its timeout_at resumes with the timeout_value" do
      ref = "tmo-#{System.unique_integer([:positive])}"

      input = %{
        "action" => "WAIT_EVENT",
        "ref" => ref,
        "bin_pid" => pid_to_bin(),
        "event_name" => "evt_#{ref}",
        "timeout_ms" => 100,
        "timeout_value" => %{"timed_out" => true, "ref" => ref}
      }

      {:ok, wf_id} = Durable.start(SinkWorkflow, input)

      # Step started — workflow is in :waiting.
      assert_receive {:started, ^ref}, 2_000

      config = Config.get(Durable)

      # Confirm pending event exists with the right shape. The {:started, ref}
      # arrives BEFORE wait_for_event throws and the pending row is committed,
      # so poll briefly for the row to appear.
      pending =
        with_backoff([total: 100, sleep: 10], fn ->
          row = repo_pending_event(config, wf_id, "evt_#{ref}")
          assert row != nil
          assert row.status == :pending
          assert row.timeout_at != nil
          row
        end)

      _ = pending

      # Wait long enough for timeout_at to elapse.
      Process.sleep(200)

      # Trigger the timeout sweep and fence on the GenServer.
      TimeoutWorker.check_timeouts(Durable)
      _ = :sys.get_state(TimeoutWorker.worker_name(Durable))

      # PendingEvent transitioned to :timeout. The workflow row is :pending or
      # has already been re-claimed by the poller (status :running) — both
      # are valid intermediate states.
      pending_after = repo_pending_event(config, wf_id, "evt_#{ref}")
      assert pending_after.status == :timeout

      # On resume, the step body re-enters and sends {:started, ref} again,
      # then wait_for_event returns the timeout_value and {:done, ref} fires.
      assert_receive {:started, ^ref}, 3_000
      assert_receive {:done, ^ref}, 3_000

      # Workflow completes with the timeout_value visible.
      with_backoff(fn ->
        exec = config.repo.get!(WorkflowExecution, wf_id)
        assert exec.status == :completed

        # The step echoed the timeout payload back into context. Keys round
        # trip through JSONB as strings.
        assert get_in(exec.context, ["payload"]) == %{
                 "timed_out" => true,
                 "ref" => ref
               }
      end)
    end
  end

  describe "call_workflow child timeout" do
    test "cancels the abandoned child when the parent's call_workflow wait times out" do
      config = Config.get(Durable)
      repo = config.repo

      # A running child whose orchestration parent is waiting on its completion.
      child = insert_exec(repo, :running)
      parent = insert_exec(repo, :waiting)

      # Parent's call_workflow wait, already past its timeout.
      %PendingEvent{}
      |> Ecto.Changeset.change(%{
        workflow_id: parent.id,
        event_name: "__child_done:#{child.id}",
        step_name: "charge_customer",
        status: :pending,
        wait_type: :single,
        timeout_at: DateTime.add(DateTime.utc_now(), -1, :second),
        timeout_value: %{"__atom__" => "child_timeout"}
      })
      |> repo.insert!()

      TimeoutWorker.check_timeouts(Durable)
      _ = :sys.get_state(TimeoutWorker.worker_name(Durable))

      # The abandoned child is cancelled synchronously within the sweep, so by
      # the fence it must be :cancelled — previously it was left running, its
      # eventual result silently dropped.
      assert repo.get!(WorkflowExecution, child.id).status == :cancelled
    end
  end

  defp insert_exec(repo, status) do
    %WorkflowExecution{}
    |> Ecto.Changeset.change(%{
      # A non-resolvable module is fine: the child is never executed (only
      # cancelled) and the resumed parent fails module resolution cleanly
      # rather than affecting this assertion.
      workflow_module: "Elixir.NoSuchModuleForTimeoutTest",
      workflow_name: "orphan_test",
      status: status,
      queue: "default",
      priority: 0,
      input: %{},
      context: %{}
    })
    |> repo.insert!()
  end

  defp repo_pending_event(%Config{repo: repo}, workflow_id, event_name) do
    import Ecto.Query

    repo.one(
      from(p in PendingEvent,
        where: p.workflow_id == ^workflow_id and p.event_name == ^event_name
      )
    )
  end
end
