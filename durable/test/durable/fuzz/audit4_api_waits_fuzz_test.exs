defmodule Durable.Fuzz.Audit4ApiWaitsTest do
  @moduledoc """
  Two properties of waits, run inline in the SQL sandbox so thousands of cases
  are cheap.

  A run with one of every wait is sent random answers, kept events, cancels and
  drains in any order; a model says what each call returns and where the run
  is afterwards.

  And whatever a step's data is, the step sees the same data on the pass after
  a wait, a sleep, a retry or a snooze as it saw the first time, less only what
  JSON can't hold.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Durable.Testing

  alias Durable.Storage.Schemas.WorkflowExecution
  alias Durable.TestRepo
  alias Durable.Wait
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

    try do
      fun.()
    after
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

    workflow "audit4_api_every_wait" do
      step(:ask, fn data -> {:ok, Map.put(data, "ask", T.describe(wait_for_input("i1")))} end)
      step(:event, fn data -> {:ok, Map.put(data, "event", T.describe(wait_for_event("e1")))} end)

      step(:nap, fn data ->
        sleep(60_000)
        {:ok, Map.put(data, "nap", "slept")}
      end)

      step(:any, fn data ->
        {:ok, Map.put(data, "any", T.describe(wait_for_any(["g_a", "g_b"])))}
      end)

      step(:all, fn data ->
        {:ok, Map.put(data, "all", T.describe(wait_for_all(["g_c", "g_d"])))}
      end)
    end
  end

  @steps ["ask", "event", "nap", "any", "all"]

  # A wait's answer as text, with a map's keys as strings: an event's name is
  # an atom key only if that atom happens to exist.
  def describe(%{} = map),
    do: inspect(Map.new(map, fn {key, value} -> {to_string(key), value} end))

  def describe(other), do: inspect(other)

  defp op do
    frequency([
      {6, constant(:drain)},
      {3, constant({:input, "i1"})},
      {1, constant({:input, "nobody_asked"})},
      {8, tuple({constant(:event), member_of(["e1", "g_a", "g_b", "g_c", "g_d"])})},
      {1, constant({:event, "nobody_waits"})},
      {2, constant({:kept_event, "e1"})},
      {1, constant({:kept_event, "nobody_waits"})},
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
    [:drain]
  ]

  defp ops do
    gen all(steps <- integer(0..6), rest <- list_of(op(), max_length: 20)) do
      (@past |> Enum.take(steps) |> List.flatten()) ++ rest
    end
  end

  defp fresh do
    %{
      at: 0,
      status: :pending,
      answer: nil,
      kept: nil,
      any: :not_reached,
      all: :not_reached,
      results: %{}
    }
  end

  # ---- the model: what `op` returns, and the state after it ----

  defp expect(model, :drain, _n), do: {:drained, forward(model)}

  defp expect(%{status: :waiting, at: 0} = model, {:input, "i1"}, n),
    do: {:ok, answered(model, %{"n" => n})}

  defp expect(model, {:input, _name}, _n), do: {{:error, :not_found}, model}

  defp expect(%{status: :waiting, at: 1} = model, {kind, "e1"}, n)
       when kind in [:event, :kept_event],
       do: {:ok, answered(model, %{"n" => n})}

  defp expect(%{status: status} = model, {:kept_event, _name}, _n)
       when status in [:completed, :cancelled],
       do: {{:error, :finished}, model}

  defp expect(model, {:kept_event, "e1"}, n), do: {:ok, %{model | kept: %{"n" => n}}}
  defp expect(model, {:kept_event, _name}, _n), do: {:ok, model}

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

  defp expect(%{status: :waiting} = model, :cancel_wait, _n),
    do: {:ok, model |> close_groups() |> answered({:cancelled, "stop"})}

  defp expect(model, :cancel_wait, _n), do: {{:error, :not_waiting}, model}

  defp expect(%{status: status} = model, :cancel, _n) when status in [:pending, :waiting],
    do: {:ok, %{close_groups(model) | status: :cancelled}}

  defp expect(model, :cancel, _n), do: {{:error, :already_completed}, model}

  defp answered(model, value), do: %{model | status: :pending, answer: {:got, value}}

  defp close_groups(model) do
    model
    |> Map.update!(:any, &if(&1 == :open, do: :closed, else: &1))
    |> Map.update!(:all, &if(match?({:open, _}, &1), do: :closed, else: &1))
  end

  # A drain runs a pending run until it waits again or ends.
  defp forward(%{status: :pending} = model), do: step(model)
  defp forward(model), do: model

  defp step(%{at: 5} = model), do: %{model | status: :completed}

  defp step(%{answer: {:got, value}, at: at} = model) do
    step(%{model | answer: nil, at: at + 1, results: Map.put(model.results, name(at), value)})
  end

  defp step(%{at: 1, kept: %{} = kept} = model), do: step(%{answered(model, kept) | kept: nil})
  # Durable.Testing.drain/2 ends sleeps.
  defp step(%{at: 2} = model), do: step(answered(model, :slept))
  defp step(%{at: 3} = model), do: %{model | status: :waiting, any: :open}
  defp step(%{at: 4} = model), do: %{model | status: :waiting, all: {:open, %{}}}
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

  defp apply_op(id, :cancel_wait, _n), do: Wait.cancel_wait(id, reason: "stop")
  defp apply_op(id, :cancel, _n), do: Durable.cancel(id, "stop")

  defp expected_result(:slept), do: "slept"
  defp expected_result(value), do: describe(value)

  defp check_run(id, model, history) do
    run = TestRepo.get!(WorkflowExecution, id)
    told = "after #{inspect(Enum.reverse(history))}"

    assert run.status == model.status, "status #{run.status}, expected #{model.status} #{told}"

    if model.status == :waiting,
      do: assert(run.current_step == name(model.at), "at #{run.current_step} #{told}")

    for {step, value} <- model.results, model.status in [:waiting, :completed] do
      assert run.context[step] == expected_result(value), "#{step} #{told}"
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
      step(:produce, fn _input -> {:ok, Process.get(:audit4_api_data)} end)

      step(:observe, [retry: [max_attempts: 2, backoff: :constant, base: 1]], fn data ->
        seen = Process.get(:audit4_api_seen, [])
        Process.put(:audit4_api_seen, seen ++ [data])

        if seen == [],
          do: __MODULE__.leave(Process.get(:audit4_api_way)),
          else: {:ok, data}
      end)
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
        # No name twice in one map, once as an atom and once as a string.
        map_of(one_of([member_of(@names), member_of([:nested, :deeper])]), child, max_length: 3),
        tuple({child, child})
      ])
    end)
  end

  # Each name once, as an atom or as a string: JSON can't hold both.
  defp run_data do
    gen all(
          names <- uniq_list_of(member_of(@names), max_length: 6),
          shapes <- list_of(boolean(), length: length(names)),
          values <- list_of(json_value(), length: length(names))
        ) do
      [names, shapes, values]
      |> Enum.zip()
      |> Map.new(fn {name, atom?, value} ->
        {if(atom?, do: String.to_atom(name), else: name), value}
      end)
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
