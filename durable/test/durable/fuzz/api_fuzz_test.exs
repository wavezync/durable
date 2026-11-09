defmodule Durable.Fuzz.ApiTest do
  @moduledoc """
  The public API takes anything without an internal error, and a value that's
  the right type but nonsense is an answer, not a crash.
  """
  use Durable.IntegrationCase, tag: :fuzz
  use ExUnitProperties

  import Durable.FuzzTerms

  alias Durable.FuzzWorkflows.{Asks, Quick, Waits}
  alias Durable.Repo

  @moduletag :capture_log
  @moduletag timeout: :infinity

  @runs String.to_integer(System.get_env("FUZZ_RUNS", "60"))

  # For a value of the wrong type these say so, which is the caller's bug.
  @misuse [
    ArgumentError,
    FunctionClauseError,
    Protocol.UndefinedError,
    Ecto.Query.CastError,
    DBConnection.EncodeError
  ]

  @statuses [:pending, :running, :waiting, :completed, :failed, :cancelled]

  defp waiting(workflow) do
    {:ok, id} = Durable.start(workflow, %{})
    assert_eventually(fn -> get(id).status == :waiting end)
    id
  end

  # {name, the type the API documents, the call}
  defp calls(ctx) do
    [
      {"start input", :map, &Durable.start(Quick, &1)},
      {"start key", :string, &Durable.start(Quick, %{}, key: &1)},
      {"start tags", :strings, &Durable.start(Quick, %{}, tags: &1)},
      {"start queue", :string, &Durable.start(Quick, %{}, queue: &1)},
      {"start priority", :integer, &Durable.start(Quick, %{}, priority: &1)},
      {"start scheduled_at", :datetime, &Durable.start(Quick, %{}, scheduled_at: &1)},
      {"start_many", :never, &Durable.start_many(&1)},
      {"get_execution", :string, &Durable.get_execution/1},
      {"cancel id", :string, &Durable.cancel/1},
      {"cancel reason", :any, &Durable.cancel(ctx.running, &1)},
      {"retry", :string, &Durable.retry/1},
      {"rerun", :string, &Durable.rerun/1},
      {"release_key", :string, &Durable.release_key/1},
      {"list_children", :string, &Durable.list_children/1},
      {"send_event id", :string, &Durable.send_event(&1, "go", %{})},
      {"send_event name", :string, &Durable.send_event(ctx.waiting, &1, %{})},
      {"send_event buffered name", :string,
       &Durable.send_event(ctx.waiting, &1, %{}, buffer: true)},
      {"send_event buffered id", :string, &Durable.send_event(&1, "go", %{}, buffer: true)},
      {"provide_input id", :string, &Durable.provide_input(&1, "approve", %{})},
      {"provide_input name", :string, &Durable.provide_input(ctx.asking, &1, %{})},
      {"list workflow", :never, &Durable.list_executions(workflow: &1)},
      {"list status", :status, &Durable.list_executions(status: &1)},
      {"list queue", :string, &Durable.list_executions(queue: &1)},
      {"list key", :string, &Durable.list_executions(key: &1)},
      {"list tag", :string, &Durable.list_executions(tag: &1)},
      {"list limit", :integer, &Durable.list_executions(limit: &1)},
      {"cancel_all tag", :string, &Durable.cancel_all([tag: &1], "x")},
      {"cancel_all reason", :any, &Durable.cancel_all([tag: "no-such-tag"], &1)},
      {"pause_queue", :string, &Durable.pause_queue/1},
      {"resume_queue", :string, &Durable.resume_queue/1},
      {"schedule cron", :string, &Durable.schedule(Quick, &1, name: "fuzz")},
      {"get_schedule", :string, &Durable.get_schedule/1},
      {"delete_schedule", :string, &Durable.delete_schedule/1},
      {"trigger_schedule", :string, &Durable.trigger_schedule/1}
    ]
  end

  defp of_type?(value, :string), do: is_binary(value) and not Repo.bad_text?(value)
  defp of_type?(value, :strings), do: is_list(value) and Enum.all?(value, &of_type?(&1, :string))
  defp of_type?(value, :integer), do: is_integer(value) and abs(value) < 2 ** 31
  defp of_type?(value, :status), do: value in @statuses
  defp of_type?(_value, :never), do: false
  defp of_type?(value, :map), do: is_map(value) and not is_struct(value)
  defp of_type?(%DateTime{}, :datetime), do: true
  defp of_type?(_value, :datetime), do: false
  defp of_type?(_value, :any), do: true

  defp attempt(name, type, call, value) do
    call.(value)
    :ok
  rescue
    error ->
      unless error.__struct__ in @misuse and not of_type?(value, type) do
        flunk("""
        #{name} raised #{inspect(error.__struct__)} on #{inspect(value)}
        #{Exception.message(error)}
        #{Exception.format_stacktrace(__STACKTRACE__)}
        """)
      end
  end

  setup do
    start_durable!(%{default: 10})
    :ok
  end

  defp nasty_for(:string) do
    one_of([nasty_string(), constant(Ecto.UUID.generate()), constant("not-a-uuid"), nasty_term()])
  end

  defp nasty_for(:strings), do: one_of([list_of(nasty_string(), max_length: 3), nasty_term()])

  defp nasty_for(:integer),
    do: one_of([integer(), constant(2 ** 70), constant(-(2 ** 70)), nasty_term()])

  defp nasty_for(:map), do: one_of([map_term(), nasty_term()])

  defp nasty_for(:datetime) do
    one_of([constant(~U[2026-01-01 00:00:00Z]), constant(~U[9999-12-31 23:59:59Z]), nasty_term()])
  end

  defp nasty_for(:status), do: one_of([member_of(@statuses), nasty_term()])
  defp nasty_for(:any), do: nasty_term()
  defp nasty_for(:never), do: nasty_term()

  for name <- [
        "start input",
        "start key",
        "start tags",
        "start queue",
        "start priority",
        "start scheduled_at",
        "start_many",
        "get_execution",
        "cancel id",
        "cancel reason",
        "retry",
        "rerun",
        "release_key",
        "list_children",
        "send_event id",
        "send_event name",
        "send_event buffered name",
        "send_event buffered id",
        "provide_input id",
        "provide_input name",
        "list workflow",
        "list status",
        "list queue",
        "list key",
        "list tag",
        "list limit",
        "cancel_all tag",
        "cancel_all reason",
        "pause_queue",
        "resume_queue",
        "schedule cron",
        "get_schedule",
        "delete_schedule",
        "trigger_schedule"
      ] do
    test "#{name} answers, or names the caller's mistake" do
      ctx = %{
        running: elem(Durable.start(Waits, %{}), 1),
        waiting: waiting(Waits),
        asking: waiting(Asks)
      }

      {name, type, call} = Enum.find(calls(ctx), &(elem(&1, 0) == unquote(name)))

      check all(value <- nasty_for(type), max_runs: @runs, max_shrinking_steps: 40) do
        attempt(name, type, call, value)
      end

      assert Process.alive?(Process.whereis(Durable.Queue.Manager))
    end
  end
end
