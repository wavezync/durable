defmodule AttemptCommitParcel do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  workflow "attempt_commit_parcel" do
    step :attempt_commit_weigh, fn parcel ->
      Probe.note(:weighed)
      {:ok, parcel}
    end
  end
end

defmodule AttemptCommitInvoice do
  @moduledoc false
  use Durable
  use Durable.Wait
  alias Durable.IntegrationProbe, as: Probe

  # The invoice is sent, then the run waits to hear it was paid.
  workflow "attempt_commit_invoice" do
    step :await_payment, fn invoice ->
      Probe.note(:invoiced)
      {:ok, Map.put(invoice, "paid", wait_for_event("attempt_commit_paid"))}
    end
  end
end

defmodule Durable.Integration.AttemptCommitTest do
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log

  @row_lock 6_421_377

  # The attempt's row commits only once whoever holds @row_lock lets go. A
  # client that dies as it waits cancels the statement and drops the
  # connection, too late for a commit under way: the wait carries on.
  defp hold_row_commits! do
    IntegrationRepo.query!("""
    CREATE FUNCTION durable.attempt_commit_hold_row() RETURNS trigger AS $$
    BEGIN
      IF NEW.step_name = 'attempt_commit_weigh' THEN
        LOOP
          BEGIN
            PERFORM pg_advisory_xact_lock(#{@row_lock});
            EXIT;
          EXCEPTION WHEN query_canceled THEN
          END;
        END LOOP;
      END IF;
      RETURN NULL;
    END $$ LANGUAGE plpgsql
    """)

    IntegrationRepo.query!("""
    CREATE CONSTRAINT TRIGGER attempt_commit_hold_row AFTER INSERT ON durable.step_executions
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION durable.attempt_commit_hold_row()
    """)

    on_exit(fn ->
      IntegrationRepo.query!("DROP TRIGGER attempt_commit_hold_row ON durable.step_executions")
      IntegrationRepo.query!("DROP FUNCTION durable.attempt_commit_hold_row()")
    end)
  end

  defp waiting_on_advisory do
    %{rows: [[count]]} =
      IntegrationRepo.query!("""
      SELECT count(*) FROM pg_stat_activity
      WHERE datname = current_database() AND state = 'active' AND wait_event = 'advisory'
        AND pid <> pg_backend_pid()
      """)

    count
  end

  def note_attempt([:durable, :step, phase], _measurements, meta, test) do
    if phase == :start, do: send(test, {:task, self()})
    send(test, {:attempt, if(phase == :start, do: :start, else: :end), meta.step_execution_id})
  end

  # The step's task, as it writes the attempt's row (or, sent first, its start).
  def note_insert(
        _event,
        _measurements,
        %{source: "step_executions", query: "INSERT" <> _},
        test
      ),
      do: send(test, {:task, self()})

  def note_insert(_event, _measurements, _meta, _test), do: :ok

  defp attempt_events do
    receive do
      {:attempt, kind, id} -> [{kind, id} | attempt_events()]
    after
      0 -> []
    end
  end

  # A step's task is killed as the attempt's row commits: the COMMIT has
  # reached the database, the task hasn't sent the start event. The row lands,
  # and whoever closes it sends an end for an attempt that never started.
  # audit4_queue_kill_fuzz_test asserts this never happens ("ended, never
  # started"); its random task kills land in this window.
  test "a task killed while its attempt's row commits sends no end without a start" do
    hold_row_commits!()
    test = self()
    handler = "attempt_commit-attempts-#{System.unique_integer([:positive])}"
    phases = for phase <- [:start, :stop, :exception], do: [:durable, :step, phase]
    :telemetry.attach_many(handler, phases, &__MODULE__.note_attempt/4, test)
    query = [:durable, :integration_repo, :query]
    :telemetry.attach("#{handler}-insert", query, &__MODULE__.note_insert/4, test)

    on_exit(fn ->
      :telemetry.detach(handler)
      :telemetry.detach("#{handler}-insert")
    end)

    holder =
      Task.async(fn ->
        IntegrationRepo.transaction(fn ->
          IntegrationRepo.query!("SELECT pg_advisory_xact_lock($1)", [@row_lock])
          send(test, :holding)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :holding
    start_durable!(%{default: 1})
    {:ok, id} = Durable.start(AttemptCommitParcel, %{"parcel" => 1})

    assert_receive {:task, task}, 5_000
    :telemetry.detach("#{handler}-insert")
    assert_eventually(fn -> waiting_on_advisory() == 1 end)

    Process.exit(task, :kill)
    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder)

    # Its row counts as the attempt (failed) or, closed by the next claim, as
    # a lost worker's (completed): either way somebody closes it.
    assert_eventually(fn -> get(id).status in [:completed, :failed] end, 10_000)
    Process.sleep(200)
    events = attempt_events()
    started = for {:start, attempt} <- events, do: attempt
    ended = for {:end, attempt} <- events, do: attempt

    assert ended -- started == [], "ended, never started: #{inspect(ended -- started)}"
  end

  # The first write of the wait's event is refused as a deadlock would be:
  # the database gave up on it, which says nothing about the step (rule 32).
  defp deadlock_first_wait! do
    IntegrationRepo.query!("CREATE SEQUENCE durable.attempt_commit_deadlocks")

    IntegrationRepo.query!("""
    CREATE FUNCTION durable.attempt_commit_deadlock() RETURNS trigger AS $$
    BEGIN
      IF NEW.event_name = 'attempt_commit_paid' AND nextval('durable.attempt_commit_deadlocks') = 1 THEN
        RAISE EXCEPTION 'deadlock detected' USING ERRCODE = 'deadlock_detected';
      END IF;
      RETURN NEW;
    END $$ LANGUAGE plpgsql
    """)

    IntegrationRepo.query!("""
    CREATE TRIGGER attempt_commit_deadlock BEFORE INSERT ON durable.pending_events
    FOR EACH ROW EXECUTE FUNCTION durable.attempt_commit_deadlock()
    """)

    on_exit(fn ->
      IntegrationRepo.query!("DROP TRIGGER attempt_commit_deadlock ON durable.pending_events")
      IntegrationRepo.query!("DROP FUNCTION durable.attempt_commit_deadlock()")
      IntegrationRepo.query!("DROP SEQUENCE durable.attempt_commit_deadlocks")
    end)
  end

  # A deadlock as the step entered its wait was taken for a wait that can't
  # be written: the run failed, for good, and can only be retried by hand.
  test "a wait the database gave up on writing sends the run back, not to failed" do
    deadlock_first_wait!()
    start_durable!(%{default: 1})

    {:ok, id} = Durable.start(AttemptCommitInvoice, %{"invoice" => 1})
    assert_eventually(fn -> get(id).status in [:waiting, :failed] end, 5_000)

    assert {get(id).status, get(id).error} == {:waiting, nil}
    assert Probe.hits(:invoiced) == 2
  end
end
