defmodule Durable.EngineState do
  @moduledoc false
  # The engine's own state for a run: what it has done, what it waits on, how
  # it is to resume. It lives in `workflow_executions.engine_state`, under the
  # names below, and nowhere else.
  #
  # A run's `context` is the user's data. It comes from outside (a start's
  # input, a step's result, an event's payload), so the engine never reads its
  # state from there, and `strip/1` drops these names from the user's data
  # wherever it comes in.
  #
  # Before the column, the state was kept in the context under the same names.
  # A row is in that layout until an engine with the column has written it,
  # which leaves its mark (`"v"`): `adopt/2` moves an unmarked row's state out
  # of its context once, as the migration does for the runs that are over. A
  # row that has the mark never has its context read for state again.

  import Ecto.Query, only: [from: 2]

  alias Durable.Config
  alias Durable.Storage.Schemas.WorkflowExecution

  @keys ~w(
    __fail__ __rollback__ __done__ __string_keys__ __atom_keys__ __atom_twins__
    __parallel_step __parallel_children __parallel_wait_group_id __parallel_error_strategy
    __sleep_satisfied__ __timeout__ __cancelled__ __wait_group_result__ __wait_group_status__
    __call_children
  )

  # Followed by a ref or a run's id.
  @prefixes ~w(__child: __child_done: __fire_forget: __parallel_done: __dropped:)

  # Followed by an attempt's row id: the keys that attempt's body deleted from
  # the context, written just before its row is completed. Read only by a run
  # that takes that row's result (`Executor.finished_before_lost/5`), and gone
  # at the next save. Named by the row, so one attempt's never stands in for,
  # or overwrites, another's.
  @dropped "__dropped:"

  @doc "The name the keys an attempt deleted are kept under."
  @spec dropped_key(String.t()) :: String.t()
  def dropped_key(row_id), do: @dropped <> row_id

  @doc "The state without what any attempt deleted."
  @spec without_dropped(map()) :: map()
  def without_dropped(state),
    do: Map.reject(state, fn {key, _value} -> String.starts_with?(key, @dropped) end)

  # What a resume leaves for the step that waited, to read through the wait
  # itself. They don't outlast the step.
  @wait_markers ~w(__sleep_satisfied__ __timeout__ __cancelled__ __wait_group_result__ __wait_group_status__)

  # A lane starts with the children its block's run has already started, so a
  # `call_workflow` under the same ref gets the same child.
  @inherited ~w(__child: __child_done: __fire_forget:)

  @mark "v"
  @process_key :durable_engine_state

  @doc "Every engine key that is a whole name."
  @spec keys() :: [String.t()]
  def keys, do: @keys

  @doc "The engine keys that are a prefix, followed by a ref or a run's id."
  @spec prefixes() :: [String.t()]
  def prefixes, do: @prefixes

  @doc "Whether a key of the user's, an atom or a string, is one of the engine's."
  @spec key?(term()) :: boolean()
  def key?(key) when is_binary(key),
    do: String.starts_with?(key, "__") and (key in @keys or String.starts_with?(key, @prefixes))

  def key?(key) when is_atom(key), do: key?(Atom.to_string(key))
  def key?(_key), do: false

  @doc "The user's data without the engine's keys. Only top-level keys are ever read."
  @spec strip(term()) :: term()
  def strip(data) when is_map(data) and not is_struct(data),
    do: Map.reject(data, fn {key, _value} -> key?(key) end)

  def strip(data), do: data

  @doc "The state of a run that has none yet, with this layout's mark."
  @spec new() :: map()
  def new, do: %{@mark => 1}

  @doc "The state without what a resume left for the step that waited."
  @spec without_wait_markers(map()) :: map()
  def without_wait_markers(state), do: Map.drop(state, @wait_markers)

  @doc "What a lane's run starts with of its block's run's state."
  @spec inherited(map()) :: map()
  def inherited(state),
    do: Map.filter(state, fn {key, _value} -> String.starts_with?(key, @inherited) end)

  # ============================================================================
  # The running step's view
  # ============================================================================

  # A step's body reads the state through its process (what its wait was
  # answered with) and writes to it (the children it started). The executor
  # puts it there as the step starts and takes it back as the step ends. It is
  # never in the step's data.

  @doc false
  @spec current() :: map()
  def current, do: Process.get(@process_key, %{})

  @doc false
  @spec put_current(map()) :: :ok
  def put_current(state) do
    Process.put(@process_key, state)
    :ok
  end

  @doc false
  @spec put_current(String.t(), term()) :: :ok
  def put_current(key, value), do: put_current(Map.put(current(), key, value))

  @doc false
  @spec clear_current() :: :ok
  def clear_current do
    Process.delete(@process_key)
    :ok
  end

  # ============================================================================
  # Rows from before the column
  # ============================================================================

  @doc """
  Whether a run in a query is marked with `key`, a pinned string. The context
  counts only for a row no engine with the column has written.
  """
  defmacro marked?(run, key) do
    quote do
      fragment(
        "(? \\? ? OR (NOT ? \\? 'v' AND ? \\? ?))",
        unquote(run).engine_state,
        unquote(key),
        unquote(run).engine_state,
        unquote(run).context,
        unquote(key)
      )
    end
  end

  @doc """
  A run as this layout has it. One an engine from before the column wrote last
  has its state taken out of its context, over what the migration moved.
  """
  @spec adopted(WorkflowExecution.t()) :: WorkflowExecution.t()
  def adopted(%{engine_state: %{@mark => _}} = run), do: run

  def adopted(run) do
    {state, context} = Map.split_with(run.context || %{}, fn {key, _value} -> key?(key) end)

    %{
      run
      | context: context,
        engine_state: (run.engine_state || %{}) |> Map.merge(state) |> Map.put(@mark, 1)
    }
  end

  @doc """
  `adopted/1`, written to the row if it is still unmarked. Takes the config, or
  the repo inside a transaction's function.
  """
  @spec adopt(Config.t() | module(), WorkflowExecution.t() | nil) :: WorkflowExecution.t() | nil
  def adopt(_repo, nil), do: nil
  def adopt(_repo, %{engine_state: %{@mark => _}} = run), do: run

  def adopt(repo, run) do
    adopted = adopted(run)

    unmarked =
      from(w in WorkflowExecution,
        where: w.id == ^run.id and not fragment("? \\? 'v'", w.engine_state)
      )

    updates = [set: [context: adopted.context, engine_state: adopted.engine_state]]

    case repo do
      %Config{} = config -> Durable.Repo.update_all(config, unmarked, updates)
      repo -> repo.update_all(unmarked, updates)
    end

    adopted
  end
end
