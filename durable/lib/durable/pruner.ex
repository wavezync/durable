defmodule Durable.Pruner do
  @moduledoc """
  Deletes finished runs older than the `:prune` config, once an hour. Steps,
  pending inputs, events and wait groups go with their run (foreign keys
  cascade); child runs keep living and are pruned on their own age.

  Deletes go in batches of #{5_000} with `FOR UPDATE SKIP LOCKED`, so every
  node can run the pruner without stepping on the others or holding long
  locks. Running and waiting runs are never pruned.

  Each batch emits `[:durable, :pruner, :pruned]` with `%{count}` and the
  `:group` (`:completed`, `:failed` or `:cancelled`).
  """
  use GenServer

  require Logger

  import Ecto.Query

  alias Durable.Config
  alias Durable.Repo
  alias Durable.Storage.Schemas.WorkflowExecution

  @interval :timer.hours(1)
  @batch 5_000
  @groups [
    completed: [:completed],
    failed: [:failed, :compensated, :compensation_failed],
    cancelled: [:cancelled]
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :config))

  @doc """
  Prunes now. Returns how many runs were deleted per group.
  """
  @spec prune(Config.t()) :: %{atom() => non_neg_integer()}
  def prune(%Config{prune: nil}), do: %{}

  def prune(%Config{prune: policy} = config) do
    deleted =
      for {group, statuses} <- @groups, keep_ms = policy[group], into: %{} do
        cutoff = DateTime.add(DateTime.utc_now(), -keep_ms, :millisecond)
        {group, prune_group(config, group, statuses, cutoff, 0)}
      end

    total = deleted |> Map.values() |> Enum.sum()

    if total > 0,
      do: Durable.Activity.record(config, "pruned", count: total, details: deleted)

    deleted
  end

  defp prune_group(config, group, statuses, cutoff, total) do
    # Compensated runs have no completed_at; their last write is when they
    # finished.
    expired =
      from(w in WorkflowExecution,
        where: w.status in ^statuses,
        where: fragment("coalesce(?, ?)", w.completed_at, w.updated_at) < ^cutoff,
        select: w.id,
        limit: @batch,
        lock: "FOR UPDATE SKIP LOCKED"
      )

    {count, _} =
      Repo.delete_all(config, from(w in WorkflowExecution, where: w.id in subquery(expired)))

    if count > 0 do
      :telemetry.execute([:durable, :pruner, :pruned], %{count: count}, %{
        durable: config.name,
        group: group
      })
    end

    if count == @batch,
      do: prune_group(config, group, statuses, cutoff, total + count),
      else: total + count
  end

  @impl true
  def init(%Config{} = config) do
    Process.send_after(self(), :prune, :rand.uniform(60_000))
    {:ok, config}
  end

  @impl true
  def handle_info(:prune, config) do
    try do
      prune(config)
    rescue
      e -> Logger.warning("[Durable] pruning failed, retrying next hour: #{Exception.message(e)}")
    end

    Process.send_after(self(), :prune, @interval)
    {:noreply, config}
  end
end
