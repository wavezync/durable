defmodule Durable.Queue.Control do
  @moduledoc false
  # Cluster-wide queue pause. The state lives in `durable.queues` and is
  # enforced by the claim query every node's poller runs (see
  # `Durable.Queue.Adapters.Postgres.fetch_jobs/4`), so a pause takes effect on
  # the next poll everywhere, with no extra round trip per poll.
  #
  # `Durable.Queue.Manager.pause/2` is different: it stops this node's poller
  # only (e.g. while draining for a deploy) and is forgotten on restart.

  import Ecto.Query

  alias Durable.Config
  alias Durable.Repo
  alias Durable.Storage.Schemas.Queue

  @spec pause(Config.t(), atom() | String.t(), keyword()) :: :ok | {:error, term()}
  def pause(%Config{} = config, queue, opts \\ []) do
    with :ok <- put_paused_at(config, queue, DateTime.utc_now()),
         do: record(config, "queue_paused", queue, opts)
  end

  @spec resume(Config.t(), atom() | String.t(), keyword()) :: :ok | {:error, term()}
  def resume(%Config{} = config, queue, opts \\ []) do
    with :ok <- put_paused_at(config, queue, nil),
         do: record(config, "queue_resumed", queue, opts)
  end

  defp record(config, kind, queue, opts) do
    details = if opts[:by], do: %{by: to_string(opts[:by])}, else: %{}
    Durable.Activity.record(config, kind, queue: queue, details: details)
  end

  @spec paused(Config.t()) :: [String.t()]
  def paused(%Config{} = config) do
    Repo.all(config, from(q in Queue, where: not is_nil(q.paused_at), select: q.name))
  end

  defp put_paused_at(config, queue, paused_at) do
    now = DateTime.utc_now()

    %Queue{name: to_string(queue), paused_at: paused_at}
    |> Repo.insert(config,
      on_conflict: [set: [paused_at: paused_at, updated_at: now]],
      conflict_target: :name
    )
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end
end
