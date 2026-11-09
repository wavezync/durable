defmodule Durable.Queue.CommitWaker do
  @moduledoc false
  # A wake sent from inside a transaction has to wait for its commit, or the
  # pollers find nothing. This asks Postgres how those transactions ended, with
  # one query per tick and none when there's nothing to watch. It uses plain
  # queries, so it works through a transaction-mode connection pooler, which
  # LISTEN/NOTIFY doesn't.
  #
  # A wake only saves waiting for the next poll, so losing one is harmless: a
  # failed query is tried again, and a transaction open past the limit is left
  # to the poll.

  use GenServer

  alias Durable.Config
  alias Durable.PubSub, as: DurablePubSub
  alias Durable.Repo

  @tick_ms 20
  @give_up_ms 60_000

  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(%Config{} = config),
    do: GenServer.start_link(__MODULE__, config, name: name(config))

  @spec watch(Config.t(), String.t(), String.t(), non_neg_integer()) :: :ok
  def watch(%Config{} = config, transaction, queue, give_up_ms \\ @give_up_ms) do
    GenServer.cast(name(config), {:watch, transaction, queue, give_up_ms})
  end

  @spec name(Config.t()) :: atom()
  def name(%Config{name: durable_name}), do: Module.concat([durable_name, Queue, CommitWaker])

  @impl true
  def init(config), do: {:ok, %{config: config, watched: %{}}}

  @impl true
  def handle_cast({:watch, transaction, queue, give_up_ms}, %{watched: watched} = state) do
    if watched == %{}, do: tick()

    deadline = System.monotonic_time(:millisecond) + give_up_ms

    watched =
      Map.update(watched, transaction, {deadline, MapSet.new([queue])}, fn {at, queues} ->
        {at, MapSet.put(queues, queue)}
      end)

    {:noreply, %{state | watched: watched}}
  end

  @impl true
  def handle_info(:tick, %{config: config, watched: watched} = state) do
    statuses = statuses(config, Map.keys(watched))
    now = System.monotonic_time(:millisecond)

    still_open =
      watched
      |> Enum.filter(fn {transaction, watch} ->
        open?(config, statuses, transaction, watch, now)
      end)
      |> Map.new()

    if still_open != %{}, do: tick()
    {:noreply, %{state | watched: still_open}}
  end

  defp open?(config, statuses, transaction, {deadline, queues}, now) do
    case Map.fetch(statuses, transaction) do
      {:ok, "committed"} ->
        Enum.each(queues, &DurablePubSub.broadcast_wake(config, &1))
        false

      {:ok, "in progress"} ->
        now < deadline

      # Rolled back, or so old Postgres no longer knows.
      {:ok, _other} ->
        false

      :error ->
        now < deadline
    end
  end

  defp statuses(config, transactions) do
    sql = "SELECT id, pg_xact_status(id::xid8) FROM unnest($1::text[]) AS id"

    case Repo.query(config, sql, [transactions]) do
      {:ok, %{rows: rows}} -> Map.new(rows, &List.to_tuple/1)
      {:error, _reason} -> %{}
    end
  rescue
    # The database is unreachable, or the connection isn't ours to use.
    _error -> %{}
  end

  defp tick, do: Process.send_after(self(), :tick, @tick_ms)
end
