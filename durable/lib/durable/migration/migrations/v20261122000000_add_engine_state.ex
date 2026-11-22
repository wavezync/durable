defmodule Durable.Migration.Migrations.V20261122000000AddEngineState do
  @moduledoc false
  # `workflow_executions.engine_state` holds the engine's own state for a run:
  # what it has done, what it waits on, how it is to resume. It used to be kept
  # in `context`, beside the user's data and under names the user's data could
  # use too.
  #
  # The state of runs that are over for good is moved to the new column here.
  # Every other run keeps it in its context for now: a node still on the old
  # code reads it from there, and has to be able to carry the run on until
  # that node stops. The first engine with the column to touch such a run
  # moves its state then (`Durable.EngineState.adopt/2`), and leaves its mark
  # (`"v"`) on the row. `down` moves all of it back.
  #
  # The update reads every row of `workflow_executions` and rewrites the
  # finished ones that have any state to move.
  #
  # The names are spelled out here, as they were when the state was in the
  # context. A row that carries the mark is left alone: nothing in its context
  # is the engine's.
  use Durable.Migration.Base

  @keys ~w(
    __fail__ __rollback__ __done__ __string_keys__ __atom_keys__
    __parallel_step __parallel_children __parallel_wait_group_id __parallel_error_strategy
    __sleep_satisfied__ __timeout__ __cancelled__ __wait_group_result__ __wait_group_status__
    __call_children
  )

  @prefixes ~w(__child: __child_done: __fire_forget: __parallel_done:)

  # No engine runs these again: a failed or cancelled run can be retried, or
  # put back with the block it was a lane of.
  @over ~w(completed compensated compensation_failed)

  @impl true
  def version, do: 20_261_122_000_000

  @impl true
  def up(prefix) do
    alter table(:workflow_executions, prefix: prefix) do
      add_if_not_exists(:engine_state, :map, null: false, default: %{})
    end

    # The column has to exist before the update is planned.
    flush()

    execute("""
    UPDATE #{prefix}.workflow_executions w
    SET engine_state = w.engine_state || moved.engine, context = moved.rest
    FROM (
      SELECT r.id,
             jsonb_object_agg(e.key, e.value) FILTER (WHERE #{engine_key("e.key")}) AS engine,
             coalesce(
               jsonb_object_agg(e.key, e.value) FILTER (WHERE NOT #{engine_key("e.key")}),
               '{}'::jsonb
             ) AS rest
      FROM #{prefix}.workflow_executions r,
           jsonb_each(CASE jsonb_typeof(r.context) WHEN 'object' THEN r.context ELSE '{}' END) e
      WHERE r.status IN (#{Enum.map_join(@over, ", ", &"'#{&1}'")})
        AND NOT r.engine_state ? 'v'
      GROUP BY r.id
      HAVING bool_or(#{engine_key("e.key")})
    ) moved
    WHERE w.id = moved.id
    """)

    :ok
  end

  @impl true
  def down(prefix) do
    execute("""
    UPDATE #{prefix}.workflow_executions
    SET context = context || (engine_state - 'v')
    WHERE engine_state - 'v' <> '{}'::jsonb
    """)

    alter table(:workflow_executions, prefix: prefix) do
      remove_if_exists(:engine_state, :map)
    end

    :ok
  end

  defp engine_key(column) do
    names = Enum.map_join(@keys, ", ", &"'#{&1}'")
    starts = Enum.map_join(@prefixes, " OR ", &"starts_with(#{column}, '#{&1}')")
    "(#{column} IN (#{names}) OR #{starts})"
  end
end
