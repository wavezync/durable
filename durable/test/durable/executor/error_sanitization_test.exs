defmodule Durable.Executor.ErrorSanitizationTest do
  @moduledoc """
  Regression coverage for Bug #3 — secondary JSON encoding errors hiding the
  root cause (see `docs/bug-reports/2026-04-12-parallel-context-and-serialization.md`).

  When a step crashed with an error payload that contained tuples, PIDs,
  functions, or refs, `Repo.update` would fail to encode it as JSONB and
  throw `Protocol.UndefinedError`. That secondary error masked the original
  crash and left the workflow in an unrecoverable `:waiting` state.

  The fix: recursively sanitize the error payload through `sanitize_for_json/1`
  before persisting, with a try/rescue fallback that stores a minimal
  diagnostic if even the sanitized payload fails to save.
  """

  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.WorkflowExecution

  describe "sanitize_for_json/1" do
    test "passes through JSON-safe primitives unchanged" do
      assert Executor.sanitize_for_json(nil) == nil
      assert Executor.sanitize_for_json(true) == true
      assert Executor.sanitize_for_json(42) == 42
      assert Executor.sanitize_for_json(3.14) == 3.14
      assert Executor.sanitize_for_json("hello") == "hello"
      assert Executor.sanitize_for_json(:an_atom) == :an_atom
    end

    test "converts tuples to lists recursively" do
      assert Executor.sanitize_for_json({:ok, "yes"}) == [:ok, "yes"]
      assert Executor.sanitize_for_json({1, 2, 3}) == [1, 2, 3]

      assert Executor.sanitize_for_json({{:nested, "tuple"}, "outer"}) ==
               [[:nested, "tuple"], "outer"]
    end

    test "walks maps recursively" do
      input = %{status: {:ok, "done"}, count: 5}
      assert Executor.sanitize_for_json(input) == %{status: [:ok, "done"], count: 5}
    end

    test "walks lists recursively" do
      input = [{:ok, 1}, {:error, :boom}, "ok"]
      assert Executor.sanitize_for_json(input) == [[:ok, 1], [:error, :boom], "ok"]
    end

    test "preserves Date/DateTime/Time structs (Jason knows how to encode them)" do
      now = DateTime.utc_now()
      today = Date.utc_today()
      time = Time.utc_now()
      naive = NaiveDateTime.utc_now()

      assert Executor.sanitize_for_json(now) == now
      assert Executor.sanitize_for_json(today) == today
      assert Executor.sanitize_for_json(time) == time
      assert Executor.sanitize_for_json(naive) == naive
    end

    test "converts other structs to plain maps" do
      range = 1..5
      # Range is a struct that Jason cannot encode directly.
      result = Executor.sanitize_for_json(range)
      assert is_map(result)
      refute is_struct(result)
    end

    test "stringifies PIDs, references, and functions" do
      pid_result = Executor.sanitize_for_json(self())
      assert is_binary(pid_result)
      assert String.contains?(pid_result, "PID")

      ref_result = Executor.sanitize_for_json(make_ref())
      assert is_binary(ref_result)

      fun_result = Executor.sanitize_for_json(&Enum.map/2)
      assert is_binary(fun_result)
    end

    test "handles deeply nested unencodable values" do
      messy_error = %{
        type: "crash",
        details: [{:ok, {:some, "tuple"}}, [{:error, self()}]],
        meta: %{inner: {make_ref(), :boom}}
      }

      result = Executor.sanitize_for_json(messy_error)

      # Verify the result can actually be encoded to JSON — the point of
      # this whole function.
      assert {:ok, _json} = Jason.encode(result)
    end
  end

  describe "mark_failed survives unencodable error payloads (end-to-end)" do
    test "workflow with error payload containing tuples can be persisted as :failed" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} =
        %WorkflowExecution{}
        |> WorkflowExecution.changeset(%{
          workflow_module: "TestWorkflow",
          workflow_name: "test",
          status: :running,
          queue: "default",
          priority: 0,
          input: %{},
          context: %{},
          locked_by: "test_node",
          locked_at: DateTime.utc_now()
        })
        |> repo.insert()

      # A payload that would have crashed Repo.update before the sanitizer.
      nasty_error = %{
        type: "FunctionClauseError",
        message: "no function clause matching",
        details: {:ok, {:some, "tuple"}},
        worker_pid: self(),
        request_ref: make_ref(),
        retries: [{:attempt, 1, {:error, :timeout}}]
      }

      # Simulate what mark_failed does internally: sanitize, then persist.
      # This is a focused integration check on the save path.
      safe = Executor.sanitize_for_json(nasty_error)

      {:ok, _} =
        execution
        |> Ecto.Changeset.change(status: :failed, error: safe)
        |> repo.update()

      # Re-fetch so we read the JSONB-round-tripped string-keyed version
      # (the same shape the dashboard and consumers will see).
      reloaded = repo.get!(WorkflowExecution, execution.id)

      assert reloaded.status == :failed
      assert reloaded.error["type"] == "FunctionClauseError"
      # Tuples became lists (atoms survive round-trip as strings via JSON)
      assert reloaded.error["details"] == ["ok", ["some", "tuple"]]
      # PID became a string
      assert is_binary(reloaded.error["worker_pid"])
      assert String.contains?(reloaded.error["worker_pid"], "PID")
    end
  end
end
