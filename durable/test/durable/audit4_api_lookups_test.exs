defmodule Durable.Audit4ApiLookupsTest do
  @moduledoc """
  The read side of the public API, the operator functions and the test helpers,
  called with values that are the right type and still nonsense: unknown ids, a
  negative limit, text Postgres can't hold, a status no run has. Each is an
  answer, never a raw database error: `{:error, :not_found}` for an id that
  names nothing and `{:error, {:invalid_option, key}}` for an option that is
  wrong, with the `!` form raising `ArgumentError`.
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
      step :ask, fn data ->
        {:ok, Map.put(data, "answer", wait_for_input("ok"))}
      end
    end
  end

  defmodule Audit4ApiFails do
    use Durable

    workflow "audit4_api_lookup_fails" do
      step :work, [compensate: :undo], fn data -> {:ok, data} end
      step :break, fn _data -> {:error, "it's 100% broken_"} end
      compensate :undo, fn data -> {:ok, data} end
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

    test "is not found by what lists a run's parts", %{unknown: unknown, waiting: waiting} do
      for id <- [unknown, nil | @not_ids] do
        assert Durable.rollback_plan(id) == {:error, :not_found}
        assert Durable.list_children(id) == {:error, :not_found}
        assert Query.get_step_executions(id) == {:error, :not_found}

        assert_raise ArgumentError, ~r/nothing found for/, fn -> Durable.rollback_plan!(id) end
        assert_raise ArgumentError, ~r/nothing found for/, fn -> Durable.list_children!(id) end
        assert_raise ArgumentError, fn -> Query.get_step_executions!(id) end
        assert_raise ArgumentError, fn -> Durable.get_execution!(id) end
      end

      # A run with nothing to list is a run all the same.
      assert Durable.list_children(waiting) == {:ok, []}
      assert Durable.rollback_plan(waiting) == {:ok, []}
    end

    test "in a list of parents is the caller's mistake, unless it is only unknown",
         %{unknown: unknown} do
      assert Query.child_counts([unknown]) == {:ok, %{}}
      assert Query.child_counts([]) == {:ok, %{}}

      for ids <- [[unknown, nil], @not_ids, nil, "x", %{}] do
        assert Query.child_counts(ids) == {:error, {:invalid_option, :parent_ids}}
        assert_raise ArgumentError, ~r/:parent_ids/, fn -> Query.child_counts!(ids) end
      end
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
    end

    # These built their query before Repo.id?/1 was asked, and Ecto refuses to
    # compare a column with nil.
    for {name, call} <- [
          {"get_execution(nil)", quote(do: Durable.get_execution(nil))},
          {"get_step_executions(nil)", quote(do: Query.get_step_executions(nil))},
          {"get_step_logs(nil, :ask)", quote(do: Query.get_step_logs(nil, :ask))}
        ] do
      test "#{name} is not found, like any other id that is no run's" do
        assert unquote(call) == {:error, :not_found}
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
      assert Durable.rollback_plan(waiting) == {:ok, []}
      assert Durable.rollback_plan(failed) == {:ok, [work: :undo]}
      assert Durable.rollback_plan!(failed) == [work: :undo]

      assert {:ok, ^failed} = Durable.rollback(failed)
      assert Durable.rollback(failed) == {:error, :not_failed}
    end

    test "an instance that was never started is named in the error", %{waiting: waiting} do
      for call <- [
            fn -> Durable.get_execution(waiting, durable: Audit4ApiNoSuchInstance) end,
            fn -> Durable.cancel(waiting, nil, durable: Audit4ApiNoSuchInstance) end,
            fn -> Durable.list_executions(durable: Audit4ApiNoSuchInstance) end,
            fn -> Durable.list_executions!(durable: Audit4ApiNoSuchInstance) end,
            fn -> Durable.get_execution!(waiting, durable: Audit4ApiNoSuchInstance) end,
            fn -> Durable.list_nodes(durable: Audit4ApiNoSuchInstance) end,
            fn -> Stats.overview(durable: Audit4ApiNoSuchInstance) end,
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
      before = Query.count_executions!()

      assert Durable.start(Audit4ApiNoSuchModule, %{}) == {:error, :not_a_workflow_module}
      assert Durable.start(String, %{}) == {:error, :not_a_workflow_module}
      assert Durable.start(Audit4ApiAsks, %{}, workflow: "no_such") == {:error, :not_found}
      assert Durable.start(Audit4ApiAsks, [1, 2]) == {:error, :invalid_input}
      assert_raise ArgumentError, fn -> Durable.start(Audit4ApiAsks, %{}, return: :bogus) end

      assert Query.count_executions!() == before
    end
  end

  describe "text that looks like SQL or a pattern" do
    test "in a filter is compared as text", %{waiting: waiting, failed: failed} do
      ids = fn filters -> filters |> Durable.list_executions!() |> Enum.map(& &1.id) end

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

      assert Query.list_keys!(key_prefix: "order_") |> Enum.map(& &1.key) == ["order_1"]
      assert Query.list_keys!(key_prefix: "order%") == []
      assert Query.list_keys!(key_prefix: "%") == []
      assert Query.count_keys!(key_prefix: "_rder") == 0
      assert Query.count_executions!() == 2
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

      assert length(Durable.list_executions!(limit: max)) == 2
      assert Durable.list_executions!(offset: max) == []
      assert {[], 2} = Query.list_executions_with_total!(offset: max)
      assert length(Query.list_keys!(limit: max)) == 1
      assert length(Wait.list_pending_inputs!(limit: max)) == 1
    end

    test "one past what Postgres can count to is the caller's mistake" do
      assert Durable.list_executions(limit: 2 ** 63) == {:error, {:invalid_option, :limit}}
      assert Durable.list_executions(offset: 2 ** 70) == {:error, {:invalid_option, :offset}}
    end

    # list_executions/1 used to clamp them to 0, and the rest handed a negative
    # number to Postgres, which raises 2201W/2201X.
    for {name, key, call, bang} <- [
          {"list_executions(limit: -1)", :limit, quote(do: Durable.list_executions(limit: -1)),
           quote(do: Durable.list_executions!(limit: -1))},
          {"list_executions(offset: -1)", :offset, quote(do: Durable.list_executions(offset: -1)),
           quote(do: Durable.list_executions!(offset: -1))},
          {"list_executions_with_total(limit: -1)", :limit,
           quote(do: Query.list_executions_with_total(limit: -1)),
           quote(do: Query.list_executions_with_total!(limit: -1))},
          {"list_executions_with_total(offset: -1)", :offset,
           quote(do: Query.list_executions_with_total(offset: -1)),
           quote(do: Query.list_executions_with_total!(offset: -1))},
          {"list_keys(limit: -1)", :limit, quote(do: Query.list_keys(limit: -1)),
           quote(do: Query.list_keys!(limit: -1))},
          {"list_keys(offset: -1)", :offset, quote(do: Query.list_keys(offset: -1)),
           quote(do: Query.list_keys!(offset: -1))},
          {"list_pending_inputs(limit: -1)", :limit,
           quote(do: Wait.list_pending_inputs(limit: -1)),
           quote(do: Wait.list_pending_inputs!(limit: -1))},
          {"list_pending_events(limit: -1)", :limit,
           quote(do: Wait.list_pending_events(limit: -1)),
           quote(do: Wait.list_pending_events!(limit: -1))},
          {"Stats.error_groups(limit: -1)", :limit, quote(do: Stats.error_groups(limit: -1)),
           quote(do: Stats.error_groups!(limit: -1))},
          {"Stats.failing_workflows(limit: -1)", :limit,
           quote(do: Stats.failing_workflows(limit: -1)),
           quote(do: Stats.failing_workflows!(limit: -1))},
          {"Activity.list(limit: -1)", :limit, quote(do: Activity.list(limit: -1)),
           quote(do: Activity.list!(limit: -1))}
        ] do
      test "#{name} is the caller's mistake, not clamped and not a database error" do
        assert unquote(call) == {:error, {:invalid_option, unquote(key)}}

        assert_raise ArgumentError,
                     "invalid value for option #{inspect(unquote(key))}: -1",
                     fn -> unquote(bang) end
      end
    end

    # bucket_seconds goes into the SQL as a divisor: 0 raised Postgres 22012,
    # division by zero.
    test "Stats.timeline(bucket_seconds: 0) doesn't divide by zero" do
      for bad <- [0, -5, 1.5, "60"] do
        assert Stats.timeline(bucket_seconds: bad) == {:error, {:invalid_option, :bucket_seconds}}
        assert Stats.keys(bucket_seconds: bad) == {:error, {:invalid_option, :bucket_seconds}}
      end

      assert_raise ArgumentError, "invalid value for option :bucket_seconds: 0", fn ->
        Stats.timeline!(bucket_seconds: 0)
      end
    end
  end

  describe "a value no row can have" do
    # A step's name is which step, as the id is which run: one Postgres can't
    # hold names no step. It was sent as it is, which raises 22021.
    test "get_step_logs/2 with a NUL or bytes that aren't text is not found",
         %{waiting: waiting} do
      for name <- ["a\0b", <<0xFF>>, 7, %{}] do
        assert Query.get_step_logs(waiting, name) == {:error, :not_found}
        assert_raise ArgumentError, fn -> Query.get_step_logs!(waiting, name) end
      end
    end

    # A filter with a NUL or bytes that aren't UTF-8 was sent to Postgres as it
    # is (22021), or quietly matched nothing.
    for {name, key, call, bang} <- [
          {"Stats.workflows(workflow:)", :workflow, quote(do: Stats.workflows(workflow: "a\0")),
           quote(do: Stats.workflows!(workflow: "a\0"))},
          {"Stats.step_performance(workflow:)", :workflow,
           quote(do: Stats.step_performance(workflow: "a\0")),
           quote(do: Stats.step_performance!(workflow: "a\0"))},
          {"Stats.keys(workflow:)", :workflow, quote(do: Stats.keys(workflow: <<0xFF>>)),
           quote(do: Stats.keys!(workflow: <<0xFF>>))},
          {"Activity.list(kinds:)", :kinds, quote(do: Activity.list(kinds: ["a\0"])),
           quote(do: Activity.list!(kinds: ["a\0"]))},
          {"list_executions(tag:)", :tag, quote(do: Durable.list_executions(tag: "a\0")),
           quote(do: Durable.list_executions!(tag: "a\0"))},
          {"list_pending_events(event_name:)", :event_name,
           quote(do: Wait.list_pending_events(event_name: "a\0")),
           quote(do: Wait.list_pending_events!(event_name: "a\0"))}
        ] do
      test "#{name} with text Postgres can't hold is the caller's mistake" do
        assert unquote(call) == {:error, {:invalid_option, unquote(key)}}
        assert_raise ArgumentError, ~r/invalid value for option/, fn -> unquote(bang) end
      end
    end

    # `status: :bogus` alone matched nothing, and in a list, for children or
    # for pending events and inputs it was an Ecto.Query.CastError.
    for {name, key, call, bang} <- [
          {"list_executions(status: :bogus)", :status,
           quote(do: Durable.list_executions(status: :bogus)),
           quote(do: Durable.list_executions!(status: :bogus))},
          {"list_executions(status: [:bogus])", :status,
           quote(do: Durable.list_executions(status: [:bogus])),
           quote(do: Durable.list_executions!(status: [:bogus]))},
          {"list_executions(status: [:pending, :bogus])", :status,
           quote(do: Durable.list_executions(status: [:pending, :bogus])),
           quote(do: Durable.list_executions!(status: [:pending, :bogus]))},
          {"list_executions_with_total(status: [:bogus])", :status,
           quote(do: Query.list_executions_with_total(status: [:bogus])),
           quote(do: Query.list_executions_with_total!(status: [:bogus]))},
          {"count_executions(status: :bogus)", :status,
           quote(do: Query.count_executions(status: :bogus)),
           quote(do: Query.count_executions!(status: :bogus))},
          {"list_keys(holder_status: :bogus)", :holder_status,
           quote(do: Query.list_keys(holder_status: :bogus)),
           quote(do: Query.list_keys!(holder_status: :bogus))},
          {"list_children(status: :bogus)", :status,
           quote(do: Durable.list_children(var!(waiting), status: :bogus)),
           quote(do: Durable.list_children!(var!(waiting), status: :bogus))},
          {"list_pending_events(status: :bogus)", :status,
           quote(do: Wait.list_pending_events(status: :bogus)),
           quote(do: Wait.list_pending_events!(status: :bogus))},
          {"list_pending_inputs(status: :bogus)", :status,
           quote(do: Wait.list_pending_inputs(status: :bogus)),
           quote(do: Wait.list_pending_inputs!(status: :bogus))}
        ] do
      test "#{name} is the caller's mistake", %{waiting: waiting} do
        _ = waiting
        assert unquote(call) == {:error, {:invalid_option, unquote(key)}}

        assert_raise ArgumentError, ~r/invalid value for option :\w+: .*bogus/, fn ->
          unquote(bang)
        end
      end
    end

    # The id was compared without Repo.id?/1: Ecto.Query.CastError.
    test "a filter on an id that isn't one is the caller's mistake" do
      assert Activity.list(workflow_id: "not-a-uuid") == {:error, {:invalid_option, :workflow_id}}
      assert Durable.list_executions(id: "not-a-uuid") == {:error, {:invalid_option, :id}}

      assert Durable.list_executions(parent_workflow_id: "") ==
               {:error, {:invalid_option, :parent_workflow_id}}

      assert_raise ArgumentError, ~s(invalid value for option :workflow_id: "not-a-uuid"), fn ->
        Activity.list!(workflow_id: "not-a-uuid")
      end
    end

    test "a status a run can have, and a filter left nil, are answers", %{waiting: waiting} do
      assert Durable.list_children(waiting, status: :waiting) == {:ok, []}
      assert {:ok, [%{id: ^waiting}]} = Durable.list_executions(status: [:waiting], tag: nil)
      assert {:ok, [_, _]} = Durable.list_executions(limit: nil, status: [])
    end

    test "options that aren't a keyword list are the caller's mistake" do
      for opts <- [%{limit: 1}, "limit", [1, 2], [{"limit", 1}]] do
        assert Durable.list_executions(opts) == {:error, {:invalid_option, :opts}}
        assert Stats.overview(opts) == {:error, {:invalid_option, :opts}}
        assert_raise ArgumentError, ~r/:opts/, fn -> Durable.list_executions!(opts) end
      end
    end
  end

  describe "the docs" do
    # The docs showed `Durable.cancel_wait(workflow_id, reason: ...)` before the
    # function was there. It is now, beside the other things an operator does.
    test "Durable.cancel_wait/2 is there to call, as its example shows", %{waiting: waiting} do
      assert Durable.cancel_wait(waiting, reason: "no longer needed") == :ok
      assert Durable.cancel_wait(waiting) == {:error, :not_waiting}
    end
  end

  describe "Durable.Testing with a run that doesn't exist" do
    test "drain/2 returns nil", %{unknown: unknown} do
      assert drain(unknown) == nil
    end

    # These read fields of the nil that Repo.get returned, so a wrong id
    # surfaced as BadMapError/KeyError from inside the helper, not as a failed
    # assertion that names the id.
    for {name, call} <- [
          {"steps/1", quote(do: steps(var!(unknown)))},
          {"assert_status/2", quote(do: assert_status(var!(unknown), :completed))},
          {"assert_step/2", quote(do: assert_step(var!(unknown), :ask))}
        ] do
      test "#{name} fails the test with a message, not a crash", %{unknown: unknown} do
        _ = unknown
        assert_raise ExUnit.AssertionError, fn -> unquote(call) end
      end
    end
  end
end
