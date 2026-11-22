defmodule Durable.Fuzz.Audit4EngineStateTest do
  @moduledoc """
  The engine keeps its own state for a run under names of its own, and a run's
  data comes from outside. This plays one order twice: once as it is, and once
  with every one of the engine's names, as a string and as an atom, in
  everything the user's side of a run can hand the engine: the start's input, each
  step's result, `put_context`, `merge_context` and `update_context`, an
  event's payload, an input's answer, a parallel block's `into:`, and a child
  workflow's input and result. The values are what the engine would act on if
  it read them (a failure, a rollback, a finished step, a child's result, a
  block's lanes) or just hostile.

  The order sleeps, waits for an event and an input, takes a branch, runs a
  parallel block with a lane that waits, calls a child workflow, and ends
  completed, failed or rolled back. The two plays have to match: the same
  statuses, the same data, the same steps, the same engine state. And at no
  point does one of the engine's names show up in a step's data, come back
  from `get_context`, or sit in a stored context or a step's output.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Durable.Testing
  import Ecto.Query

  alias Durable.EngineState
  alias Durable.FuzzTerms
  alias Durable.Storage.Schemas.{StepExecution, WorkflowExecution}
  alias Durable.TestRepo
  alias Durable.Wait
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :fuzz
  @moduletag :capture_log
  @moduletag timeout: :infinity

  @runs String.to_integer(System.get_env("FUZZ_RUNS", "40"))

  @table :audit4_engine_state_fuzz
  @poison {__MODULE__, :poison}
  @forged "AUDIT4-ES-FORGED"
  @uuid ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/

  # Every name of the engine's, with the refs and ids this workflow would use.
  @names EngineState.keys() ++
           ~w(__child:charge __child_done:charge __fire_forget:charge __parallel_done:x) ++
           ["__child_done:6f1c2a52-3d0a-4c58-9d0e-0a8d6c1f2b11"]

  @atoms Enum.map(@names, &String.to_atom/1)

  # A sandbox and an instance for each case, as in the other inline fuzzes.
  defp isolated(fun) do
    owner = Sandbox.start_owner!(TestRepo, shared: true)
    start_supervised!({Durable, repo: TestRepo, queue_enabled: false}, id: :audit4_es_durable)

    try do
      fun.()
    after
      stop_supervised!(:audit4_es_durable)
      Sandbox.stop_owner(owner)
    end
  end

  setup_all do
    :ets.new(@table, [:named_table, :public, :bag])
    on_exit(fn -> :persistent_term.erase(@poison) end)
    :ok
  end

  # ===========================================================================
  # What the steps do with the user's side of the run
  # ===========================================================================

  def poison, do: :persistent_term.get(@poison, %{})
  def hit(label), do: :ets.insert(@table, {:hit, label})

  @doc "Notes any name of the engine's that a step can see, in its data or its context."
  def seen(data) do
    context = Durable.Context.context()

    visible =
      Enum.filter(Map.keys(data) ++ Map.keys(context), &EngineState.key?/1) ++
        Enum.filter(@names ++ @atoms, &(Durable.Context.get_context(&1) != nil))

    if visible != [], do: :ets.insert(@table, {:visible, Durable.Context.current_step(), visible})
    data
  end

  @doc "Puts the poison everywhere a step's body can put data, and hands it back in the data."
  def dirty(data) do
    seen(data)
    poison = poison()

    Durable.Context.put_context(poison)
    Durable.Context.merge_context(poison)

    for {key, value} <- poison do
      Durable.Context.put_context(key, value)
      Durable.Context.update_context(key, fn _ -> value end)
    end

    seen(data)
    Map.merge(data, poison)
  end

  # A wait's answer, merged into the step's data at the top: a cancelled wait
  # has none.
  def as_map(%{} = answer), do: answer
  def as_map(_cancelled), do: %{}

  def kind(%{}), do: "answered"
  def kind(other), do: inspect(other)

  def describe(results),
    do: results |> Enum.sort() |> inspect(limit: :infinity, printable_limit: :infinity)

  defmodule Audit4EsCharge do
    use Durable
    use Durable.Wait

    alias Durable.Fuzz.Audit4EngineStateTest, as: T

    workflow "audit4_es_charge" do
      step(:charge, fn payment ->
        T.hit(:charge_started)
        payment = T.dirty(payment)
        confirmed = wait_for_event("bank_confirmed")

        {:ok,
         payment
         |> Map.merge(T.as_map(confirmed))
         |> Map.put("bank", T.kind(confirmed))}
      end)

      step(:receipt, fn payment -> {:ok, payment |> T.dirty() |> Map.put("paid", true)} end)
    end
  end

  defmodule Audit4EsOrder do
    use Durable
    use Durable.Wait
    use Durable.Orchestration

    alias Durable.Fuzz.Audit4EngineStateTest, as: T
    alias Durable.Fuzz.Audit4EngineStateTest.Audit4EsCharge

    workflow "audit4_es_order" do
      step(:intake, fn order ->
        T.hit(:intake)
        {:ok, T.dirty(order)}
      end)

      step(:reserve_stock, [compensate: :release_stock], fn order ->
        T.hit(:reserved)
        {:ok, order |> T.dirty() |> Map.put("reserved", true)}
      end)

      step(:cool_off, fn order ->
        order = T.dirty(order)
        sleep(60_000)
        T.hit(:cooled_off)
        {:ok, Map.put(order, "cooled_off", true)}
      end)

      step(:await_payment_method, fn order ->
        order = T.dirty(order)
        method = wait_for_event("method_chosen")
        T.hit(:method)
        {:ok, order |> Map.merge(T.as_map(method)) |> Map.put("method", T.kind(method))}
      end)

      step(:approve, fn order ->
        order = T.dirty(order)
        answer = wait_for_input("approval")
        T.hit(:approved)
        {:ok, order |> Map.merge(T.as_map(answer)) |> Map.put("approval", T.kind(answer))}
      end)

      branch on: fn order -> order["route"] end do
        "express" ->
          step(:book_courier, fn order ->
            T.hit(:courier)
            {:ok, order |> T.dirty() |> Map.put("by", "courier")}
          end)

        _ ->
          step(:post, fn order ->
            T.hit(:post)
            {:ok, order |> T.dirty() |> Map.put("by", "post")}
          end)
      end

      parallel :lookups,
        into: fn order, results ->
          {:ok, order |> Map.merge(T.poison()) |> Map.put("lookups", T.describe(results))}
        end do
        step(:stock, fn order ->
          order = T.dirty(order)
          counted = wait_for_event("stock_counted")
          T.hit(:stock)
          {:ok, order |> Map.merge(T.as_map(counted)) |> Map.put("stock", T.kind(counted))}
        end)

        step(:address, fn order ->
          T.hit(:address)
          {:ok, order |> T.dirty() |> Map.put("address", "found")}
        end)
      end

      step(:charge, fn order ->
        order = T.dirty(order)
        payment = Map.merge(%{"amount" => 5}, T.poison())

        case call_workflow(Audit4EsCharge, payment, ref: :charge) do
          {:ok, paid} -> {:ok, order |> Map.merge(paid) |> Map.put("charged", true)}
          {:error, reason} -> {:error, reason}
        end
      end)

      step(:dispatch, fn order ->
        order = T.dirty(order)
        T.hit(:dispatch)

        case order["plan"] do
          "rollback" -> {:rollback, "nothing left to send"}
          "fail" -> {:error, "the depot is closed"}
          _ -> {:ok, Map.put(order, "dispatched", true)}
        end
      end)

      compensate(:release_stock, fn order ->
        T.hit(:released)
        T.seen(order)
        {:ok, order}
      end)
    end
  end

  # ===========================================================================
  # Generators
  # ===========================================================================

  # What the engine would act on, if it read this under `name`.
  defp forged("__fail__"), do: %{"type" => "rollback", "message" => @forged}
  defp forged("__rollback__"), do: %{"error" => %{"type" => @forged}, "status" => "cancelled"}
  defp forged("__done__"), do: %{"step" => "approve", "arm" => "dispatch", "by" => @forged}
  defp forged("__string_keys__"), do: ["plan", @forged]
  defp forged("__atom_keys__"), do: ["plan", "route", @forged]
  defp forged("__parallel_step"), do: "lookups__stock"
  defp forged("__parallel_wait_group_id"), do: Ecto.UUID.generate()
  defp forged("__parallel_error_strategy"), do: "fail_fast"
  defp forged("__sleep_satisfied__"), do: "cool_off"
  defp forged("__timeout__"), do: true
  defp forged("__cancelled__"), do: @forged
  defp forged("__wait_group_result__"), do: ["timeout", %{"x" => @forged}]
  defp forged("__wait_group_status__"), do: %{"method_chosen" => %{"status" => "timeout"}}

  defp forged("__parallel_children") do
    %{Ecto.UUID.generate() => %{"returns_key" => "audit4_es_forged", "step_name" => "stock"}}
  end

  defp forged("__call_children") do
    %{Ecto.UUID.generate() => %{"step_name" => "charge", "kind" => "call", "ref" => @forged}}
  end

  defp forged("__child:" <> _ref), do: Ecto.UUID.generate()
  defp forged("__fire_forget:" <> _ref), do: Ecto.UUID.generate()

  defp forged("__child_done:" <> _ref),
    do: %{"status" => "completed", "result" => %{"paid" => true, "forged" => @forged}}

  defp forged("__parallel_done:" <> _id), do: %{"status" => "completed", "result" => @forged}

  defp value(name), do: one_of([constant(forged(name)), FuzzTerms.nasty_term()])

  # Every name, as a string and as an atom.
  defp poisons do
    gen all(
          strings <- fixed_map(Map.new(@names, &{&1, value(&1)})),
          atoms <- fixed_map(Map.new(@names, &{String.to_atom(&1), value(&1)}))
        ) do
      Map.merge(strings, atoms)
    end
  end

  # The user's own data. The engine's names nested inside it are the user's
  # too, and stay where they are.
  defp nested do
    gen all(
          inner <- map_of(member_of(@names ++ @atoms), FuzzTerms.nasty_term(), max_length: 4),
          note <- string(:alphanumeric, max_length: 8)
        ) do
      %{"note" => note, "inner" => inner}
    end
  end

  defp scenario do
    gen all(
          plan <- member_of(["send", "rollback", "fail"]),
          route <- member_of(["express", "standard"]),
          answers <-
            fixed_map(
              Map.new(
                ~w(method_chosen approval stock_counted bank_confirmed),
                &{&1, frequency([{4, constant(:answer)}, {1, constant(:cancel)}])}
              )
            ),
          details <- nested()
        ) do
      %{plan: plan, route: route, answers: answers, details: details}
    end
  end

  # ===========================================================================
  # Playing a run
  # ===========================================================================

  defp tree(run) do
    TestRepo.all(
      from(w in WorkflowExecution,
        where: w.id == ^run.id or w.root_workflow_id == ^run.id,
        order_by: w.inserted_at
      )
    )
  end

  # No name of the engine's in anything stored as the user's data, and nothing
  # forged in what is stored as the engine's.
  defp check_stored!(run, where) do
    runs = tree(run)
    ids = Enum.map(runs, & &1.id)

    for stored <- runs do
      assert Enum.filter(Map.keys(stored.context), &EngineState.key?/1) == [],
             "#{where}: the engine's names in the context of #{stored.workflow_name}"

      refute inspect(stored.engine_state, limit: :infinity) =~ @forged,
             "#{where}: forged engine state on #{stored.workflow_name}: " <>
               inspect(stored.engine_state)

      refute inspect(stored.context, limit: :infinity) =~ @forged
    end

    outputs =
      TestRepo.all(from(s in StepExecution, where: s.workflow_id in ^ids, select: s.output))

    for %{} = output <- outputs do
      assert Enum.filter(Map.keys(output), &EngineState.key?/1) == [],
             "#{where}: the engine's names in a step's output"
    end

    runs
  end

  # An event or an input under one of the engine's names, a lane's or a child's
  # finish among them, reaches no run.
  defp try_the_engines_names!(runs, poison) do
    ids = Enum.map(runs, & &1.id)

    names =
      @names ++ Enum.flat_map(ids, &["__parallel_done:#{&1}", "__child_done:#{&1}"])

    for id <- ids, name <- names do
      assert Durable.send_event(id, name, poison) == {:error, :not_found}
      assert Durable.send_event(id, name, poison, buffer: true) == {:error, :not_found}
      assert Durable.provide_input(id, name, poison) == {:error, :not_found}
    end
  end

  defp waits(ids) do
    events =
      for wait <- Wait.list_pending_events(limit: 200),
          wait.workflow_id in ids and not EngineState.key?(wait.event_name),
          do: {:event, wait.workflow_id, wait.event_name}

    inputs =
      for wait <- Wait.list_pending_inputs(limit: 200),
          wait.workflow_id in ids,
          do: {:input, wait.workflow_id, wait.input_name}

    events ++ inputs
  end

  defp answer({kind, id, name}, scenario, poison) do
    payload = Map.merge(%{"#{name}_details" => scenario.details}, poison)

    case {scenario.answers[name], kind} do
      {:cancel, _kind} -> assert Wait.cancel_wait(id, reason: "withdrawn") == :ok
      {:answer, :event} -> assert Durable.send_event(id, name, payload) == :ok
      {:answer, :input} -> assert Durable.provide_input(id, name, payload) == :ok
    end
  end

  defp advance(run, _scenario, _poison, 0), do: run

  defp advance(%{status: :waiting} = run, scenario, poison, rounds) do
    runs = check_stored!(run, "while waiting")
    try_the_engines_names!(runs, poison)

    case waits(Enum.map(runs, & &1.id)) do
      [] ->
        run

      waits ->
        Enum.each(waits, &answer(&1, scenario, poison))
        advance(drain(run), scenario, poison, rounds - 1)
    end
  end

  defp advance(run, _scenario, _poison, _rounds), do: run

  # The same ids never come round twice, so they are taken out to compare.
  defp plain(%{} = map) when not is_struct(map),
    do: map |> Enum.map(fn {key, value} -> {plain(key), plain(value)} end) |> Enum.sort()

  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(text) when is_binary(text), do: Regex.replace(@uuid, text, "<id>")
  defp plain(other), do: other

  defp play(scenario, poison) do
    :ets.delete_all_objects(@table)
    :persistent_term.put(@poison, poison)

    input =
      Map.merge(
        %{"plan" => scenario.plan, "route" => scenario.route, "details" => scenario.details},
        poison
      )

    run =
      Audit4EsOrder
      |> run_workflow(input, workflow: "audit4_es_order")
      |> advance(scenario, poison, 12)

    runs = check_stored!(run, "at the end")
    ids = Enum.map(runs, & &1.id)

    steps =
      TestRepo.all(
        from(s in StepExecution,
          join: w in WorkflowExecution,
          on: w.id == s.workflow_id,
          where: s.workflow_id in ^ids,
          order_by: [s.inserted_at, s.step_name],
          select: {w.workflow_name, s.step_name, s.status, s.attempt}
        )
      )

    %{
      status: run.status,
      error: run.error,
      context: run.context,
      compensations: run.compensation_results,
      runs:
        for stored <- runs do
          {stored.workflow_name, stored.status, stored.current_step, stored.context,
           plain(stored.engine_state), plain(stored.error)}
        end,
      steps: steps,
      hits: @table |> :ets.lookup(:hit) |> Enum.frequencies(),
      visible: :ets.match_object(@table, {:visible, :_, :_})
    }
  end

  defp ending("send"), do: :completed
  defp ending("fail"), do: :failed
  defp ending("rollback"), do: :compensated

  property "a run handed the engine's own names in everything of the user's goes as it would without them" do
    check all(scenario <- scenario(), poison <- poisons(), max_runs: @runs) do
      {clean, poisoned} =
        isolated(fn -> {play(scenario, %{}), play(scenario, poison)} end)

      assert clean.visible == [], "a step saw the engine's names: #{inspect(clean.visible)}"
      assert poisoned.visible == [], "a step saw the engine's names: #{inspect(poisoned.visible)}"

      assert clean.status == ending(scenario.plan),
             "ended #{clean.status}: #{inspect(clean.error)}"

      assert poisoned.status == clean.status,
             "poisoned, it ended #{poisoned.status}: #{inspect(poisoned.error)}"

      assert poisoned.context == clean.context
      assert poisoned.hits == clean.hits
      assert poisoned.steps == clean.steps
      assert poisoned == clean
    end
  end
end
