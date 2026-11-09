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

  defmodule Quick do
    @moduledoc false
    use Durable

    workflow "fuzz_quick" do
      step(:a, fn data -> {:ok, data} end)
    end
  end

  defmodule Waits do
    @moduledoc false
    use Durable
    use Durable.Wait

    workflow "fuzz_waits" do
      step(:a, fn data ->
        wait_for_event("go")
        {:ok, data}
      end)
    end
  end

  defmodule Asks do
    @moduledoc false
    use Durable
    use Durable.Wait

    workflow "fuzz_asks" do
      step(:a, fn data ->
        wait_for_input("approve")
        {:ok, data}
      end)
    end
  end

  # Each step does what the run's script says. Queues, retries and compensations
  # are fixed here; the model in the fuzz test knows them.
  defmodule Scripted do
    @moduledoc false
    use Durable

    alias Durable.FuzzWorkflows, as: F

    workflow "fuzz_scripted" do
      step(:s1, [compensate: :u1, retry: [max_attempts: 3, backoff: :constant, base: 1]], fn d ->
        F.scripted(:s1, nil, d)
      end)

      step(
        :s2,
        [queue: :q_a, compensate: :u2, retry: [max_attempts: 3, backoff: :constant, base: 1]],
        fn d -> F.scripted(:s2, :q_a, d) end
      )

      step(:s3, [retry: [max_attempts: 3, backoff: :constant, base: 1]], fn d ->
        F.scripted(:s3, nil, d)
      end)

      step(
        :s4,
        [queue: :q_b, compensate: :u4, retry: [max_attempts: 3, backoff: :constant, base: 1]],
        fn d -> F.scripted(:s4, :q_b, d) end
      )

      step(:s5, [queue: :q_a, retry: [max_attempts: 3, backoff: :constant, base: 1]], fn d ->
        F.scripted(:s5, :q_a, d)
      end)

      step(:s6, [compensate: :u6, retry: [max_attempts: 3, backoff: :constant, base: 1]], fn d ->
        F.scripted(:s6, nil, d)
      end)

      compensate(:u1, fn d -> F.scripted_undo(:s1, d) end)
      compensate(:u2, fn d -> F.scripted_undo(:s2, d) end)
      compensate(:u4, fn d -> F.scripted_undo(:s4, d) end)
      compensate(:u6, fn d -> F.scripted_undo(:s6, d) end)
    end
  end

  def scripted(step, queue, data) do
    case_id = case_of(data)
    %{steps: steps} = Probe.fetch(case_id)
    groups = if queue, do: [{:run, case_id}, {:queue, queue}], else: [{:run, case_id}]

    Probe.inside(groups, fn ->
      Probe.note({case_id, step, :enter})
      Process.sleep(1)
      perform(Map.fetch!(steps, step), step, case_id, data)
    end)
  end

  def scripted_undo(step, data) do
    case_id = case_of(data)
    Probe.note({case_id, :undo, step})

    case Probe.fetch(case_id).undo[step] do
      :ok -> {:ok, data}
      :error -> {:error, "couldn't undo"}
      :raise -> raise "couldn't undo"
    end
  end

  defp done(step, case_id, data) do
    Probe.note({case_id, step, :done})
    {:ok, data}
  end

  defp perform(:ok, step, case_id, data), do: done(step, case_id, data)
  defp perform(:fail, _step, _case_id, _data), do: {:fail, "failed"}
  defp perform(:cancel, _step, _case_id, _data), do: {:cancel, "cancelled"}

  defp perform({:put, value}, step, case_id, data) do
    Context.put_context("put_#{step}", value)
    done(step, case_id, data)
  end

  defp perform({how, times}, step, case_id, data)
       when how in [:error, :raise, :throw, :exit, :bad] do
    if Context.attempt() <= times, do: misbehave(how), else: done(step, case_id, data)
  end

  defp perform({:snooze, times}, step, case_id, data) do
    if Probe.note({case_id, step, :snooze}) <= times,
      do: {:snooze, 1},
      else: done(step, case_id, data)
  end

  defp perform(:sleep, step, case_id, data) do
    Durable.Wait.sleep(1)
    done(step, case_id, data)
  end

  defp perform(:event, step, case_id, data) do
    Durable.Wait.wait_for_event("e_#{step}")
    done(step, case_id, data)
  end

  defp perform(:input, step, case_id, data) do
    Durable.Wait.wait_for_input("i_#{step}")
    done(step, case_id, data)
  end

  defp perform(:any, step, case_id, data) do
    Durable.Wait.wait_for_any(["e_#{step}", "never_#{step}"])
    done(step, case_id, data)
  end

  defp perform(:all, step, case_id, data) do
    Durable.Wait.wait_for_all(["e_#{step}", "f_#{step}"])
    done(step, case_id, data)
  end

  defp misbehave(:error), do: {:error, "boom"}
  defp misbehave(:raise), do: raise("boom")
  defp misbehave(:throw), do: throw(:boom)
  defp misbehave(:exit), do: exit(:boom)
  defp misbehave(:bad), do: :not_a_valid_return

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
