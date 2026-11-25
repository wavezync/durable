defmodule Durable.ReadFunctions do
  @moduledoc false
  # Every public read function, with what it takes, in order. Each returns
  # `{:ok, result}` or `{:error, reason}` and has a `!` twin (Durable.Query.Opts).
  #
  # The contract test and the fuzz test call everything listed here, and the
  # contract test fails when a module has a read function this list leaves out:
  # a new one goes here.

  alias Durable.Activity
  alias Durable.Query
  alias Durable.Scheduler.API
  alias Durable.Stats
  alias Durable.Wait

  @doc "The modules whose read functions are listed."
  def modules, do: [Durable, Query, Stats, Activity, Wait, API]

  @doc "Of those, the ones every public function of is a read function."
  def read_only_modules, do: [Query, Stats]

  @doc """
  `{module, function, arguments}`. An argument is `:id` (a run's), `:ids`,
  `:step` (a step's name), `:name` (a schedule's), `:schedule`, `:count` or
  `:opts`.
  """
  def all do
    [
      {Durable, :get_execution, [:id, :opts]},
      {Durable, :list_executions, [:opts]},
      {Durable, :list_children, [:id, :opts]},
      {Durable, :rollback_plan, [:id, :opts]},
      {Durable, :paused_queues, [:opts]},
      {Durable, :list_nodes, [:opts]},
      {Durable, :list_schedules, [:opts]},
      {Durable, :get_schedule, [:name, :opts]},
      {Query, :get_execution, [:id, :opts]},
      {Query, :list_executions, [:opts]},
      {Query, :list_executions_with_total, [:opts]},
      {Query, :count_executions, [:opts]},
      {Query, :count_by_status, [:opts]},
      {Query, :list_keys, [:opts]},
      {Query, :count_keys, [:opts]},
      {Query, :get_step_executions, [:id, :opts]},
      {Query, :get_step_logs, [:id, :step, :opts]},
      {Query, :list_child_executions, [:id, :opts]},
      {Query, :child_counts, [:ids, :opts]},
      {Query, :dashboard_counts, [:opts]},
      {Query, :list_workflows, [:opts]},
      {Stats, :overview, [:opts]},
      {Stats, :timeline, [:opts]},
      {Stats, :error_groups, [:opts]},
      {Stats, :failing_workflows, [:opts]},
      {Stats, :workflows, [:opts]},
      {Stats, :step_performance, [:opts]},
      {Stats, :queues, [:opts]},
      {Stats, :queue_history, [:opts]},
      {Stats, :keys, [:opts]},
      {Activity, :list, [:opts]},
      {Wait, :list_pending_inputs, [:opts]},
      {Wait, :list_pending_events, [:opts]},
      {API, :list_schedules, [:opts]},
      {API, :get_schedule, [:name, :opts]},
      {API, :upcoming_runs, [:schedule, :count]}
    ]
  end

  @doc "The `!` twin's name."
  def bang(name), do: :"#{name}!"

  @doc "A short name for a test: `Durable.Query.list_keys/1`."
  def label({module, name, args}), do: "#{inspect(module)}.#{name}/#{length(args)}"
end
