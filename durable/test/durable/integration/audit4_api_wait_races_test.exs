defmodule Durable.Integration.Audit4ApiWaitRacesTest do
  @moduledoc """
  Two answers for one wait, at once. Every answer takes the run's row lock
  first, so a test that holds that lock can line callers up behind it, see them
  all blocked, and let them go together: the interleaving is forced, not hoped
  for.
  """
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log
  @moduletag timeout: 60_000

  alias Durable.Storage.Schemas.{PendingEvent, PendingInput, WaitGroup}
  alias Durable.Wait
  alias Durable.Wait.TimeoutWorker

  defmodule Audit4ApiWaitsEvent do
    use Durable
    use Durable.Wait

    workflow "audit4_api_race_event" do
      step :wait, fn data ->
        got = wait_for_event("go", timeout: 3_600_000, timeout_value: "timed out")
        {:ok, Map.put(data, "got", got)}
      end
    end
  end

  defmodule Audit4ApiAsks do
    use Durable
    use Durable.Wait

    workflow "audit4_api_race_input" do
      step :wait, fn data ->
        got = wait_for_input("answer", timeout: 3_600_000, timeout_value: "timed out")
        {:ok, Map.put(data, "got", got)}
      end
    end
  end

  defmodule Audit4ApiWaitsAny do
    use Durable
    use Durable.Wait

    workflow "audit4_api_race_any" do
      step :wait, fn data ->
        got = wait_for_any(["go", "stop"], timeout: 3_600_000, timeout_value: "timed out")
        {:ok, Map.put(data, "got", inspect(got))}
      end
    end
  end

  defmodule Audit4ApiStartsSlowly do
    use Durable
    use Durable.Wait

    alias Durable.IntegrationProbe, as: Probe

    workflow "audit4_api_race_buffered" do
      step :prepare, fn data ->
        Probe.wait_for(:go_on)
        {:ok, data}
      end

      step :wait, fn data -> {:ok, Map.put(data, "got", wait_for_event("go"))} end
    end
  end

  defmodule Audit4ApiBadWaits do
    use Durable
    use Durable.Wait

    workflow "audit4_api_bad_waits" do
      step :first, fn data -> {:ok, data} end

      step :wait, fn data ->
        case data["kind"] do
          "sleep_too_long" -> sleep(10 ** 30)
          "sleep_before_time" -> sleep(-(10 ** 15))
          "timeout_float" -> wait_for_event("x", timeout: 1.5)
          "timeout_too_long" -> wait_for_input("x", timeout: 10 ** 30)
          "too_deep" -> :ok
        end

        deep = Enum.reduce(1..20_000, [], fn _n, nested -> [nested] end)
        {:ok, Map.put(data, "deep", deep)}
      end
    end
  end

  # Takes the run's row lock and keeps it until told to let go.
  defp hold_lock(id) do
    test = self()

    holder =
      spawn_link(fn ->
        IntegrationRepo.transaction(fn ->
          IntegrationRepo.query!(
            "SELECT 1 FROM durable.workflow_executions WHERE id = $1 FOR UPDATE",
            [Ecto.UUID.dump!(id)]
          )

          send(test, :locked)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :locked, 5_000
    holder
  end

  # How many of this database's connections are waiting for a lock.
  defp await_blocked(count) do
    assert_eventually(
      fn ->
        %{rows: [[blocked]]} =
          IntegrationRepo.query!("""
          SELECT count(*) FROM pg_stat_activity
          WHERE datname = current_database() AND wait_event_type = 'Lock'
          """)

        blocked == count
      end,
      5_000,
      10
    )
  end

  defp waiting(workflow) do
    {:ok, id} = Durable.start(workflow, %{})
    await_status(id, :waiting)
    id
  end

  defp make_due(schema, id) do
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    {1, _} =
      IntegrationRepo.update_all(from(p in schema, where: p.workflow_id == ^id),
        set: [timeout_at: past]
      )
  end

  defp sweep_async do
    TimeoutWorker.check_timeouts()
  end

  setup do
    start_durable!(%{default: 4})
    :ok
  end

  describe "the same event sent twice at once" do
    # The sender looks for the wait once it holds the run's lock, so the second
    # one finds it already answered.
    test "one sender is told :ok, and the row keeps the payload the run got" do
      id = waiting(Audit4ApiWaitsEvent)
      holder = hold_lock(id)

      senders =
        for n <- 1..2, do: Task.async(fn -> Durable.send_event(id, "go", %{"sender" => n}) end)

      await_blocked(2)
      send(holder, :release)
      results = Task.await_many(senders, 10_000)
      run = await_status(id, :completed)

      [event] = IntegrationRepo.all(from(p in PendingEvent, where: p.workflow_id == ^id))

      assert Enum.sort(results) == [:ok, {:error, :not_found}]
      assert event.payload == run.context["got"]
    end
  end

  describe "an event against the timeout sweep" do
    # The other way round: the sweep times the wait out first, and the sender
    # behind it finds no wait left.
    test "an event that lost to the timeout isn't reported as delivered" do
      id = waiting(Audit4ApiWaitsEvent)
      make_due(PendingEvent, id)
      holder = hold_lock(id)

      sweep_async()
      await_blocked(1)
      sender = Task.async(fn -> Durable.send_event(id, "go", %{"real" => true}) end)
      await_blocked(2)
      send(holder, :release)

      result = Task.await(sender, 10_000)
      run = await_status(id, :completed)
      [event] = IntegrationRepo.all(from(p in PendingEvent, where: p.workflow_id == ^id))

      assert run.context["got"] == "timed out"
      assert result == {:error, :not_found}
      assert event.status == :timeout
    end

    # The sweep read the wait as pending before it got the lock; by then it had
    # been answered, and the sweep leaves it as it finds it.
    test "an input answered just before the sweep stays answered" do
      id = waiting(Audit4ApiAsks)
      make_due(PendingInput, id)
      holder = hold_lock(id)

      answer = Task.async(fn -> Durable.provide_input(id, "answer", %{"real" => true}) end)
      await_blocked(1)
      sweep_async()
      await_blocked(2)
      send(holder, :release)

      assert Task.await(answer, 10_000) == :ok
      run = await_status(id, :completed)
      assert run.context["got"] == %{"real" => true}

      # The sweep is a cast: this call returns once it has finished.
      :sys.get_state(TimeoutWorker.worker_name(Durable))
      [input] = IntegrationRepo.all(from(p in PendingInput, where: p.workflow_id == ^id))
      assert input.status == :completed
    end

    test "an event sent just before the sweep stays received" do
      id = waiting(Audit4ApiWaitsEvent)
      make_due(PendingEvent, id)
      holder = hold_lock(id)

      sender = Task.async(fn -> Durable.send_event(id, "go", %{"real" => true}) end)
      await_blocked(1)
      sweep_async()
      await_blocked(2)
      send(holder, :release)

      assert Task.await(sender, 10_000) == :ok
      assert await_status(id, :completed).context["got"] == %{"real" => true}

      :sys.get_state(TimeoutWorker.worker_name(Durable))
      [event] = IntegrationRepo.all(from(p in PendingEvent, where: p.workflow_id == ^id))
      assert event.status == :received
    end

    test "a wait_for_any answered just before the sweep stays answered" do
      id = waiting(Audit4ApiWaitsAny)

      past = DateTime.add(DateTime.utc_now(), -1, :second)

      {1, _} =
        IntegrationRepo.update_all(from(g in WaitGroup, where: g.workflow_id == ^id),
          set: [timeout_at: past]
        )

      holder = hold_lock(id)

      sender = Task.async(fn -> Durable.send_event(id, "go", %{"real" => true}) end)
      await_blocked(1)
      sweep_async()
      await_blocked(2)
      send(holder, :release)

      assert Task.await(sender, 10_000) == :ok
      assert await_status(id, :completed).context["got"] == ~s({"go", %{"real" => true}})

      :sys.get_state(TimeoutWorker.worker_name(Durable))
      [group] = IntegrationRepo.all(from(g in WaitGroup, where: g.workflow_id == ^id))
      events = IntegrationRepo.all(from(p in PendingEvent, where: p.workflow_id == ^id))

      assert group.status == :completed
      assert events |> Enum.map(& &1.status) |> Enum.sort() == [:cancelled, :received]
    end

    test "whichever wins, the run finishes once with one of the two values" do
      id = waiting(Audit4ApiAsks)
      make_due(PendingInput, id)
      holder = hold_lock(id)

      sweep_async()
      await_blocked(1)
      answer = Task.async(fn -> Durable.provide_input(id, "answer", %{"real" => true}) end)
      await_blocked(2)
      send(holder, :release)

      result = Task.await(answer, 10_000)
      run = await_status(id, :completed)
      :sys.get_state(TimeoutWorker.worker_name(Durable))

      case result do
        :ok -> assert run.context["got"] == %{"real" => true}
        {:error, :not_found} -> assert run.context["got"] == "timed out"
      end

      assert IntegrationRepo.aggregate(
               from(s in StepExecution, where: s.workflow_id == ^id and s.status == :completed),
               :count
             ) == 1
    end
  end

  describe "the same input provided many times at once" do
    test "exactly one is taken, and it's the one the run sees" do
      id = waiting(Audit4ApiAsks)
      holder = hold_lock(id)

      answers =
        for n <- 1..6, do: Task.async(fn -> Durable.provide_input(id, "answer", %{"n" => n}) end)

      await_blocked(6)
      send(holder, :release)
      results = Task.await_many(answers, 10_000)
      run = await_status(id, :completed)

      assert Enum.frequencies(results) == %{:ok => 1, {:error, :not_found} => 5}
      [input] = IntegrationRepo.all(from(p in PendingInput, where: p.workflow_id == ^id))
      assert input.status == :completed
      assert input.response == run.context["got"]
    end
  end

  describe "cancel_wait against an answer" do
    test "one of them wins, and the other is told so" do
      id = waiting(Audit4ApiAsks)
      holder = hold_lock(id)

      answer = Task.async(fn -> Durable.provide_input(id, "answer", %{"real" => true}) end)
      cancel = Task.async(fn -> Wait.cancel_wait(id, reason: "changed my mind") end)
      await_blocked(2)
      send(holder, :release)

      results = Task.await_many([answer, cancel], 10_000)
      run = await_status(id, :completed)

      case results do
        [:ok, {:error, :not_waiting}] ->
          assert run.context["got"] == %{"real" => true}

        [{:error, :not_found}, :ok] ->
          assert run.context["got"] == ["cancelled", "changed my mind"]
      end
    end

    test "a cancel against an answer leaves the run cancelled, with no wait open" do
      id = waiting(Audit4ApiAsks)
      holder = hold_lock(id)

      answer = Task.async(fn -> Durable.provide_input(id, "answer", %{"real" => true}) end)
      await_blocked(1)
      cancel = Task.async(fn -> Durable.cancel(id, "stop") end)
      await_blocked(2)
      send(holder, :release)

      [answered, cancelled] = Task.await_many([answer, cancel], 10_000)
      assert_eventually(fn -> get(id).status in [:cancelled, :completed] end, 10_000, 20)

      run = get(id)
      open = IntegrationRepo.all(from(p in PendingInput, where: p.status == :pending))

      assert open == []

      assert {answered, cancelled, run.status} in [
               {:ok, :ok, :cancelled},
               {:ok, {:error, :already_completed}, :completed},
               {{:error, :not_found}, :ok, :cancelled}
             ]
    end
  end

  describe "events sent before the run is waiting" do
    test "kept ones reach it exactly once, however many senders raced its arrival" do
      {:ok, id} = Durable.start(Audit4ApiStartsSlowly, %{})
      assert_eventually(fn -> get(id).status == :running end, 5_000, 10)

      assert Durable.send_event(id, "go", %{"n" => 0}) == {:error, :not_found}

      senders =
        for n <- 1..8 do
          Task.async(fn ->
            if n == 4, do: Probe.set(:go_on)
            Durable.send_event(id, "go", %{"n" => n}, buffer: true)
          end)
        end

      assert Enum.uniq(Task.await_many(senders, 10_000)) == [:ok]
      run = await_status(id, :completed)

      assert %{"n" => n} = run.context["got"]
      assert n in 1..8

      # Whatever arrived after the answer stays kept; nothing is left pending.
      events = IntegrationRepo.all(from(p in PendingEvent, where: p.workflow_id == ^id))
      assert Enum.count(events, &(&1.status == :received)) == 1
      assert Enum.all?(events, &(&1.status in [:received, :buffered]))
    end
  end

  describe "a wait the engine can't record" do
    for kind <- [
          "sleep_too_long",
          "sleep_before_time",
          "timeout_float",
          "timeout_too_long",
          "too_deep"
        ] do
      test "#{kind} fails the run with its error, and the queue moves on" do
        {:ok, bad} = Durable.start(Audit4ApiBadWaits, %{"kind" => unquote(kind)})
        run = await_status(bad, :failed, 20_000)

        assert is_binary(run.error["type"])
        assert is_binary(run.error["message"])
        assert run.locked_by == nil

        # The step that asked for the wait isn't left :waiting on a wait that
        # was never written. (Data too deep to save isn't a wait: the worker
        # closes that attempt.)
        waiting = from(s in StepExecution, where: s.workflow_id == ^bad and s.status == :waiting)
        assert IntegrationRepo.all(waiting) == []

        good = waiting(Audit4ApiAsks)
        assert Durable.provide_input(good, "answer", "fine") == :ok
        assert await_status(good, :completed).context["got"] == "fine"
      end
    end
  end
end
