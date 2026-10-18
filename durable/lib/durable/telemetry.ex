defmodule Durable.Telemetry do
  @moduledoc """
  The `:telemetry` events Durable emits. This list is a contract: names,
  measurements and metadata keys only change in a major version.

  Spans follow `:telemetry.span/3`: a `:start` event, then exactly one of
  `:stop` or `:exception`, with `duration` in native time units — the same
  shape as Phoenix, Ecto and Oban, so existing tooling reads them as-is.

  Run, step, compensation and schedule events include `:durable` (the
  instance name) in their metadata.

  ## Runs

  A run executes in *segments*: it starts, runs until it finishes or suspends
  (sleep, wait for an event or input, parallel fan-out), and later resumes as
  a new segment, possibly on another node. Each segment is one span.

    * `[:durable, :workflow, :start]` — `%{system_time, monotonic_time}`;
      metadata `:workflow_id`, `:workflow`, `:workflow_module`, `:queue`,
      `:trigger`, `:resumed` (false on a run's first segment)
    * `[:durable, :workflow, :stop]` — `%{duration, monotonic_time}`; adds
      `:status`: `:completed`, `:failed`, `:compensated`,
      `:compensation_failed`, `:waiting` (suspended) or `:superseded`
      (cancelled or reclaimed by another node mid-segment)
    * `[:durable, :workflow, :exception]` — the executor itself crashed;
      adds `:kind`, `:reason`, `:stacktrace`

  ## Steps

  One span per attempt. A step that raises or returns an error is a normal
  `:stop` with `result: :error` — `:exception` means Durable itself failed.

    * `[:durable, :step, :start]` — metadata `:workflow_id`, `:workflow`,
      `:step`, `:step_type`, `:attempt`, `:max_attempts`
    * `[:durable, :step, :stop]` — adds `:result` (`:ok`, `:error` or
      `:suspended`) and, for errors, `:error` (`%{type, message}`)
    * `[:durable, :step, :exception]`
    * `[:durable, :step, :retry]` — `%{backoff_ms}`; the step metadata plus
      `:error`, emitted before sleeping for the next attempt

  ## Compensations

    * `[:durable, :compensation, :start | :stop | :exception]` — metadata
      `:workflow_id`, `:workflow`, `:compensation`, `:step` (the step it
      undoes); `:stop` adds `:result` (`:ok` or `:error`)

  ## Queue, scheduler and waits

    * `[:durable, :queue, :job_claimed]` — `%{count}`; `:job_id`, `:queue`, `:node_id`
    * `[:durable, :queue, :job_completed]` — `%{duration}`; `:job_id`,
      `:queue`, `:workflow_module`, `:workflow_name`, `:status`
    * `[:durable, :queue, :poll]` — `%{jobs_fetched}`; `:queue`, `:available_slots`
    * `[:durable, :queue, :heartbeat]` — `%{count}`; `:job_id`, `:queue`
    * `[:durable, :queue, :stale_recovered]`, `[:durable, :queue, :zombie_recovered]` — `%{count}`
    * `[:durable, :queue, :worker_fenced]` — `%{count, duration}`; `:job_id`, `:queue`
    * `[:durable, :queue, :ack_failed]` — `%{count, attempts}`; `:job_id`, `:reason`
    * `[:durable, :schedule, :trigger]` — `%{count}`; `:schedule`,
      `:workflow_id`, `:workflow_module`, `:workflow`, `:queue`
    * `[:durable, :wait, :sleep_woken]` — `%{count}`
    * `[:durable, :pruner, :pruned]` — `%{count}`; `:group` (`:completed`,
      `:failed` or `:cancelled`), once per deleted batch

  ## Reporting

  `metrics/0` returns `Telemetry.Metrics` definitions for any reporter
  (Prometheus, StatsD, LiveDashboard) when `:telemetry_metrics` is installed:

      def metrics, do: my_metrics() ++ Durable.Telemetry.metrics()

  `attach_default_logger/1` logs one line per finished run and per failed step.
  """

  require Logger

  @events [
    [:durable, :workflow, :start],
    [:durable, :workflow, :stop],
    [:durable, :workflow, :exception],
    [:durable, :step, :start],
    [:durable, :step, :stop],
    [:durable, :step, :exception],
    [:durable, :step, :retry],
    [:durable, :compensation, :start],
    [:durable, :compensation, :stop],
    [:durable, :compensation, :exception],
    [:durable, :queue, :job_claimed],
    [:durable, :queue, :job_completed],
    [:durable, :queue, :poll],
    [:durable, :queue, :heartbeat],
    [:durable, :queue, :stale_recovered],
    [:durable, :queue, :zombie_recovered],
    [:durable, :queue, :worker_fenced],
    [:durable, :queue, :ack_failed],
    [:durable, :schedule, :trigger],
    [:durable, :wait, :sleep_woken],
    [:durable, :pruner, :pruned]
  ]

  @doc """
  Every event name Durable emits, for `:telemetry.attach_many/4`.
  """
  @spec events() :: [[atom()]]
  def events, do: @events

  @logger_id "durable-default-logger"

  @doc """
  Logs one line per finished run (`level`, default `:info`) and one warning
  per failed step attempt. Detach with `:telemetry.detach("#{@logger_id}")`.
  """
  @spec attach_default_logger(keyword()) :: :ok | {:error, :already_exists}
  def attach_default_logger(opts \\ []) do
    :telemetry.attach_many(
      @logger_id,
      [[:durable, :workflow, :stop], [:durable, :workflow, :exception], [:durable, :step, :stop]],
      &__MODULE__.handle_log_event/4,
      Keyword.get(opts, :level, :info)
    )
  end

  # Telemetry handlers run in the step's process, so without this the step's
  # log capture would record these lines as if the step had logged them.
  @internal [durable_internal: true]

  @doc false
  def handle_log_event([:durable, :workflow, :stop], %{duration: duration}, meta, level) do
    Logger.log(
      if(meta.status in [:failed, :compensation_failed], do: :error, else: level),
      "[Durable] #{meta.workflow} #{meta.workflow_id} #{meta.status} in #{ms(duration)}ms",
      @internal
    )
  end

  def handle_log_event([:durable, :workflow, :exception], _measurements, meta, _level) do
    Logger.error(
      "[Durable] #{meta.workflow} #{meta.workflow_id} crashed: " <>
        Exception.format(meta.kind, meta.reason, meta.stacktrace),
      @internal
    )
  end

  def handle_log_event(
        [:durable, :step, :stop],
        %{duration: duration},
        %{result: :error} = meta,
        _
      ) do
    Logger.warning(
      "[Durable] #{meta.workflow} #{meta.workflow_id} step #{meta.step} failed " <>
        "(attempt #{meta.attempt}/#{meta.max_attempts}, #{ms(duration)}ms): " <>
        "#{meta.error.type}: #{meta.error.message}",
      @internal
    )
  end

  def handle_log_event(_event, _measurements, _meta, _level), do: :ok

  defp ms(native), do: System.convert_time_unit(native, :native, :millisecond)

  # `:telemetry_metrics` is optional, so no `import` here: an import is
  # expanded even inside a false `if` and would break compilation for apps
  # that don't install it.
  @compile {:no_warn_undefined, Telemetry.Metrics}

  if Code.ensure_loaded?(Telemetry.Metrics) do
    alias Telemetry.Metrics

    # ms buckets from a fast step to a slow run; reporters without buckets
    # ignore them.
    @buckets [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 30_000, 60_000, 300_000]

    @doc """
    `Telemetry.Metrics` definitions for Durable's events. Tags are bounded —
    workflow, step, queue and schedule names, never run ids.
    """
    @spec metrics() :: [Telemetry.Metrics.t()]
    def metrics do
      ms = [unit: {:native, :millisecond}, reporter_options: [buckets: @buckets]]
      # Counters count events. Most of these events carry no `:count`, and
      # LiveDashboard drops an event whose measurement is missing.
      event = fn _measurements -> 1 end

      [
        Metrics.counter("durable.workflow.stop.count",
          tags: [:workflow, :status],
          measurement: event
        ),
        Metrics.distribution(
          "durable.workflow.stop.duration",
          [tags: [:workflow, :status]] ++ ms
        ),
        Metrics.counter("durable.step.stop.count",
          tags: [:workflow, :step, :result],
          measurement: event
        ),
        Metrics.distribution("durable.step.stop.duration", [tags: [:workflow, :step]] ++ ms),
        Metrics.counter("durable.step.retry.count", tags: [:workflow, :step], measurement: event),
        Metrics.counter("durable.compensation.stop.count",
          tags: [:workflow, :compensation, :result],
          measurement: event
        ),
        Metrics.distribution(
          "durable.queue.job_completed.duration",
          [tags: [:queue, :status]] ++ ms
        ),
        Metrics.counter("durable.queue.worker_fenced.count", tags: [:queue], measurement: event),
        Metrics.sum("durable.queue.stale_recovered.count", []),
        Metrics.sum("durable.queue.zombie_recovered.count", []),
        Metrics.counter("durable.schedule.trigger.count", tags: [:schedule], measurement: event)
      ]
    end
  end

  # Run-level metadata, shared with the step and compensation spans that run
  # inside it (they only know the workflow id).
  @meta_key {__MODULE__, :run}

  @doc false
  def put_run_meta(meta), do: Process.put(@meta_key, meta)

  @doc false
  def run_meta, do: Process.get(@meta_key, %{})
end
