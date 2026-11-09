defmodule Durable.IntegrationProbe do
  @moduledoc false
  # Workflow steps report here, from whichever process and node runs them.

  use GenServer

  import Ecto.Query

  alias Durable.Context
  alias Durable.IntegrationRepo
  alias Durable.Storage.Schemas.WorkflowExecution

  @name {:global, __MODULE__}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: @name)

  @doc "Records `label` with the queue the run is on now. Returns its count so far."
  def here(label) do
    id = Context.workflow_id()
    queue = IntegrationRepo.one(from(w in WorkflowExecution, where: w.id == ^id, select: w.queue))
    GenServer.call(@name, {:here, label, queue})
  end

  @doc "A slot taken for `ms`, counted under `group` to find the peak."
  def work(label, group, ms) do
    GenServer.call(@name, {:enter, label, group})
    Process.sleep(ms)
    GenServer.call(@name, {:leave, group})
  end

  def wait_for(flag) do
    unless set?(flag) do
      Process.sleep(10)
      wait_for(flag)
    end
  end

  @doc "Stores a term for a step to pick up, without a trip through JSON."
  def put(key, value), do: GenServer.call(@name, {:put, key, value})
  def fetch(key), do: GenServer.call(@name, {:fetch, key})

  @doc "Like `here/1`, without looking up the queue. Returns its count so far."
  def note(label), do: GenServer.call(@name, {:here, label, nil})

  @doc "Runs `fun` counted under each of `groups`, to find their peaks."
  def inside(groups, fun) do
    for group <- groups, do: GenServer.call(@name, {:enter, group, group})

    try do
      fun.()
    after
      for group <- groups, do: GenServer.call(@name, {:leave, group})
    end
  end

  def set(flag), do: GenServer.call(@name, {:set, flag})
  def set?(flag), do: GenServer.call(@name, {:set?, flag})
  def hits(label), do: GenServer.call(@name, {:hits, label})
  def peak(group), do: GenServer.call(@name, {:peak, group})

  @doc "Everything recorded, oldest first, as `{label, queue, node}`."
  def log, do: GenServer.call(@name, :log)

  @doc "The labels recorded, oldest first, each with its queue."
  def trail, do: Enum.map(log(), fn {label, queue, _node} -> {label, queue} end)

  @impl true
  def init(nil) do
    {:ok, %{hits: %{}, running: %{}, peak: %{}, log: [], flags: MapSet.new(), stored: %{}}}
  end

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    {:reply, :ok, put_in(state.stored[key], value)}
  end

  def handle_call({:fetch, key}, _from, state), do: {:reply, Map.fetch!(state.stored, key), state}

  def handle_call({:here, label, queue}, {pid, _}, state) do
    state = count(state, label)
    state = %{state | log: [{label, queue, node(pid)} | state.log]}
    {:reply, state.hits[label], state}
  end

  def handle_call({:enter, label, group}, {pid, _}, state) do
    running = Map.get(state.running, group, 0) + 1
    peak = max(running, Map.get(state.peak, group, 0))

    state = count(state, label)

    {:reply, :ok,
     %{
       state
       | running: Map.put(state.running, group, running),
         peak: Map.put(state.peak, group, peak),
         log: [{label, group, node(pid)} | state.log]
     }}
  end

  def handle_call({:leave, group}, _from, state),
    do: {:reply, :ok, %{state | running: Map.update!(state.running, group, &(&1 - 1))}}

  def handle_call({:set, flag}, _from, state),
    do: {:reply, :ok, %{state | flags: MapSet.put(state.flags, flag)}}

  def handle_call({:set?, flag}, _from, state),
    do: {:reply, MapSet.member?(state.flags, flag), state}

  def handle_call({:hits, label}, _from, state),
    do: {:reply, Map.get(state.hits, label, 0), state}

  def handle_call({:peak, group}, _from, state),
    do: {:reply, Map.get(state.peak, group, 0), state}

  def handle_call(:log, _from, state), do: {:reply, Enum.reverse(state.log), state}

  defp count(state, label), do: %{state | hits: Map.update(state.hits, label, 1, &(&1 + 1))}
end
