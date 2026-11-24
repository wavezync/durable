defmodule Durable.Clock do
  @moduledoc """
  The time by the database's clock, the one clock of a Durable cluster.

  Nodes compare times that other nodes wrote: how old a lock is, when a sleep
  is due, when a key's next run may start. A node whose clock is off by more
  than a heartbeat takes live locks or starts a key's next run beside the last
  one. So `utc_now/0` is this node's monotonic clock set to the database's at
  the last `sync/1`, which `Durable.NodeRegistry` runs when it starts and at
  each beat. Until a sync has worked it is this node's own clock.

  It counts on the monotonic clock, not the wall clock, so a node whose wall
  clock is stepped between two syncs keeps the database's time.
  """

  alias Durable.Config
  alias Durable.Repo

  # ponytail: one offset per BEAM node, so two Durable instances on one node
  # against different database servers share it (the last to sync wins). Key
  # it by instance if that's ever needed.
  @key {__MODULE__, :offset}
  @samples 5
  @read_db "SELECT (extract(epoch FROM clock_timestamp()) * 1000000)::bigint"

  @doc "The time now, by the database's clock as of the last sync."
  @spec utc_now() :: DateTime.t()
  def utc_now do
    case :persistent_term.get(@key, nil) do
      nil -> DateTime.utc_now()
      offset -> DateTime.from_unix!(System.monotonic_time(:microsecond) + offset, :microsecond)
    end
  end

  @doc """
  Reads the database's clock a few times and keeps the reading with the
  shortest round trip. Returns the offset in microseconds, or `:error` if the
  database couldn't be read, which leaves the clock as it was.
  """
  @spec sync(Config.t()) :: integer() | :error
  def sync(%Config{} = config) do
    samples = for _ <- 1..@samples, do: sample(config)
    offset = offset(samples)
    put_offset(offset)
    offset
  rescue
    _error -> :error
  catch
    :exit, _reason -> :error
  end

  defp sample(config) do
    sent = System.monotonic_time(:microsecond)
    {:ok, %{rows: [[db]]}} = Repo.query(config, @read_db, [])
    {sent, db, System.monotonic_time(:microsecond)}
  end

  @doc false
  # The database's clock less this node's monotonic one, from `{sent, db,
  # received}` samples. The database read its clock somewhere in the round
  # trip; the shortest one leaves it least room, and the middle of it is the
  # best guess.
  @spec offset([{integer(), integer(), integer()}]) :: integer()
  def offset(samples) do
    {sent, db, received} = Enum.min_by(samples, fn {sent, _db, received} -> received - sent end)
    db - div(sent + received, 2)
  end

  @doc false
  # A small integer, so updating it costs no global GC.
  @spec put_offset(integer() | nil) :: :ok
  def put_offset(nil) do
    _ = :persistent_term.erase(@key)
    :ok
  end

  def put_offset(offset) when is_integer(offset), do: :persistent_term.put(@key, offset)
end
