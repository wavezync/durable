defmodule Durable.Testing do
  @moduledoc """
  Helpers for testing workflows.

  Runs execute inline in the test process, with no queue or pollers, so they
  share the test's Ecto sandbox. `drain/2` keeps running a workflow and every
  run it spawns until nothing is left to do. Sleeps end immediately and
  retries skip their backoff.

  ## Setup

  Turn queue processing off in `config/test.exs`, so pollers don't race the
  test for the same runs:

      config :durable, disable_queue_processing: true

  Then import the helpers where you test workflows, for example in your
  `DataCase`:

      import Durable.Testing

  ## Example

      test "charges the order" do
        run = run_workflow(OrderWorkflow, %{"order_id" => 42})

        assert_status(run, :completed)
        assert_step(run, :charge)
        assert %{"charged" => true} = run.context
      end

  A waiting run is resumed with the regular API, then drained:

      run = run_workflow(ApprovalWorkflow, %{})
      assert_waiting_for_input(run, "manager_approval")

      :ok = Durable.provide_input(run.id, "manager_approval", %{"approved" => true})

      run
      |> drain()
      |> assert_status(:completed)

  Every function takes a `:durable` option that names the Durable instance
  (default `Durable`). Runs can be passed as a `%WorkflowExecution{}`, a map
  with an `:id`, or the id itself.
  """

  import Ecto.Query
  import ExUnit.Assertions, only: [flunk: 1]

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Queue.Adapter
  alias Durable.Repo
  alias Durable.Storage.Schemas.{PendingEvent, PendingInput, StepExecution, WorkflowExecution}

  @max_rounds 100

  @doc """
  Starts the workflow in `module` with `input` and drains it. Returns the run
  as a `%WorkflowExecution{}`, finished or waiting.

  Takes the same options as `Durable.start/3`.
  """
  @spec run_workflow(module(), map(), keyword()) :: WorkflowExecution.t()
  def run_workflow(module, input \\ %{}, opts \\ []) do
    case Durable.start(module, input, opts) do
      {:ok, id} ->
        drain(id, opts)

      {:error, reason} ->
        raise ArgumentError, "can't start #{inspect(module)}: #{inspect(reason)}"
    end
  end

  @doc """
  Runs every pending execution in the run's tree (the run, its parallel
  branches and its child workflows) until none is left, then returns the
  reloaded run.

  Sleeps end immediately and retries skip their backoff. Use it after
  `Durable.provide_input/3` or `Durable.send_event/3`.
  """
  @spec drain(WorkflowExecution.t() | map() | String.t(), keyword()) :: WorkflowExecution.t()
  def drain(run, opts \\ []) do
    config = config(opts)
    id = run_id(run)

    if config.queue_enabled do
      raise ArgumentError, """
      Durable.Testing.drain/2 needs queue processing off, or queue workers race \
      the test for the same runs. Add `config :durable, disable_queue_processing: true` \
      to config/test.exs, or start Durable with `queue_enabled: false`.
      """
    end

    previous = Process.put(:durable_skip_backoff, true)

    try do
      drain_rounds(config, id, @max_rounds)
    after
      Process.put(:durable_skip_backoff, previous)
    end

    Repo.get(config, WorkflowExecution, id)
  end

  defp drain_rounds(_config, id, 0),
    do: flunk("Workflow run #{id} still had work after #{@max_rounds} drain rounds")

  defp drain_rounds(config, id, rounds) do
    ids = tree_ids(config, [id])
    wake_sleepers(config, ids)

    pending =
      Repo.all(
        config,
        from(w in WorkflowExecution,
          where: w.id in ^ids and w.status == :pending,
          order_by: w.inserted_at,
          select: w.id
        )
      )

    if pending != [] do
      Enum.each(pending, &Executor.execute_workflow(&1, config))
      drain_rounds(config, id, rounds - 1)
    end
  end

  defp tree_ids(config, ids) do
    children =
      Repo.all(
        config,
        from(w in WorkflowExecution,
          where: w.parent_workflow_id in ^ids and w.id not in ^ids,
          select: w.id
        )
      )

    if children == [], do: ids, else: tree_ids(config, ids ++ children)
  end

  # Back-dates the tree's sleeps so the adapter's wake sweep, which takes the
  # oldest first, wakes exactly these rows.
  defp wake_sleepers(config, ids) do
    sleeping =
      from(w in WorkflowExecution,
        where: w.id in ^ids and w.status == :waiting and not is_nil(w.scheduled_at)
      )

    case Repo.update_all(config, sleeping, set: [scheduled_at: ~U[2000-01-01 00:00:00.000000Z]]) do
      {0, _} -> :ok
      {count, _} -> {:ok, _} = Adapter.default_adapter().wake_sleeping_workflows(config, count)
    end
  end

  @doc """
  Returns the run's step executions, oldest first, including the steps its
  parallel blocks ran. There is one row per attempt, and a step that waited
  has one more row for the run after it resumed.
  """
  @spec steps(WorkflowExecution.t() | map() | String.t(), keyword()) :: [StepExecution.t()]
  def steps(run, opts \\ []) do
    config = config(opts)
    root = Repo.get(config, WorkflowExecution, run_id(run))

    branches =
      from(w in WorkflowExecution,
        where:
          w.parent_workflow_id == ^root.id and w.workflow_module == ^root.workflow_module and
            w.workflow_name == ^root.workflow_name,
        select: w.id
      )

    Repo.all(
      config,
      from(s in StepExecution,
        where: s.workflow_id == ^root.id or s.workflow_id in subquery(branches),
        order_by: [asc: s.inserted_at]
      )
    )
  end

  @doc """
  Asserts the run's status, such as `:completed`, `:failed` or `:waiting`. On
  a mismatch the failure shows the run's current step and error.

  Returns the reloaded run.
  """
  @spec assert_status(WorkflowExecution.t() | map() | String.t(), atom(), keyword()) ::
          WorkflowExecution.t()
  def assert_status(run, expected, opts \\ []) do
    run = Repo.get(config(opts), WorkflowExecution, run_id(run))

    if run.status != expected do
      flunk("""
      Expected workflow run #{run.id} to be #{inspect(expected)}, got #{inspect(run.status)}
      current step: #{inspect(run.current_step)}
      error: #{inspect(run.error, pretty: true)}
      """)
    end

    run
  end

  @doc """
  Asserts that the step's latest attempt ended with `status`
  (default `:completed`). Steps inside `parallel` and `branch` blocks are
  matched by their own name, so it also checks which branch ran.

  Returns that `%StepExecution{}`, so its `output`, `error` and `attempt` can
  be checked as well:

      assert assert_step(run, :charge).attempt == 3
  """
  @spec assert_step(WorkflowExecution.t() | map() | String.t(), atom(), atom(), keyword()) ::
          StepExecution.t()
  def assert_step(run, step, status \\ :completed, opts \\ []) when is_atom(status) do
    all = steps(run, opts)
    name = to_string(step)

    case all |> Enum.filter(&(short_name(&1) == name)) |> List.last() do
      nil ->
        ran = all |> Enum.map(&short_name/1) |> Enum.uniq()
        flunk("Step #{inspect(step)} never ran. Steps that ran: #{inspect(ran)}")

      %StepExecution{status: ^status} = latest ->
        latest

      latest ->
        flunk("""
        Expected step #{inspect(step)} to be #{inspect(status)}, got #{inspect(latest.status)} \
        (attempt #{latest.attempt})
        error: #{inspect(latest.error, pretty: true)}
        """)
    end
  end

  # Steps inside parallel and branch blocks are stored qualified, such as
  # "parallel_123__email" or "branch_456__digital__ship".
  defp short_name(%StepExecution{step_name: name}),
    do: name |> String.split("__") |> List.last()

  @doc """
  Asserts that the run is waiting for the input named `input_name`. Returns the
  `%PendingInput{}`.
  """
  @spec assert_waiting_for_input(
          WorkflowExecution.t() | map() | String.t(),
          String.t(),
          keyword()
        ) ::
          PendingInput.t()
  def assert_waiting_for_input(run, input_name, opts \\ []) do
    assert_pending(PendingInput, :input_name, run, input_name, opts)
  end

  @doc """
  Asserts that the run is waiting for the event named `event_name`. Returns the
  `%PendingEvent{}`.
  """
  @spec assert_waiting_for_event(
          WorkflowExecution.t() | map() | String.t(),
          String.t(),
          keyword()
        ) ::
          PendingEvent.t()
  def assert_waiting_for_event(run, event_name, opts \\ []) do
    assert_pending(PendingEvent, :event_name, run, event_name, opts)
  end

  defp assert_pending(schema, field, run, name, opts) do
    id = run_id(run)

    pending =
      Repo.all(
        config(opts),
        from(p in schema, where: p.workflow_id == ^id and p.status == :pending)
      )

    Enum.find(pending, &(Map.fetch!(&1, field) == name)) ||
      flunk("""
      Expected workflow run #{id} to wait for #{inspect(name)}
      it waits for: #{inspect(Enum.map(pending, &Map.fetch!(&1, field)))}
      """)
  end

  @doc """
  Returns the runs of the workflow in `module` that were started, oldest
  first. With queue processing off, nothing runs them, so this checks what
  code started without running the workflow:

      Orders.place(order)
      assert [run] = all_started(Fulfilment)
      assert run.input == %{"order_id" => 42}

  Parallel branches aren't included; child workflows are.

  ## Options

  - `:input` - only runs whose input contains this map. `%{"order_id" => 42}`
    matches an input that has more keys too
  - `:key` - only runs started with this `key:`
  - `:durable` - the Durable instance (default `Durable`)
  """
  @spec all_started(module(), keyword()) :: [WorkflowExecution.t()]
  def all_started(module, opts \\ []) do
    opts = Keyword.validate!(opts, [:input, :key, :durable])

    # A branch is a run whose parent runs the same workflow, as in steps/2.
    # ponytail: a workflow that call_workflows itself looks like a branch too.
    branch_parent =
      from(p in WorkflowExecution,
        where:
          p.id == parent_as(:run).parent_workflow_id and
            p.workflow_module == parent_as(:run).workflow_module and
            p.workflow_name == parent_as(:run).workflow_name
      )

    query =
      from(w in WorkflowExecution,
        as: :run,
        where: w.workflow_module == ^Atom.to_string(module),
        where: not exists(branch_parent),
        order_by: [asc: w.inserted_at]
      )

    query =
      Enum.reduce(opts, query, fn
        {:input, input}, q -> where(q, [w], fragment("? @> ?", w.input, type(^input, :map)))
        {:key, key}, q -> where(q, [w], w.key == ^key)
        {:durable, _}, q -> q
      end)

    Repo.all(config(opts), query)
  end

  @doc """
  Asserts that a run of the workflow in `module` was started, matching the
  `:input` and `:key` options of `all_started/2`. Returns the oldest match,
  which can then be drained:

      Orders.place(order)

      assert_started(Fulfilment, input: %{"order_id" => 42}, key: "order:42")
      |> drain()
      |> assert_status(:completed)
  """
  @spec assert_started(module(), keyword()) :: WorkflowExecution.t()
  def assert_started(module, opts \\ []) do
    case all_started(module, opts) do
      [run | _] ->
        run

      [] ->
        flunk("""
        Expected a run of #{inspect(module)} to be started#{filters(opts)}
        #{started_list(module, opts)}
        """)
    end
  end

  @doc """
  Asserts that no run of the workflow in `module` was started, matching the
  `:input` and `:key` options of `all_started/2`.
  """
  @spec refute_started(module(), keyword()) :: :ok
  def refute_started(module, opts \\ []) do
    case all_started(module, opts) do
      [] ->
        :ok

      runs ->
        flunk("""
        Expected no run of #{inspect(module)} to be started#{filters(opts)}, got #{length(runs)}
        #{Enum.map_join(runs, "\n", &describe_started/1)}
        """)
    end
  end

  defp filters(opts) do
    case Keyword.take(opts, [:input, :key]) do
      [] -> ""
      filters -> " with " <> inspect(filters)
    end
  end

  defp started_list(module, opts) do
    case all_started(module, Keyword.take(opts, [:durable])) do
      [] -> "No run of #{inspect(module)} was started."
      runs -> "Runs that were started:\n" <> Enum.map_join(runs, "\n", &describe_started/1)
    end
  end

  defp describe_started(run),
    do: "  #{run.id} key: #{inspect(run.key)} input: #{inspect(run.input)}"

  defp config(opts), do: Config.get(Keyword.get(opts, :durable, Durable))

  defp run_id(%{id: id}), do: id
  defp run_id(id) when is_binary(id), do: id
end
