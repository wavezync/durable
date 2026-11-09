defmodule Durable.HostileValuesTest do
  @moduledoc """
  One value a workflow hands over mustn't poison its row or stop the engine.
  Found by the fuzz suite (`mix test --only fuzz`).
  """
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Executor.StepRunner
  alias Durable.Storage.Schemas.{PendingEvent, WorkflowExecution}
  alias Durable.TestRepo
  alias Durable.Wait.TimeoutWorker

  defmodule Returns do
    use Durable

    workflow "hostile_returns" do
      step(:a, fn data ->
        Durable.HostileValuesTest.returned(data[:what] || data["what"])
      end)
    end
  end

  def returned("error_date"), do: {:error, ~D[2026-01-01]}
  def returned("fail_decimal"), do: {:fail, Decimal.new("1.5")}
  def returned("ok_date"), do: {:ok, ~D[2026-01-01]}
  def returned("error_nul"), do: {:error, "a\0b"}
  def returned("error_bytes"), do: {:error, %{<<0xFF>> => <<0xFE>>}}
  def returned("ok_nul"), do: {:ok, %{"a\0" => :"b\0"}}
  def returned("ok_improper"), do: {:ok, %{"list" => [1 | 2]}}

  for {what, status} <- [
        {"error_date", :failed},
        {"fail_decimal", :failed},
        {"ok_date", :failed},
        {"error_nul", :failed},
        {"error_bytes", :failed},
        {"ok_nul", :completed},
        {"ok_improper", :completed}
      ] do
    test "a step returning #{what} ends #{status} and can be read back" do
      {:ok, id} = Executor.start_workflow(Returns, %{what: unquote(what)}, inline: true)

      assert TestRepo.get!(WorkflowExecution, id).status == unquote(status)
    end
  end

  defmodule WaitsWithDate do
    use Durable
    use Durable.Wait

    workflow "hostile_timeout_value" do
      step(:a, fn data ->
        wait_for_event("never", timeout: 1, timeout_value: ~U[2026-01-01 00:00:00Z])
        {:ok, data}
      end)
    end
  end

  defp sweep do
    worker = TimeoutWorker.worker_name(Durable)
    TimeoutWorker.check_timeouts(Durable)
    :sys.get_state(worker)
    assert Process.alive?(Process.whereis(worker))
  end

  defp events, do: TestRepo.all(PendingEvent)

  describe "the timeout sweep" do
    setup do
      start_supervised!({TimeoutWorker, config: Config.get(Durable), interval: 3_600_000})
      :ok
    end

    test "can read a timeout_value that's a date, and resumes the run" do
      {:ok, id} = Executor.start_workflow(WaitsWithDate, %{}, inline: true)
      assert [%PendingEvent{}] = events()
      Process.sleep(5)

      sweep()

      assert TestRepo.get!(WorkflowExecution, id).status == :pending
    end

    test "survives a row it can't load, and the other sweeps still run" do
      {:ok, id} = Executor.start_workflow(WaitsWithDate, %{}, inline: true)
      Process.sleep(5)

      TestRepo.query!("UPDATE durable.pending_events SET timeout_value = '\"poison\"'::jsonb")

      past = DateTime.add(DateTime.utc_now(), -1, :second)

      TestRepo.update_all(from(w in WorkflowExecution, where: w.id == ^id),
        set: [deadline_at: past]
      )

      sweep()

      assert TestRepo.get!(WorkflowExecution, id).status == :pending
    end
  end

  describe "an id that couldn't be a run's" do
    for id <- ["", "not-a-uuid", String.duplicate("x", 36), <<0::128>>] do
      test "#{inspect(id)} is not found, everywhere an id is taken" do
        id = unquote(id)

        assert Durable.get_execution(id) == {:error, :not_found}
        assert Durable.cancel(id) == {:error, :not_found}
        assert Durable.retry(id) == {:error, :not_found}
        assert Durable.rerun(id) == {:error, :not_found}
        assert Durable.release_key(id) == {:error, :not_found}
        assert Durable.send_event(id, "go", %{}) == {:error, :not_found}
        assert Durable.send_event(id, "go", %{}, buffer: true) == {:error, :not_found}
        assert Durable.provide_input(id, "go", %{}) == {:error, :not_found}
        assert Durable.list_children(id) == []
      end
    end
  end

  describe "text Postgres can't hold" do
    test "matches nothing when it's a filter or a name" do
      {:ok, id} = Durable.start(Returns, %{})

      for bad <- ["a\0b", <<0xFF>>] do
        assert Durable.list_executions(queue: bad) == []
        assert Durable.list_executions(key: bad) == []
        assert Durable.list_executions(tag: bad) == []
        assert Durable.cancel_all([tag: bad], "x") == {:ok, 0}
        assert Durable.send_event(id, bad, %{}) == {:error, :not_found}
        assert Durable.send_event(id, bad, %{}, buffer: true) == {:error, :not_found}
        assert Durable.provide_input(id, bad, %{}) == {:error, :not_found}
        assert Durable.get_schedule(bad) == {:error, :not_found}
        assert Durable.delete_schedule(bad) == {:error, :not_found}
        assert Durable.pause_queue(bad) == {:error, :invalid_queue}
      end
    end

    for opts <- [[key: "a\0"], [queue: "a\0"], [tags: ["ok", <<0xFF>>]], [queue: :"a\0"]] do
      test "is refused by name in #{inspect(opts)}" do
        assert_raise ArgumentError, ~r/can't be stored/, fn ->
          Durable.start(Returns, %{}, unquote(opts))
        end
      end
    end
  end

  test "a start's input is made storable, or refused if it can't be an object" do
    {:ok, id} = Durable.start(Returns, %{"t" => {:a, self()}, "n" => "a\0"})
    assert %{"t" => ["a", _pid], "n" => "a\uFFFD"} = TestRepo.get!(WorkflowExecution, id).input

    assert Durable.start(Returns, ~D[2026-01-01]) == {:error, :invalid_input}
    assert Durable.start(Returns, "a string") == {:error, :invalid_input}
  end

  test "any cancel reason can be stored" do
    {:ok, id} = Durable.start(Returns, %{})

    assert Durable.cancel(id, {:reason, self(), "a\0"}) == :ok

    assert %{status: :cancelled, error: %{"message" => [_, _, _]}} =
             TestRepo.get!(WorkflowExecution, id)
  end

  test "a negative limit or offset lists nothing rather than raising" do
    assert Durable.list_executions(limit: -1) == []
    assert is_list(Durable.list_executions(offset: -1))
  end

  test "sanitizing leaves nothing Postgres or JSON would reject" do
    for term <- ["a\0b", <<0xFF>>, :"a\0", %{"k\0" => 1}, %{<<0xFF>> => 1}, [1 | 2]] do
      safe = Executor.sanitize_for_json(term)
      assert {:ok, _} = TestRepo.query("SELECT $1::jsonb", [%{"v" => safe}])
    end
  end

  test "an output or error that's a scalar still fits a map column" do
    assert %{value: ~D[2026-01-01]} = StepRunner.serialize_output(~D[2026-01-01])
    assert %{message: "~D[2026-01-01]"} = Executor.storable_error(~D[2026-01-01])
  end
end
