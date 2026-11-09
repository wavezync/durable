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
      metadata `:workflow_id`, `:root_workflow_id` (the run at the top of its
      tree), `:workflow`, `:workflow_module`, `:queue`, `:key`, `:tags`,
      `:trigger`, `:resumed` (false on a run's first segment)
    * `[:durable, :workflow, :stop]` — `%{duration, monotonic_time}`; adds
      `:status`: `:completed`, `:failed`, `:compensated`,
      `:compensation_failed`, `:waiting` (suspended: a wait, or a retry or
      snooze that parked the run) or `:superseded`
      (cancelled, reclaimed by another node, or its process died mid-segment)
    * `[:durable, :workflow, :exception]` — the executor itself crashed;
      adds `:kind`, `:reason`, `:stacktrace`

  ## Steps

  One span per attempt. A step that raises or returns an error is a normal
  `:stop` with `result: :error` — `:exception` means Durable itself failed.

    * `[:durable, :step, :start]` — metadata `:workflow_id`,
      `:root_workflow_id`, `:step_execution_id` (the attempt's row), `:workflow`,
      `:key`, `:tags`, `:step`, `:step_type`, `:attempt`, `:max_attempts`
    * `[:durable, :step, :stop]` — adds `:result` (`:ok`, `:error`,
      `:suspended`, `:snoozed` or `:cancelled`) and, for errors, `:error`
      (`%{type, message}`)
    * `[:durable, :step, :exception]`
    * `[:durable, :step, :retry]` — `%{backoff_ms}`; the step metadata plus
      `:error`, emitted as the run parks until the next attempt
    * `[:durable, :step, :snooze]` — `%{snooze_ms}`; the step metadata plus
      `:reason` (`nil` for `{:snooze, ms}`)

  ## Compensations

    * `[:durable, :compensation, :start | :stop | :exception]` — metadata
      `:workflow_id`, `:root_workflow_id`, `:workflow`, `:key`, `:tags`,
      `:compensation`, `:step` (the step it undoes); `:stop` adds `:result`
      (`:ok` or `:error`)

  ## Attempts that die

  An attempt's end event comes from whoever closes its row. That's one atomic
  update, so each attempt gets exactly one. When its process dies, its node is
  lost or its run is cancelled, that's the worker, a sweep or the cancel,
  possibly on another node, which sends:

    * `[:durable, :step, :stop]` with `result: :error` (and `:error`),
      `:cancelled` or `:snoozed`, or `[:durable, :compensation, :stop]` with
      `result: :error`. `duration` runs from the attempt's start
    * `[:durable, :step, :retry]` if another attempt follows; `backoff_ms` is 0
      after a lost worker, which uses no attempt
    * `[:durable, :workflow, :stop]` with `status: :superseded`. Its `duration`
      also runs from the attempt's start, not the segment's, and `:resumed` is
      `nil`

  So a handler can't assume the process that saw `:start` sees the end.
  `:telemetry_span_context` matches them up: it's the row id for a step, the run
  id for a segment. A node that dies between two steps has no attempt to close,
  so that segment gets no end event.

  ## Queue, scheduler and waits

    * `[:durable, :queue, :job_claimed]` — `%{count}`; `:job_id`, `:queue`, `:node_id`
    * `[:durable, :queue, :job_completed]` — `%{duration}`; `:job_id`,
      `:queue`, `:workflow_module`, `:workflow_name`, `:status`
    * `[:durable, :queue, :poll]` — `%{jobs_fetched}`; `:queue`, `:available_slots`
    * `[:durable, :queue, :claim_failed]` — `%{count}`; a poll's claim query
      failed. `:queue`, `:reason`
    * `[:durable, :queue, :heartbeat]` — `%{count}`; `:job_id`, `:queue`
    * `[:durable, :queue, :stale_recovered]`, `[:durable, :queue, :zombie_recovered]` — `%{count}`
    * `[:durable, :queue, :worker_fenced]` — `%{count, duration}`; `:job_id`, `:queue`
    * `[:durable, :queue, :ack_failed]` — `%{count, attempts}`; `:job_id`, `:reason`
    * `[:durable, :node, :drain, :start | :stop | :exception]` — a span around a
      node stopping work; metadata `:durable`, `:node_id`; `:stop` adds `:result`
      (`:ok` or `{:error, :timeout}`)
    * `[:durable, :schedule, :trigger]` — `%{count}`; `:schedule`,
      `:workflow_id`, `:workflow_module`, `:workflow`, `:queue`
    * `[:durable, :wait, :sleep_woken]` — `%{count}`
    * `[:durable, :pruner, :pruned]` — `%{count}`; `:group` (`:completed`,
      `:failed` or `:cancelled`), once per deleted batch

  ## Workflow keys

    * `[:durable, :key, :duplicate]` — `%{count}`; a start found its key
      taken. `:workflow`, `:key`, `:holder_id`, `:outcome` (`:use_existing`,
      `:error`, `:cancel_existing`, `:send_event` or `:debounced`),
      `:input_changed`
    * `[:durable, :key, :handoff]` — `%{count}`; a start took the key from a
      finished run. `:workflow`, `:key`, `:from`, `:to`
    * `[:durable, :key, :release]` — `%{count}`; `Durable.release_key/2`.
      `:workflow`, `:key`, `:workflow_id`, `:by`

  ## Logs

  Before each attempt of a step or compensation, `Logger.metadata/1` gets
  `:workflow`, `:workflow_id`, `:step` and `:attempt`, plus whatever the
  workflow's `log_metadata:` function returns for the step's data. Add the
  ones you want to your Logger formatter's `:metadata`. `Durable.LogCapture`
  describes what's saved on the step's row.

  `Durable.OpenTelemetry` turns attempts into spans.

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
    [:durable, :step, :snooze],
    [:durable, :compensation, :start],
    [:durable, :compensation, :stop],
    [:durable, :compensation, :exception],
    [:durable, :queue, :job_claimed],
    [:durable, :queue, :job_completed],
    [:durable, :queue, :poll],
    [:durable, :queue, :claim_failed],
    [:durable, :queue, :heartbeat],
    [:durable, :queue, :stale_recovered],
    [:durable, :queue, :zombie_recovered],
    [:durable, :queue, :worker_fenced],
    [:durable, :queue, :ack_failed],
    [:durable, :node, :drain, :start],
    [:durable, :node, :drain, :stop],
    [:durable, :node, :drain, :exception],
    [:durable, :schedule, :trigger],
    [:durable, :wait, :sleep_woken],
    [:durable, :pruner, :pruned],
    [:durable, :key, :duplicate],
    [:durable, :key, :handoff],
    [:durable, :key, :release]
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
        Metrics.counter("durable.schedule.trigger.count", tags: [:schedule], measurement: event),
        Metrics.counter("durable.key.duplicate.count",
          tags: [:workflow, :outcome],
          measurement: event
        ),
        Metrics.counter("durable.key.handoff.count", tags: [:workflow], measurement: event)
      ]
    end
  end

  # Run-level metadata, shared with the step and compensation spans that run
  # inside it (they only know the workflow id).
  @meta_key {__MODULE__, :run}
  @log_fields_key {__MODULE__, :log_fields}
  @log_keys_key {__MODULE__, :log_keys}

  @doc false
  # A run's id as an OpenTelemetry trace id, and the low 8 bytes of a row's id
  # as a span id. Both are the hex forms OpenTelemetry uses.
  @spec log_ids(String.t(), String.t()) :: %{trace_id: String.t(), span_id: String.t()}
  def log_ids(root_id, row_id) do
    %{
      trace_id: String.replace(root_id, "-", ""),
      span_id: row_id |> String.replace("-", "") |> String.slice(16, 16)
    }
  end

  @doc false
  # :telemetry.span/3, except that the end event can belong to someone else: an
  # attempt that was closed while it ran had its end event sent by the closer.
  # `meta` carries a `:telemetry_span_context` the closer can work out too.
  @spec span([atom()], map(), (-> {result, map()})) :: result when result: term()
  def span(prefix, %{telemetry_span_context: _} = meta, fun) do
    started = System.monotonic_time()

    :telemetry.execute(
      prefix ++ [:start],
      %{monotonic_time: started, system_time: System.system_time()},
      meta
    )

    try do
      {result, stop_meta} = fun.()
      :telemetry.execute(prefix ++ [:stop], elapsed(started), stop_meta)
      result
    catch
      :throw, :durable_attempt_closed ->
        throw(:durable_attempt_closed)

      # The attempt is still open: whoever closes it sends the end event.
      :error, %DBConnection.ConnectionError{} = error ->
        reraise error, __STACKTRACE__

      kind, reason ->
        stacktrace = __STACKTRACE__
        details = %{kind: kind, reason: reason, stacktrace: stacktrace}
        :telemetry.execute(prefix ++ [:exception], elapsed(started), Map.merge(meta, details))
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp elapsed(started) do
    now = System.monotonic_time()
    %{duration: now - started, monotonic_time: now}
  end

  @doc false
  def put_run_meta(meta, log_fields \\ nil) do
    Process.put(@log_fields_key, log_fields)
    Process.put(@meta_key, meta)
  end

  @doc false
  def run_meta, do: Process.get(@meta_key, %{})

  @doc false
  # Set before every attempt, since an attempt can land in a new process. A
  # step's own `Logger.metadata/1` lasts only as long as that process does.
  def put_log_metadata(workflow_id, step, attempt, data) do
    fields =
      [workflow: Map.get(run_meta(), :workflow), workflow_id: workflow_id] ++
        [step: step, attempt: attempt] ++ log_fields(Process.get(@log_fields_key), data)

    Process.put(@log_keys_key, Keyword.keys(fields))
    Logger.metadata(fields)
  end

  @doc false
  # A run executed inline leaves the caller's own metadata as it found it.
  def clear_log_metadata do
    Logger.metadata(Enum.map(Process.delete(@log_keys_key) || [], &{&1, nil}))
  end

  defp log_fields(nil, _data), do: []

  # Metadata is a nicety: a function that fails costs the step nothing.
  defp log_fields(fun, data) do
    case fun.(data) do
      fields when is_list(fields) -> if Keyword.keyword?(fields), do: fields, else: []
      _other -> []
    end
  catch
    kind, reason ->
      Logger.warning(
        "[Durable] log_metadata failed: #{Exception.format_banner(kind, reason)}",
        @internal
      )

      []
  end
end
