defmodule Durable.KeyWorkflows do
  @moduledoc false
  # Keyed workflows for the live key tests. In test/support, not a test file,
  # so a second node can load them.

  alias Durable.IntegrationProbe, as: Probe
  alias Durable.KeyWorkflows.Ledger

  defmodule Again do
    @moduledoc false
    use Durable

    workflow "kw_again", on_duplicate: :run_again do
      step :work, fn data -> Durable.KeyWorkflows.body(data) end
      step :save, fn data -> Durable.KeyWorkflows.save(data) end
    end
  end

  defmodule Debounced do
    @moduledoc false
    use Durable

    workflow "kw_debounced", on_duplicate: :run_again, debounce: [period: 30] do
      step :work, fn data -> Durable.KeyWorkflows.body(data) end
      step :save, fn data -> Durable.KeyWorkflows.save(data) end
    end
  end

  @doc """
  A step that tells the `Ledger` when it begins and ends, for which key and
  input, from whichever node runs it. `"hold"` waits for the probe's flag
  `{:go, v}`, `"ms"` sleeps, `"fail"` fails the run.
  """
  def body(data) do
    Ledger.inside(data["key"], data["v"], fn ->
      if data["hold"], do: Probe.wait_for({:go, data["v"]})
      Process.sleep(data["ms"] || 0)
    end)

    if data["fail"], do: {:fail, "told to"}, else: {:ok, data}
  end

  @doc "A second step, so a run is also between steps a while. Its input isn't noted."
  def save(data) do
    Ledger.inside(data["key"], nil, fn -> Process.sleep(data["save_ms"] || 0) end)
    {:ok, data}
  end

  @doc "The inputs (`v`) of `key` in the order their first step began."
  def ran(key), do: for({:enter, ^key, _run, v, _node} <- Ledger.events(), v != nil, do: v)

  @doc "Each `{earlier_run, later_run}` of `key` whose steps were going at once."
  def overlaps(key) do
    {pairs, _open} =
      Enum.reduce(Ledger.events(), {[], []}, fn
        {:enter, ^key, id, _v, _node}, {pairs, open} ->
          {pairs ++ for(o <- open, do: {o, id}), [id | open]}

        {:exit, ^key, id}, {pairs, open} ->
          {pairs, List.delete(open, id)}

        _other, acc ->
          acc
      end)

    pairs
  end

  defmodule Ledger do
    @moduledoc false
    # Every step of a keyed run that began and ended, in one order, from every
    # node. A step killed mid-way ends when its process does.
    use GenServer

    @name {:global, __MODULE__}

    def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: @name)

    def inside(key, v, fun) do
      id = Durable.Context.workflow_id()
      # The task's worker: killing it stops the step with it.
      worker = List.first(Process.get(:"$callers", []))
      :ok = GenServer.call(@name, {:enter, key, id, v, worker})

      try do
        fun.()
      after
        GenServer.call(@name, {:exit, key, id})
      end
    end

    @doc "`{:enter, key, run_id, v, node}` and `{:exit, key, run_id}`, oldest first."
    def events, do: GenServer.call(@name, :events)

    @doc "`{step_pid, worker_pid, run_id}` of every step of `key` going now."
    def inside_now(key), do: GenServer.call(@name, {:inside_now, key})

    def reset, do: GenServer.call(@name, :reset)

    @impl true
    def init(nil), do: {:ok, %{events: [], open: %{}}}

    @impl true
    def handle_call({:enter, key, id, v, worker}, {pid, _}, state) do
      ref = Process.monitor(pid)
      open = Map.put(state.open, ref, {key, id, pid, worker})
      event = {:enter, key, id, v, node(pid)}
      {:reply, :ok, %{state | events: [event | state.events], open: open}}
    end

    def handle_call({:exit, key, id}, {pid, _}, state) do
      case Enum.find(state.open, fn {_ref, {k, i, p, _w}} -> {k, i, p} == {key, id, pid} end) do
        {ref, _} ->
          Process.demonitor(ref, [:flush])
          {:reply, :ok, closed(state, ref)}

        nil ->
          {:reply, :ok, state}
      end
    end

    def handle_call(:events, _from, state), do: {:reply, Enum.reverse(state.events), state}

    def handle_call({:inside_now, key}, _from, state) do
      {:reply, for({_ref, {^key, id, pid, worker}} <- state.open, do: {pid, worker, id}), state}
    end

    def handle_call(:reset, _from, state) do
      for {ref, _} <- state.open, do: Process.demonitor(ref, [:flush])
      {:reply, :ok, %{events: [], open: %{}}}
    end

    @impl true
    def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
      if Map.has_key?(state.open, ref),
        do: {:noreply, closed(state, ref)},
        else: {:noreply, state}
    end

    defp closed(state, ref) do
      {{key, id, _pid, _worker}, open} = Map.pop(state.open, ref)
      %{state | events: [{:exit, key, id} | state.events], open: open}
    end
  end
end
