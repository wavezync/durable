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
