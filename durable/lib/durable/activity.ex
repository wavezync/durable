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
  | `"schedule_removed"`  | schedules were turned off for no longer having an `@schedule`  |
  | `"pruned"`            | the retention pruner deleted finished runs                     |
  | `"key_duplicate"`     | a start found its key taken and returned the holder or an error |
  | `"key_handed_off"`    | a start took a key from a closed run that `reuse:` let go      |
  | `"key_released"`      | `Durable.release_key/2` (`details.by` when given)              |
  | `"key_retaken"`       | a retry took its key back from a closed run                    |

  Key events carry `details.key` and `details.workflow`, and their
  `:workflow_id` is the run they're about: the holder for `"key_duplicate"`,
  the new holder for `"key_handed_off"` (with `replaced: true` when it
  cancelled the holder) and `"key_retaken"`. A
  `"key_duplicate"` also has `outcome` (`use_existing`, `error`,
  `cancel_existing`, `send_event` with the `event` name, or `debounced`),
  `holder_status` and `input_changed`, plus the new `input` when it differed
  (up to 16 KB; `input_truncated` when larger).

  Each row has `:at`, `:kind`, the `:node_id` that recorded it, and where it
  applies `:queue`, `:workflow_id`, a `:count` and `:details`.

  Recording never raises: losing an activity row must not break the recovery
  or the action it describes. Inside a transaction the insert runs under a
  savepoint, so a failed insert doesn't abort the caller's transaction either.
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

    # Inside a transaction (a caller's `Durable.start/3`), `mode: :savepoint`
    # rolls back just this insert on error instead of leaving the transaction
    # aborted. Postgrex refuses that mode outside a transaction.
    opts = if config.repo.in_transaction?(), do: [mode: :savepoint], else: []
    Repo.insert(event, config, opts)
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
  - `:workflow_id` - only events about this run
  - `:kinds` - only these kinds (strings)
  - `:durable` - the Durable instance (default: `Durable`)
  """
  @spec list(keyword()) :: [ActivityEvent.t()]
  def list(opts \\ []) do
    config = Config.get(Keyword.get(opts, :durable, Durable))
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -86_400, :second))

    query =
      from(a in ActivityEvent,
        where: a.at >= ^since,
        order_by: [desc: a.at],
        limit: ^Keyword.get(opts, :limit, 100)
      )

    query =
      case Keyword.get(opts, :workflow_id) do
        nil -> query
        id -> from(a in query, where: a.workflow_id == ^id)
      end

    query =
      case Keyword.get(opts, :kinds) do
        nil -> query
        kinds -> from(a in query, where: a.kind in ^kinds)
      end

    Repo.all(config, query)
  end
end
