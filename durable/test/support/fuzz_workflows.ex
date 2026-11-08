defmodule Durable.FuzzWorkflows do
  @moduledoc false

  alias Durable.Context
  alias Durable.IntegrationProbe, as: Probe

  require Logger

  # A step of Hostile hands Durable the term stored under the run's "case".
  defmodule Hostile do
    @moduledoc false
    use Durable

    workflow "fuzz_hostile" do
      step(
        :act,
        [compensate: :undo, retry: [max_attempts: 2, backoff: :constant, base: 1]],
        fn data -> Durable.FuzzWorkflows.act(data) end
      )

      step(:next, fn data -> Durable.FuzzWorkflows.next(data) end)

      compensate(:undo, fn data -> Durable.FuzzWorkflows.undo(data) end)
    end
  end

  # Fails after a step that compensates, for what a compensation can return.
  defmodule HostileUndo do
    @moduledoc false
    use Durable

    workflow "fuzz_hostile_undo" do
      step(:book, [compensate: :undo], fn data -> {:ok, data} end)
      step(:charge, fn _data -> {:fail, "declined"} end)
      compensate(:undo, fn data -> Durable.FuzzWorkflows.undo(data) end)
    end
  end

  def case_of(data), do: data[:case] || data["case"]

  def act(data) do
    {surface, term} = Probe.fetch(case_of(data))
    apply_surface(surface, term, data)
  end

  def next(data), do: {:ok, data}

  def undo(data) do
    case Probe.fetch(case_of(data)) do
      {:undo_return, term} -> term
      {:undo_error, term} -> {:error, term}
      {:undo_fail, term} -> {:fail, term}
      {:undo_raise, term} -> raise inspect(term)
      {:undo_throw, term} -> throw(term)
      _other -> {:ok, data}
    end
  end

  defp apply_surface(:ok_value, term, _data), do: {:ok, %{"v" => term}}
  defp apply_surface(:ok_raw, term, _data), do: {:ok, term}
  defp apply_surface(:return, term, _data), do: term
  defp apply_surface(:error, term, _data), do: {:error, term}
  defp apply_surface(:fail, term, _data), do: {:fail, term}
  defp apply_surface(:cancel, term, _data), do: {:cancel, term}
  defp apply_surface(:goto, term, data), do: {:goto, term, data}
  defp apply_surface(:throw, term, _data), do: throw(term)
  defp apply_surface(:exit, term, _data), do: exit(term)

  defp apply_surface(:raise, term, _data), do: raise(RuntimeError, message: message(term))

  defp apply_surface(:put_context, term, data) do
    Context.put_context(:v, term)
    {:ok, data}
  end

  defp apply_surface(:put_context_key, term, data) do
    Context.put_context(%{term => 1})
    {:ok, data}
  end

  defp apply_surface(:snooze, term, data) do
    if Probe.here({:snooze, case_of(data)}) == 1, do: {:snooze, 1, term}, else: {:ok, data}
  end

  defp apply_surface(:log, term, data) do
    text = message(term)
    Logger.error(text)
    IO.puts(text)
    {:ok, data}
  end

  defp apply_surface(:timeout_value, term, data) do
    Durable.Wait.wait_for_event("never", timeout: 1, timeout_value: term)
    {:ok, data}
  end

  defp apply_surface(:input_options, term, data) do
    Durable.Wait.wait_for_input("never",
      timeout: 1,
      timeout_value: term,
      prompt: message(term),
      metadata: term,
      fields: term
    )

    {:ok, data}
  end

  defp apply_surface(_undo_surface, _term, _data), do: {:fail, "fails, to reach the undo"}

  defp message(term) when is_binary(term), do: term
  defp message(term), do: inspect(term)
end
