defmodule Durable.Audit4ApiLookupsTest do
  @moduledoc """
  The read side of the public API, the operator functions and the test helpers,
  called with values that are the right type and still nonsense: unknown ids, a
  negative limit, text Postgres can't hold, a status no run has. Each is an
  answer, never a raw database error, as `list_executions/1` already is.
  """
  use Durable.DataCase, async: false

  import Durable.Testing

  alias Durable.Activity
  alias Durable.Query
  alias Durable.Stats
  alias Durable.Wait

  @moduletag :capture_log

  defmodule Audit4ApiAsks do
    use Durable
    use Durable.Wait

    workflow "audit4_api_lookup_asks" do
      step(:ask, fn data ->
        {:ok, Map.put(data, "answer", wait_for_input("ok"))}
      end)
    end
  end

  defmodule Audit4ApiFails do
    use Durable

    workflow "audit4_api_lookup_fails" do
      step(:work, [compensate: :undo], fn data -> {:ok, data} end)
      step(:break, fn _data -> {:error, "it's 100% broken_"} end)
      compensate(:undo, fn data -> {:ok, data} end)
    end
  end

  setup do
    waiting = run_workflow(Audit4ApiAsks, %{"note" => "50% off"}, tags: ["a'b", "50%"])
    failed = run_workflow(Audit4ApiFails, %{}, key: "order_1")
    {:ok, waiting: waiting.id, failed: failed.id, unknown: Ecto.UUID.generate()}
  end

  @not_ids ["", "not-a-uuid", "00000000-0000-0000-0000-00000000000g", 7, :id, %{}, [1]]

  describe "an id that is no run's" do
    test "is not found by every operator function", %{unknown: unknown} do
      for id <- [unknown | @not_ids] do
        assert Durable.rollback(id) == {:error, :not_found}
        assert Durable.retry(id) == {:error, :not_found}
        assert Durable.rerun(id) == {:error, :not_found}
        assert Durable.release_key(id) == {:error, :not_found}
        assert Durable.cancel(id) == {:error, :not_found}
        assert Durable.get_execution(id) == {:error, :not_found}
        assert Wait.cancel_wait(id) == {:error, :not_found}
        assert Query.get_step_logs(id, :ask) == {:error, :not_found}
      end
    end

    test "has nothing to list", %{unknown: unknown} do
      for id <- [unknown | @not_ids] do
        assert Durable.rollback_plan(id) == []
        assert Durable.list_children(id) == []
        assert Query.get_step_executions(id) == []
      end

      assert Query.child_counts([unknown, nil | @not_ids]) == %{}
    end

    test "nil is not found where the id is checked before the query" do
      assert Durable.rollback(nil) == {:error, :not_found}
      assert Durable.retry(nil) == {:error, :not_found}
      assert Durable.rerun(nil) == {:error, :not_found}
      assert Durable.release_key(nil) == {:error, :not_found}
      assert Durable.cancel(nil) == {:error, :not_found}
      assert Wait.cancel_wait(nil) == {:error, :not_found}
      assert Durable.send_event(nil, "go", %{}) == {:error, :not_found}
      assert Durable.provide_input(nil, "ok", %{}) == {:error, :not_found}
      assert Durable.rollback_plan(nil) == []
      assert Durable.list_children(nil) == []
    end

    # These build their query before Repo.id?/1 is asked (query.ex:28, :255,
    # :277), and Ecto refuses to compare a column with nil: ArgumentError
    # "comparing `w.id` with `nil` is forbidden as it is unsafe".
    for {name, call} <- [
          {"get_execution(nil)", quote(do: Durable.get_execution(nil) == {:error, :not_found})},
          {"get_step_executions(nil)", quote(do: Query.get_step_executions(nil) == [])},
          {"get_step_logs(nil, :ask)",
           quote(do: Query.get_step_logs(nil, :ask) == {:error, :not_found})}
        ] do
      @tag :skip
      test "#{name} is not found, like any other id that is no run's" do
        assert unquote(call)
      end
    end
  end

  describe "the operator functions on the wrong run" do
    test "say what's wrong with it", %{waiting: waiting, failed: failed} do
      assert Durable.rollback(waiting) == {:error, :not_failed}
      assert Durable.retry(waiting) == {:error, :not_failed}
      assert Durable.release_key(waiting) == {:error, :no_key}
      assert Durable.release_key(failed) == :ok
      assert Durable.release_key(failed) == {:error, :no_key}
      assert Durable.rollback_plan(waiting) == []
      assert Durable.rollback_plan(failed) == [work: :undo]

      assert {:ok, ^failed} = Durable.rollback(failed)
      assert Durable.rollback(failed) == {:error, :not_failed}
    end

    test "an instance that was never started is named in the error", %{waiting: waiting} do
      for call <- [
            fn -> Durable.get_execution(waiting, durable: Audit4ApiNoSuchInstance) end,
            fn -> Durable.cancel(waiting, nil, durable: Audit4ApiNoSuchInstance) end,
            fn -> Durable.list_executions(durable: Audit4ApiNoSuchInstance) end,
            fn -> Wait.provide_input(waiting, "ok", %{}, durable: Audit4ApiNoSuchInstance) end,
            fn -> Durable.start(Audit4ApiAsks, %{}, durable: Audit4ApiNoSuchInstance) end,
            fn -> Stats.overview(durable: Audit4ApiNoSuchInstance) end
          ] do
        assert_raise ArgumentError, ~r/Audit4ApiNoSuchInstance not found/, call
      end

      assert {:ok, %{status: :waiting}} = Durable.get_execution(waiting)
    end
  end

  describe "a start that can't be one" do
    test "is refused without a run" do
      before = Query.count_executions()

      assert Durable.start(Audit4ApiNoSuchModule, %{}) == {:error, :not_a_workflow_module}
      assert Durable.start(String, %{}) == {:error, :not_a_workflow_module}
      assert Durable.start(Audit4ApiAsks, %{}, workflow: "no_such") == {:error, :not_found}
      assert Durable.start(Audit4ApiAsks, [1, 2]) == {:error, :invalid_input}
      assert_raise ArgumentError, fn -> Durable.start(Audit4ApiAsks, %{}, return: :bogus) end

      assert Query.count_executions() == before
    end
  end

  describe "text that looks like SQL or a pattern" do
    test "in a filter is compared as text", %{waiting: waiting, failed: failed} do
      ids = fn filters -> filters |> Durable.list_executions() |> Enum.map(& &1.id) end

      assert ids.(tag: "a'b") == [waiting]
      assert ids.(tag: "50%") == [waiting]
      assert ids.(tag: "%") == []
      assert ids.(tag: "' OR '1'='1") == []
      assert ids.(key: "order_1") == [failed]
      assert ids.(key: "order%") == []
      assert ids.(key: "order__") == []
      assert ids.(workflow_name: "audit4_api_lookup_%") == []
      assert ids.(current_step: "a_k") == []
      assert ids.(error_contains: "100% broken_") == [failed]
      assert ids.(error_contains: "100_ broken") == []
      assert ids.(error_contains: "%") == [failed]
      assert ids.(input: %{"note" => "50% off"}) == [waiting]
      assert ids.(input: %{"note" => "50%"}) == []
      assert ids.(input: %{"note'; DROP TABLE durable.workflow_executions; --" => "x"}) == []
      assert ids.(queue: "default'; --") == []

      assert Query.list_keys(key_prefix: "order_") |> Enum.map(& &1.key) == ["order_1"]
      assert Query.list_keys(key_prefix: "order%") == []
      assert Query.list_keys(key_prefix: "%") == []
      assert Query.count_keys(key_prefix: "_rder") == 0
      assert Query.count_executions() == 2
    end

    test "in cancel_all cancels only what matches", %{waiting: waiting} do
      assert Durable.cancel_all([tag: "%"], "x") == {:ok, 0}
      assert Durable.cancel_all([key: "order%"], "x") == {:ok, 0}
      assert Durable.cancel_all([tag: "' OR '1'='1"], "x") == {:ok, 0}
      assert {:ok, %{status: :waiting}} = Durable.get_execution(waiting)

      assert Durable.cancel_all([tag: "50%"], "x") == {:ok, 1}
      assert {:ok, %{status: :cancelled}} = Durable.get_execution(waiting)
    end
  end

  describe "limits and offsets" do
    test "a huge limit or offset is an answer" do
      max = 9_223_372_036_854_775_807

      assert length(Durable.list_executions(limit: max)) == 2
      assert Durable.list_executions(offset: max) == []
      assert {[], 2} = Query.list_executions_with_total(offset: max)
      assert length(Query.list_keys(limit: max)) == 1
      assert length(Wait.list_pending_inputs(limit: max)) == 1
    end

    # Only list_executions/1 clamps them (query.ex:71-72). The rest hand a
    # negative number to Postgres, which raises 2201W/2201X: query.ex:113-114,
    # :469-470, wait.ex:1055 and :1090, stats.ex:226 and :266, activity.ex:92.
    for {name, call} <- [
          {"list_executions_with_total(limit: -1)",
           quote(do: Query.list_executions_with_total(limit: -1))},
          {"list_executions_with_total(offset: -1)",
           quote(do: Query.list_executions_with_total(offset: -1))},
          {"list_keys(limit: -1)", quote(do: Query.list_keys(limit: -1))},
          {"list_keys(offset: -1)", quote(do: Query.list_keys(offset: -1))},
          {"list_pending_inputs(limit: -1)", quote(do: Wait.list_pending_inputs(limit: -1))},
          {"list_pending_events(limit: -1)", quote(do: Wait.list_pending_events(limit: -1))},
          {"Stats.error_groups(limit: -1)", quote(do: Stats.error_groups(limit: -1))},
          {"Stats.failing_workflows(limit: -1)", quote(do: Stats.failing_workflows(limit: -1))},
          {"Activity.list(limit: -1)", quote(do: Activity.list(limit: -1))}
        ] do
      @tag :skip
      test "#{name} lists nothing rather than raising" do
        result = unquote(call)
        assert result in [[], {[], 2}]
      end
    end

    # bucket_seconds goes into the SQL as a divisor (stats.ex:105): 0 raises
    # Postgres 22012, division by zero.
    @tag :skip
    test "Stats.timeline(bucket_seconds: 0) doesn't divide by zero" do
      assert is_list(Stats.timeline(bucket_seconds: 0))
    end
  end

  describe "a value no row can have" do
    # A step name or a workflow name with a NUL or bytes that aren't UTF-8 is
    # sent to Postgres as it is, which raises 22021. list_executions/1 and
    # list_pending_events/1 check Repo.bad_text?/1 first; these don't:
    # query.ex:278, stats.ex:432 and :602, activity.ex:102.
    for {name, call} <- [
          {"get_step_logs/2 with a NUL",
           quote(do: Query.get_step_logs(var!(waiting), "a\0b") == {:error, :not_found})},
          {"get_step_logs/2 with bytes",
           quote(do: Query.get_step_logs(var!(waiting), <<0xFF>>) == {:error, :not_found})},
          {"Stats.workflows(workflow:)", quote(do: Stats.workflows(workflow: "a\0") == [])},
          {"Stats.step_performance(workflow:)",
           quote(do: Stats.step_performance(workflow: "a\0") == [])},
          {"Stats.keys(workflow:)", quote(do: is_map(Stats.keys(workflow: "a\0")))},
          {"Activity.list(kinds:)", quote(do: Activity.list(kinds: ["a\0"]) == [])}
        ] do
      @tag :skip
      test "#{name} matches nothing rather than raising", %{waiting: waiting} do
        _ = waiting
        assert unquote(call)
      end
    end

    # `status: :bogus` alone is caught (query.ex:528), but not in a list
    # (query.ex:576), for children (query.ex:315) or for pending events and
    # inputs (wait.ex:1059, :1094): Ecto.Query.CastError.
    for {name, call} <- [
          {"list_executions(status: [:bogus])",
           quote(do: Durable.list_executions(status: [:bogus]))},
          {"list_executions(status: [:pending, :bogus])",
           quote(do: Durable.list_executions(status: [:pending, :bogus]))},
          {"list_executions_with_total(status: [:bogus])",
           quote(do: Query.list_executions_with_total(status: [:bogus]) |> elem(0))},
          {"list_children(status: :bogus)",
           quote(do: Durable.list_children(var!(waiting), status: :bogus))},
          {"list_pending_events(status: :bogus)",
           quote(do: Wait.list_pending_events(status: :bogus))},
          {"list_pending_inputs(status: :bogus)",
           quote(do: Wait.list_pending_inputs(status: :bogus))}
        ] do
      @tag :skip
      test "#{name} matches nothing rather than raising", %{waiting: waiting} do
        _ = waiting
        assert unquote(call) == []
      end
    end

    # activity.ex:98 compares the id without Repo.id?/1: Ecto.Query.CastError.
    @tag :skip
    test "Activity.list(workflow_id:) with a malformed id lists nothing" do
      assert Activity.list(workflow_id: "not-a-uuid") == []
    end

    test "one unknown status still matches nothing", %{waiting: waiting} do
      assert Durable.list_executions(status: :bogus) == []
      assert Query.count_executions(status: :bogus) == 0
      assert Query.list_keys(holder_status: :bogus) == []
      assert Durable.list_children(waiting, status: :waiting) == []
    end
  end

  describe "the docs" do
    # wait.ex:993 shows `Durable.cancel_wait(workflow_id, reason: ...)`, and the
    # function only exists as Durable.Wait.cancel_wait/2. Durable.provide_input/3
    # likewise can't name an instance, though Wait.provide_input/4 takes :durable.
    @tag :skip
    test "Durable.cancel_wait/2 exists, as the example in Durable.Wait says" do
      Code.ensure_loaded!(Durable)
      assert function_exported?(Durable, :cancel_wait, 2)
    end
  end

  describe "Durable.Testing with a run that doesn't exist" do
    test "drain/2 returns nil", %{unknown: unknown} do
      assert drain(unknown) == nil
    end

    # testing.ex:177 and :213 read fields of the nil that Repo.get returned, so
    # a wrong id surfaces as BadMapError/KeyError from inside the helper, not as
    # a failed assertion that names the id.
    for {name, call} <- [
          {"steps/1", quote(do: steps(var!(unknown)))},
          {"assert_status/2", quote(do: assert_status(var!(unknown), :completed))},
          {"assert_step/2", quote(do: assert_step(var!(unknown), :ask))}
        ] do
      @tag :skip
      test "#{name} fails the test with a message, not a crash", %{unknown: unknown} do
        _ = unknown
        assert_raise ExUnit.AssertionError, fn -> unquote(call) end
      end
    end
  end
end
