defmodule Durable.Activity do
  @moduledoc """
  Operational events worth an operator's attention, kept for a week in
  `durable.activity` — the record behind "what happened to my queues?".

  | kind                  | recorded when                                                  |
  | --------------------- | -------------------------------------------------------------- |
  | `"stale_recovered"`   | runs whose node stopped heartbeating went back on the queue    |
  | `"zombie_recovered"`  | runs left `running` with no live worker were failed            |
  | `"worker_fenced"`     | a worker found its run reclaimed by another node and stopped   |
  | `"ack_failed"`        | a worker couldn't release a finished run's lock                |
  | `"queue_paused"`      | `Durable.pause_queue/2` (`details.by` when given)               |
  | `"queue_resumed"`     | `Durable.resume_queue/2`                                       |
  | `"schedule_disabled"` | a schedule was turned off after failing repeatedly            |
  | `"pruned"`            | the retention pruner deleted finished runs                     |

  Each row has `:at`, `:kind`, the `:node_id` that recorded it, and where it
  applies `:queue`, `:workflow_id`, a `:count` and `:details`.

  Recording never raises: losing an activity row must not break the recovery
  or the action it describes.
  """

  import Ecto.Query

  require Logger

  alias Durable.Config
  alias Durable.Repo
  alias Durable.Storage.Schemas.ActivityEvent

  @doc false
  @spec record(Config.t(), String.t(), keyword()) :: :ok
  def record(%Config{} = config, kind, attrs \\ []) do
    event = %ActivityEvent{
      at: DateTime.utc_now(),
      kind: kind,
      node_id: config.node_id,
      queue: attrs[:queue] && to_string(attrs[:queue]),
      workflow_id: attrs[:workflow_id],
      count: Keyword.get(attrs, :count, 1),
      details: attrs |> Keyword.get(:details, %{}) |> Durable.Executor.sanitize_for_json()
    }

    Repo.insert(event, config)
    :ok
  rescue
    e ->
      Logger.debug("[Durable] activity #{kind} not recorded: #{Exception.message(e)}")
      :ok
  end

  @doc """
  Recent activity, newest first.

  ## Options

  - `:since` - only events at or after this time (default: 24 hours ago)
  - `:limit` - at most this many (default: 100)
  - `:durable` - the Durable instance (default: `Durable`)
  """
  @spec list(keyword()) :: [ActivityEvent.t()]
  def list(opts \\ []) do
    config = Config.get(Keyword.get(opts, :durable, Durable))
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -86_400, :second))

    Repo.all(
      config,
      from(a in ActivityEvent,
        where: a.at >= ^since,
        order_by: [desc: a.at],
        limit: ^Keyword.get(opts, :limit, 100)
      )
    )
  end
end
