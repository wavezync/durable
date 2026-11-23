defmodule Durable.Fuzz.Audit4ApiWaitsTest do
  @moduledoc """
  Two properties of waits, run inline in the SQL sandbox so thousands of cases
  are cheap.

  A run with one of every wait, the last of them inside a parallel block's
  lane, is sent random answers, kept events, timeouts, cancels and drains in any
  order; a model says what each call returns and where the run is afterwards.

  And whatever a step's data is, the step sees the same data on the pass after
  a wait, a sleep, a retry or a snooze as it saw the first time, less only what
  JSON can't hold.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Durable.Testing
  import Ecto.Query

  alias Durable.Storage.Schemas.{PendingEvent, PendingInput, WaitGroup, WorkflowExecution}
  alias Durable.TestRepo
  alias Durable.Wait
  alias Durable.Wait.TimeoutWorker
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :fuzz
  @moduletag :capture_log
  @moduletag timeout: :infinity

  @runs String.to_integer(System.get_env("FUZZ_RUNS", "60"))

  # A sandbox and an instance for each case. Durable.DataCase gives a whole
  # property one transaction, which slows as it fills, and one owner, which
  # gives its connection up after two minutes: FUZZ_RUNS can ask for more.
  defp isolated(fun) do
    owner = Sandbox.start_owner!(TestRepo, shared: true)
    start_supervised!({Durable, repo: TestRepo, queue_enabled: false}, id: :audit4_api_durable)

    start_supervised!(
      {TimeoutWorker, config: Durable.Config.get(Durable), interval: 3_600_000},
      id: :audit4_api_sweep
    )

    try do
      fun.()
    after
      stop_supervised!(:audit4_api_sweep)
      stop_supervised!(:audit4_api_durable)
      Sandbox.stop_owner(owner)
    end
  end

  # ===========================================================================
  # Random answers against a model
  # ===========================================================================

  defmodule Audit4ApiEveryWait do
    use Durable
    use Durable.Wait

    alias Durable.Fuzz.Audit4ApiWaitsTest, as: T

    # Each wait says what it returns if it times out, in a shape JSON would
    # change: an atom, a tuple, a map that looks like the engine's own wrapper,
    # and for the last nothing, which is `{:timeout, received}`.
    workflow "audit4_api_every_wait" do
      step :ask, fn data ->
        got = wait_for_input("i1", timeout: 3_600_000, timeout_value: :late)
        {:ok, Map.put(data, "ask", T.describe(got))}
      end

      step :event, fn data ->
        got = wait_for_event("e1", timeout: 3_600_000, timeout_value: {:late, "e1"})
        {:ok, Map.put(data, "event", T.describe(got))}
      end

      step :nap, fn data ->
        sleep(60_000)
        {:ok, Map.put(data, "nap", "slept")}
      end

      step :any, fn data ->
        got = wait_for_any(["g_a", "g_b"], timeout: 3_600_000, timeout_value: T.late_map())
        {:ok, Map.put(data, "any", T.describe(got))}
      end

      step :all, fn data ->
        got = wait_for_all(["g_c", "g_d"], timeout: 3_600_000)
        {:ok, Map.put(data, "all", T.describe(got))}
      end

      parallel :lanes do
        step :lane, fn data -> {:ok, Map.put(data, "lane", T.describe(wait_for_event("l1")))} end
      end
    end
  end

  @steps ["ask", "event", "nap", "any", "all", "lanes"]

  # A wait's answer as text, with a map's keys as strings: an event's name is
  # an atom key only if that atom happens to exist.
  def describe(%{} = map),
    do: inspect(Map.new(map, fn {key, value} -> {to_string(key), value} end))

  def describe(other), do: inspect(other)

  def late_map, do: %{"__atom__" => "audit4_api_late"}

  defp op do
    frequency([
      {6, constant(:drain)},
      {3, constant({:input, "i1"})},
      {1, constant({:input, "nobody_asked"})},
      {8, tuple({constant(:event), member_of(["e1", "g_a", "g_b", "g_c", "g_d"])})},
      {1, constant({:event, "nobody_waits"})},
      {2, constant(:lane_event)},
      {4, tuple({constant(:kept_event), member_of(["e1", "g_a", "g_b", "g_c", "g_d"])})},
      {1, constant({:kept_event, "nobody_waits"})},
      {3, constant(:time_out)},
      {2, constant(:cancel_wait)},
      {1, constant(:cancel)}
    ])
  end

  # The answers that take a run past each step in turn, so the random part
  # starts from every wait as often as from the first.
  @past [
    [:drain, {:input, "i1"}],
    [:drain, {:event, "e1"}],
    [],
    [:drain, {:event, "g_a"}],
    [:drain, {:event, "g_c"}, {:event, "g_d"}],
    [:drain, :lane_event],
    [:drain]
  ]

  defp ops do
    gen all(steps <- integer(0..7), rest <- list_of(op(), max_length: 20)) do
      (@past |> Enum.take(steps) |> List.flatten()) ++ rest
    end
  end

  defp fresh do
    %{
      at: 0,
      status: :pending,
      answer: nil,
      kept: %{},
      any: :not_reached,
      all: :not_reached,
      lane: :not_reached,
      results: %{}
    }
  end

  # ---- the model: what `op` returns, and the state after it ----

  defp expect(model, :drain, _n), do: {:drained, forward(model)}

  defp expect(%{status: :waiting, at: 0} = model, {:input, "i1"}, n),
    do: {:ok, answered(model, %{"n" => n})}

  defp expect(model, {:input, _name}, _n), do: {{:error, :not_found}, model}

  defp expect(%{status: status} = model, {:kept_event, _name}, _n)
       when status in [:completed, :cancelled],
       do: {{:error, :finished}, model}

  # A kept event is delivered if something waits for it, like any other, and
  # kept for a later wait if nothing does.
  defp expect(model, {:kept_event, name}, n) do
    case expect(model, {:event, name}, n) do
      {:ok, %{any: :done} = same} when same == model -> {:ok, keep(model, name, n)}
      {:ok, %{all: :done} = same} when same == model -> {:ok, keep(model, name, n)}
      {:ok, delivered} -> {:ok, delivered}
      {{:error, :not_found}, model} -> {:ok, keep(model, name, n)}
    end
  end

  defp expect(%{status: :waiting, at: 1} = model, {:event, "e1"}, n),
    do: {:ok, answered(model, %{"n" => n})}

  defp expect(%{any: :open} = model, {:event, name}, n) when name in ["g_a", "g_b"],
    do: {:ok, answered(%{model | any: :done}, {name, %{"n" => n}})}

  # The sender can't know which event got there first.
  defp expect(%{any: :done} = model, {:event, name}, _n) when name in ["g_a", "g_b"],
    do: {:ok, model}

  defp expect(%{all: {:open, got}} = model, {:event, name}, n) when name in ["g_c", "g_d"] do
    got = Map.put_new(got, name, %{"n" => n})

    cond do
      is_map_key(elem(model.all, 1), name) -> {{:error, :not_found}, model}
      map_size(got) == 2 -> {:ok, answered(%{model | all: :done}, got)}
      true -> {:ok, %{model | all: {:open, got}}}
    end
  end

  defp expect(%{all: :done} = model, {:event, name}, _n) when name in ["g_c", "g_d"],
    do: {:ok, model}

  defp expect(model, {:event, _name}, _n), do: {{:error, :not_found}, model}

  # A wait that times out returns its call's own timeout_value, as written. An
  # answered wait, a sleep and a block have nothing to time out.
  defp expect(%{status: :waiting, at: 0} = model, :time_out, _n),
    do: {:swept, answered(model, :late)}

  defp expect(%{status: :waiting, at: 1} = model, :time_out, _n),
    do: {:swept, answered(model, {:late, "e1"})}

  defp expect(%{any: :open} = model, :time_out, _n),
    do: {:swept, answered(%{model | any: :closed}, late_map())}

  defp expect(%{all: {:open, got}} = model, :time_out, _n),
    do: {:swept, answered(%{model | all: :closed}, {:timeout, got})}

  defp expect(model, :time_out, _n), do: {:swept, model}

  # The lane's wait is the lane's: its own id answers it.
  defp expect(%{lane: :open} = model, :lane_event, n),
    do: {:ok, %{model | lane: {:got, %{"n" => n}}}}

  defp expect(model, :lane_event, _n), do: {{:error, :not_found}, model}

  # A run waiting for its block has no wait of its own: the cancel goes to the
  # lane if it is waiting, and the block goes on waiting for the lane.
  defp expect(%{status: :waiting, at: 5, lane: :open} = model, :cancel_wait, _n),
    do: {:ok, %{model | lane: {:got, {:cancelled, "stop"}}}}

  defp expect(%{status: :waiting, at: 5} = model, :cancel_wait, _n), do: {:ok, model}

  defp expect(%{status: :waiting} = model, :cancel_wait, _n),
    do: {:ok, model |> close_groups() |> answered({:cancelled, "stop"})}

  defp expect(model, :cancel_wait, _n), do: {{:error, :not_waiting}, model}

  defp expect(%{status: status} = model, :cancel, _n) when status in [:pending, :waiting],
    do: {:ok, %{close_groups(model) | status: :cancelled}}

  defp expect(model, :cancel, _n), do: {{:error, :already_completed}, model}

  defp answered(model, value), do: %{model | status: :pending, answer: {:got, value}}

  # The newest of a name is the one a wait gets.
  defp keep(model, name, n), do: put_in(model.kept[name], %{"n" => n})

  defp close_groups(model) do
    model
    |> Map.update!(:any, &if(&1 == :open, do: :closed, else: &1))
    |> Map.update!(:all, &if(match?({:open, _}, &1), do: :closed, else: &1))
    |> Map.update!(:lane, &if(&1 == :not_reached, do: &1, else: :closed))
  end

  # A drain runs a pending run until it waits again or ends, and its lanes too.
  defp forward(%{status: :pending} = model), do: step(model)

  defp forward(%{status: :waiting, at: 5, lane: {:got, value}} = model),
    do: step(%{model | lane: :done, at: 6, results: Map.put(model.results, "lanes", value)})

  defp forward(model), do: model

  defp step(%{at: 6} = model), do: %{model | status: :completed}

  defp step(%{answer: {:got, value}, at: at} = model) do
    step(%{model | answer: nil, at: at + 1, results: Map.put(model.results, name(at), value)})
  end

  defp step(%{at: 1, kept: %{"e1" => kept}} = model),
    do: step(%{answered(model, kept) | kept: Map.delete(model.kept, "e1")})

  # Durable.Testing.drain/2 ends sleeps.
  defp step(%{at: 2} = model), do: step(answered(model, :slept))

  # wait_for_any takes the first of its names with a kept event.
  defp step(%{at: 3, kept: kept} = model) do
    case Enum.find(["g_a", "g_b"], &is_map_key(kept, &1)) do
      nil ->
        %{model | status: :waiting, any: :open}

      name ->
        step(answered(%{model | any: :done, kept: Map.delete(kept, name)}, {name, kept[name]}))
    end
  end

  # wait_for_all takes every kept event it has a name for, and waits for the rest.
  defp step(%{at: 4, kept: kept} = model) do
    got = Map.take(kept, ["g_c", "g_d"])
    model = %{model | kept: Map.drop(kept, ["g_c", "g_d"])}

    if map_size(got) == 2,
      do: step(answered(%{model | all: :done}, got)),
      else: %{model | status: :waiting, all: {:open, got}}
  end

  # The block starts its lane, and the same drain runs the lane to its wait.
  defp step(%{at: 5} = model), do: %{model | status: :waiting, lane: :open}
  defp step(model), do: %{model | status: :waiting}

  defp name(at), do: Enum.at(@steps, at)

  # ---- the same op against the engine ----

  defp apply_op(id, :drain, _n) do
    drain(id)
    :drained
  end

  defp apply_op(id, {:input, name}, n), do: Durable.provide_input(id, name, %{"n" => n})
  defp apply_op(id, {:event, name}, n), do: Durable.send_event(id, name, %{"n" => n})

  defp apply_op(id, {:kept_event, name}, n),
    do: Durable.send_event(id, name, %{"n" => n}, buffer: true)

  # Every wait of the run that has a timeout is past it, and the sweep has run.
  defp apply_op(id, :time_out, _n) do
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    for schema <- [PendingInput, PendingEvent, WaitGroup] do
      TestRepo.update_all(
        from(p in schema,
          where: p.workflow_id == ^id and p.status == :pending and not is_nil(p.timeout_at)
        ),
        set: [timeout_at: past]
      )
    end

    TimeoutWorker.check_timeouts()
    :sys.get_state(TimeoutWorker.worker_name(Durable))
    :swept
  end

  defp apply_op(id, :lane_event, n) do
    case Durable.list_children!(id) do
      [lane] -> Durable.send_event(lane.id, "l1", %{"n" => n})
      [] -> {:error, :not_found}
    end
  end

  defp apply_op(id, :cancel_wait, _n), do: Wait.cancel_wait(id, reason: "stop")
  defp apply_op(id, :cancel, _n), do: Durable.cancel(id, "stop")

  # A block's result is under its name, each lane's under the lane's.
  defp got(context, "lanes"), do: context["lanes"]["lane"]["lane"]
  defp got(context, step), do: context[step]

  defp expected_result(:slept), do: "slept"
  defp expected_result(value), do: describe(value)

  defp check_run(id, model, history) do
    run = TestRepo.get!(WorkflowExecution, id)
    told = "after #{inspect(Enum.reverse(history))}"

    assert run.status == model.status, "status #{run.status}, expected #{model.status} #{told}"

    if model.status == :waiting,
      do: assert(run.current_step == name(model.at), "at #{run.current_step} #{told}")

    for {step, value} <- model.results, model.status in [:waiting, :completed] do
      assert got(run.context, step) == expected_result(value), "#{step} #{told}"
    end
  end

  property "any order of answers, kept events, cancels and drains ends where the model says" do
    check all(ops <- ops(), max_runs: @runs * 5) do
      isolated(fn ->
        {:ok, id} = Durable.start(Audit4ApiEveryWait, %{})

        ops
        |> Enum.with_index(1)
        |> Enum.reduce({fresh(), []}, fn {op, n}, {model, history} ->
          {expected, model} = expect(model, op, n)
          history = [op | history]

          assert apply_op(id, op, n) == expected,
                 "#{inspect(op)} after #{inspect(Enum.reverse(tl(history)))}"

          check_run(id, model, history)
          {model, history}
        end)
      end)
    end
  end

  # ===========================================================================
  # The same data, however the run got back to the step
  # ===========================================================================

  defmodule Audit4ApiComesBack do
    use Durable
    use Durable.Wait

    workflow "audit4_api_comes_back" do
      step :produce, fn _input -> {:ok, Process.get(:audit4_api_data)} end

      step :observe, [retry: [max_attempts: 2, backoff: :constant, base: 1]], fn data ->
        seen = Process.get(:audit4_api_seen, [])
        Process.put(:audit4_api_seen, seen ++ [data])

        if seen == [],
          do: __MODULE__.leave(Process.get(:audit4_api_way)),
          else: {:ok, data}
      end
    end

    def leave(way) do
      case way do
        :event -> wait_for_event("audit4_api_answer")
        :input -> wait_for_input("audit4_api_answer")
        :any -> wait_for_any(["audit4_api_answer", "audit4_api_other"])
        :sleep -> sleep(60_000)
        :retry -> {:error, "once"}
        :snooze -> {:snooze, 0}
      end
    end
  end

  @ways [:event, :input, :any, :sleep, :retry, :snooze]
  @names ["id", "status", "ok", "error", "total", "x y", "0", "ünï", "a.b", "Elixir.Enum", "_"]

  defp json_leaf do
    one_of([
      integer(),
      float(),
      boolean(),
      constant(nil),
      string(:utf8, max_length: 8),
      member_of([:ok, :error, :"a b", 2 ** 80, -0.0, 1.0e300, 1000.0, -2.0e6, "", "\u{10FFFF}"])
    ])
  end

  defp json_value do
    tree(json_leaf(), fn child ->
      one_of([
        list_of(child, max_length: 3),
        # No name twice in one map, once as an atom and once as a string. Two
        # of the names are drawn often, so a map takes more tries to fill.
        map_of(one_of([member_of(@names), member_of([:nested, :deeper])]), child,
          max_length: 3,
          max_tries: 100
        ),
        tuple({child, child})
      ])
    end)
  end

  # Each name as an atom, as a string, or as both with a value each: JSON
  # holds a name once, and the engine keeps the atom's value beside it.
  defp run_data do
    gen all(
          names <- uniq_list_of(member_of(@names), max_length: 6),
          shapes <- list_of(member_of([:atom, :string, :both]), length: length(names)),
          values <- list_of(tuple({json_value(), json_value()}), length: length(names))
        ) do
      [names, shapes, values]
      |> Enum.zip()
      |> Enum.flat_map(fn
        {name, :atom, {value, _}} -> [{String.to_atom(name), value}]
        {name, :string, {value, _}} -> [{name, value}]
        {name, :both, {value, other}} -> [{String.to_atom(name), value}, {name, other}]
      end)
      |> Map.new()
    end
  end

  defp through_json(value), do: value |> Jason.encode!() |> Jason.decode!()

  # Equal, a number's type included. Only a zero's sign is lost: jsonb has one
  # zero.
  defp same?(a, b) when is_map(a) and is_map(b) do
    Map.keys(a) == Map.keys(b) and Enum.all?(a, fn {key, value} -> same?(value, b[key]) end)
  end

  defp same?(a, b) when is_list(a) and is_list(b),
    do: length(a) == length(b) and a |> Enum.zip(b) |> Enum.all?(fn {x, y} -> same?(x, y) end)

  defp same?(a, b) when is_float(a) and is_float(b), do: a == b
  defp same?(a, b), do: a === b

  defp come_back(id, way) when way in [:event, :any] do
    :ok = Durable.send_event(id, "audit4_api_answer", "x")
    drain(id)
  end

  defp come_back(id, :input) do
    :ok = Durable.provide_input(id, "audit4_api_answer", "x")
    drain(id)
  end

  defp come_back(id, _way), do: drain(id)

  defp observe(data, way) do
    Process.put(:audit4_api_data, data)
    Process.put(:audit4_api_way, way)
    Process.delete(:audit4_api_seen)

    run = run_workflow(Audit4ApiComesBack, %{})
    run = come_back(run.id, way)
    assert run.status == :completed, "#{way}: #{inspect(run.error)}"

    assert [first, second] = Process.get(:audit4_api_seen)
    {first, Map.drop(second, ["audit4_api_answer", :audit4_api_answer])}
  end

  property "a step sees the same data however the run got back to it" do
    check all(data <- run_data(), max_runs: @runs * 3) do
      isolated(fn ->
        for way <- @ways do
          {first, second} = observe(data, way)

          assert Enum.sort_by(Map.keys(second), &inspect/1) ==
                   Enum.sort_by(Map.keys(first), &inspect/1),
                 "#{way} changed the keys of #{inspect(data)}"

          for {key, value} <- first do
            assert same?(through_json(value), second[key]),
                   "#{way} changed #{inspect(key)} of #{inspect(data)} to #{inspect(second[key])}"
          end
        end
      end)
    end
  end
end
