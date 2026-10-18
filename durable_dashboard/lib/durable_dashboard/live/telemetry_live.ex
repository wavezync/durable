defmodule DurableDashboard.Live.TelemetryLive do
  @moduledoc """
  What Durable emits, who is listening on this node, and how to wire it up.

    * **Listening now** — `:telemetry.list_handlers/1` for `[:durable]` and
      `[:durable_dashboard]`, so you can see whether your reporter attached.
    * **Events** — the contract from `Durable.Telemetry`, with how often each
      fired on this node over the last five minutes. Counting attaches a
      handler that bumps a `:counters` slot (no message per event) and
      detaches itself once this page's process is gone.
    * **Metrics** — `Durable.Telemetry.metrics/0`, when `:telemetry_metrics`
      is installed.
  """

  use Phoenix.LiveView

  alias DurableDashboard.Components.Charts
  alias DurableDashboard.Components.Core
  alias DurableDashboard.Format
  alias DurableDashboard.Layouts

  # Defined only when the host app has :telemetry_metrics; checked at runtime.
  @compile {:no_warn_undefined, {Durable.Telemetry, :metrics, 0}}

  @sample_ms 5_000
  # 5 minutes of samples, plus the one they're measured from.
  @window 61

  @audit_event [:durable_dashboard, :action]

  # Measurements and metadata per event, mirroring `Durable.Telemetry`'s
  # moduledoc. A test keeps this in step with `Durable.Telemetry.events/0`.
  @catalog [
    {"Runs",
     [
       {[:durable, :workflow, :start], "system_time",
        "workflow, workflow_id, queue, trigger, resumed"},
       {[:durable, :workflow, :stop], "duration",
        "+ status: completed | failed | compensated | compensation_failed | waiting | superseded"},
       {[:durable, :workflow, :exception], "duration", "+ kind, reason, stacktrace"}
     ]},
    {"Steps",
     [
       {[:durable, :step, :start], "system_time",
        "workflow, workflow_id, step, step_type, attempt, max_attempts"},
       {[:durable, :step, :stop], "duration", "+ result: ok | error | suspended; error"},
       {[:durable, :step, :exception], "duration", "+ kind, reason, stacktrace"},
       {[:durable, :step, :retry], "backoff_ms", "step metadata + error"}
     ]},
    {"Compensations",
     [
       {[:durable, :compensation, :start], "system_time", "workflow, compensation, step"},
       {[:durable, :compensation, :stop], "duration", "+ result: ok | error"},
       {[:durable, :compensation, :exception], "duration", "+ kind, reason, stacktrace"}
     ]},
    {"Queue",
     [
       {[:durable, :queue, :job_claimed], "count", "job_id, queue, node_id"},
       {[:durable, :queue, :job_completed], "duration",
        "job_id, queue, workflow_module, workflow_name, status"},
       {[:durable, :queue, :poll], "jobs_fetched", "queue, available_slots"},
       {[:durable, :queue, :heartbeat], "count", "job_id, queue"},
       {[:durable, :queue, :stale_recovered], "count", ""},
       {[:durable, :queue, :zombie_recovered], "count", ""},
       {[:durable, :queue, :worker_fenced], "count, duration", "job_id, queue"},
       {[:durable, :queue, :ack_failed], "count, attempts", "job_id, reason"}
     ]},
    {"Schedules, waits and retention",
     [
       {[:durable, :schedule, :trigger], "count",
        "schedule, workflow_id, workflow_module, workflow, queue"},
       {[:durable, :wait, :sleep_woken], "count", ""},
       {[:durable, :pruner, :pruned], "count", "group: completed | failed | cancelled"}
     ]},
    {"Dashboard",
     [
       {@audit_event, "count", "action, user, ids, result — an audit trail of every action"}
     ]}
  ]

  # What makes each event fire, for its tooltip.
  @fires %{
    [:durable, :workflow, :start] => "A worker starts or resumes a run",
    [:durable, :workflow, :stop] => "A run finishes, or pauses to wait",
    [:durable, :workflow, :exception] => "A run crashes outside a step",
    [:durable, :step, :start] => "An attempt at a step begins",
    [:durable, :step, :stop] => "An attempt ends · ok, error or suspended",
    [:durable, :step, :exception] => "A step raises",
    [:durable, :step, :retry] => "A failed attempt is retried after backoff_ms",
    [:durable, :compensation, :start] => "An undo step begins",
    [:durable, :compensation, :stop] => "An undo step ends",
    [:durable, :compensation, :exception] => "An undo step raises",
    [:durable, :queue, :job_claimed] => "A worker claims a run from its queue",
    [:durable, :queue, :job_completed] => "A worker is done with a run",
    [:durable, :queue, :poll] => "A queue looks for work",
    [:durable, :queue, :heartbeat] => "A worker renews its lock on a long run",
    [:durable, :queue, :stale_recovered] => "Runs whose lock went stale go back on the queue",
    [:durable, :queue, :zombie_recovered] => "Runs held by a dead node are taken back",
    [:durable, :queue, :worker_fenced] => "A worker lost its lock and stopped writing",
    [:durable, :queue, :ack_failed] => "Marking a job done failed, even after retries",
    [:durable, :schedule, :trigger] => "A schedule starts a run",
    [:durable, :wait, :sleep_woken] => "Sleeping runs wake up",
    [:durable, :pruner, :pruned] => "Retention deletes a batch of old runs",
    @audit_event => "Someone acts in this dashboard"
  }

  @metric_types %{
    "counter" => "Counts events",
    "sum" => "Adds a measurement up",
    "distribution" => "Buckets a measurement into a histogram",
    "summary" => "Tracks a measurement's percentiles",
    "lastvalue" => "Keeps a measurement's latest value"
  }

  @snippet [
    {:comment, "# Prometheus / StatsD / LiveDashboard: add Durable's metrics"},
    {:code, "def metrics, do: my_metrics() ++ Durable.Telemetry.metrics()"},
    {:code, ""},
    {:comment, "# One log line per finished run and failed step"},
    {:code, "Durable.Telemetry.attach_default_logger(level: :info)"},
    {:code, ""},
    {:comment, "# Audit trail of dashboard actions"},
    {:code,
     ~s|:telemetry.attach("audit", [:durable_dashboard, :action], &MyApp.Audit.log/4, nil)|}
  ]

  @doc false
  def catalog, do: @catalog

  @doc false
  def fires, do: @fires

  @impl true
  def mount(_params, session, socket) do
    config = session["config"]
    events = Enum.flat_map(@catalog, fn {_group, rows} -> Enum.map(rows, &elem(&1, 0)) end)
    counters = :counters.new(length(events), [:write_concurrency])

    if connected?(socket) do
      attach_counter(events, counters)
      :timer.send_interval(@sample_ms, :sample)
    end

    {:ok,
     assign(socket,
       config: config,
       base_path: config.base_path,
       durable: config.durable,
       page_title: "Telemetry",
       breadcrumbs: [%{label: "Telemetry"}],
       events: events,
       counters: counters,
       samples: [sample(counters, length(events))],
       handlers: handlers(),
       metrics: metrics(),
       node: node()
     )}
  end

  @impl true
  def handle_params(_params, uri, socket),
    do: {:noreply, assign(socket, current_path: URI.parse(uri).path)}

  @impl true
  def handle_info(:sample, socket) do
    now = sample(socket.assigns.counters, length(socket.assigns.events))

    {:noreply,
     assign(socket,
       samples: Enum.take([now | socket.assigns.samples], @window),
       handlers: handlers()
     )}
  end

  @impl true
  def terminate(_reason, _socket), do: :telemetry.detach(handler_id(self()))

  # ---- Counting ---------------------------------------------------------------

  defp attach_counter(events, counters) do
    index = events |> Enum.with_index(1) |> Map.new()

    :telemetry.attach_many(handler_id(self()), events, &__MODULE__.count_event/4, %{
      pid: self(),
      counters: counters,
      index: index
    })
  end

  @doc false
  def count_event(event, _measurements, _metadata, %{pid: pid} = config) do
    if Process.alive?(pid),
      do: :counters.add(config.counters, Map.fetch!(config.index, event), 1),
      else: :telemetry.detach(handler_id(pid))
  end

  defp handler_id(pid), do: {__MODULE__, pid}

  defp sample(counters, n), do: for(i <- 1..n, do: :counters.get(counters, i))

  defp recent_counts(%{samples: [latest | _] = samples, events: events}) do
    oldest = List.last(samples)

    events
    |> Enum.zip(Enum.zip_with(latest, oldest, &(&1 - &2)))
    |> Map.new()
  end

  # ---- Introspection ----------------------------------------------------------

  defp handlers do
    [:durable]
    |> :telemetry.list_handlers()
    |> Kernel.++(:telemetry.list_handlers([:durable_dashboard]))
    |> Enum.reject(&match?({__MODULE__, _pid}, &1.id))
    |> Enum.group_by(& &1.id)
    |> Enum.map(fn {id, rows} ->
      %{
        id: id,
        events: length(rows),
        names: Enum.map_join(rows, "\n", &inspect(&1.event_name)),
        module: rows |> hd() |> Map.fetch!(:function) |> Function.info(:module) |> elem(1)
      }
    end)
    |> Enum.sort_by(&inspect(&1.id))
  end

  defp metrics do
    if Code.ensure_loaded?(Durable.Telemetry) and
         function_exported?(Durable.Telemetry, :metrics, 0) do
      Enum.map(Durable.Telemetry.metrics(), fn metric ->
        %{
          name: Enum.join(metric.name, "."),
          type: metric.__struct__ |> Module.split() |> List.last() |> String.downcase(),
          tags: metric.tags
        }
      end)
    end
  end

  # ---- Render -----------------------------------------------------------------

  @impl true
  def render(assigns) do
    counts = recent_counts(assigns)

    assigns =
      assign(assigns,
        catalog: @catalog,
        fires: @fires,
        metric_types: @metric_types,
        snippet: @snippet,
        counts: counts,
        peak: counts |> Map.values() |> Enum.max(fn -> 0 end)
      )

    ~H"""
    <Layouts.app
      base_path={@base_path}
      current_path={@current_path}
      breadcrumbs={@breadcrumbs}
      durable={@durable} inbox_count={@inbox_count}
    >
      <Core.heading level={1} subtitle="What Durable emits, who is listening on this node, and how to wire it up.">
        Telemetry
      </Core.heading>

      <div class="mt-5 flex flex-wrap gap-4">
        <Charts.panel
          title="Listening now"
          sub={":telemetry.list_handlers([:durable]) on #{@node}"}
          class="flex-[1_1_360px]"
        >
          <p :if={@handlers == []} class="px-4 pb-5 pt-1 text-xs text-muted-foreground">
            Nothing is attached to Durable's events on this node — its runs aren't reaching a reporter or a log.
          </p>
          <ul>
            <li :for={h <- @handlers} class="flex items-baseline gap-3 border-t border-border px-4 py-2.5">
              <Core.status_dot status={:completed} />
              <span class="min-w-0 flex-1">
                <span
                  class="block truncate font-mono text-xs"
                  data-tip-title="Handler id"
                  data-tip={inspect(h.id)}
                >
                  {inspect(h.id)}
                </span>
                <span class="text-xs text-muted-foreground" data-tip="The module whose function handles them">
                  {inspect(h.module)}
                </span>
              </span>
              <span class="shrink-0 text-xs text-subtle-foreground" data-tip-title="Attached to" data-tip={h.names}>
                {Format.count(h.events, "event")}
              </span>
            </li>
          </ul>
        </Charts.panel>

        <Charts.panel title="Wire it up" sub="a few lines in your app; nothing to deploy" class="flex-[1_1_420px]">
          <pre class="thin-scroll mx-4 mb-3 overflow-x-auto rounded-md bg-secondary px-3.5 py-3 font-mono text-xs leading-5"><span :for={{kind, line} <- @snippet} class={["block min-h-5", kind == :comment && "text-muted-foreground"]}>{line}</span></pre>
          <p class="px-4 pb-4 text-xs text-muted-foreground">
            Spans follow the <span class="font-mono">:telemetry.span/3</span> convention — start, stop, exception, durations in native units — so tools built for Phoenix, Ecto and Oban read them as-is.
          </p>
        </Charts.panel>
      </div>

      <Charts.panel
        title="Events"
        sub="every event Durable emits · count is the last 5 minutes on this node, while this page is open"
        class="mt-4"
      >
        <div class="thin-scroll overflow-x-auto">
          <table class="w-full border-collapse">
            <thead>
              <tr class="border-y border-border text-xs text-muted-foreground">
                <th class="px-4 py-2 text-left font-medium">Event</th>
                <th class="px-4 py-2 text-left font-medium" data-tip="The numbers it carries · durations in native time units">
                  Measurements
                </th>
                <th class="px-4 py-2 text-left font-medium" data-tip="The fields it carries · “+” adds to the start event's">
                  Metadata
                </th>
                <th
                  class="w-[180px] px-4 py-2 text-right font-medium"
                  data-tip-title="Last 5 minutes"
                  data-tip="How often it fired on this node · counted only while this page is open"
                >
                  Last 5 min
                </th>
              </tr>
            </thead>
            <%= for {group, rows} <- @catalog do %>
              <tbody>
                <tr>
                  <th colspan="4" class="border-b border-border bg-secondary/50 px-4 py-1.5 text-left text-xs font-medium text-subtle-foreground">
                    {group}
                  </th>
                </tr>
                <tr :for={{event, measurements, metadata} <- rows} class="border-b border-border hover:bg-accent">
                  <td class="whitespace-nowrap px-4 py-2 font-mono text-xs" data-tip-title="Fires when" data-tip={@fires[event]}>
                    {inspect(event)}
                  </td>
                  <td class="px-4 py-2 font-mono text-xs text-subtle-foreground">{measurements}</td>
                  <td class="px-4 py-2 text-xs text-muted-foreground">{metadata}</td>
                  <td class="px-4 py-2">
                    <div class="flex items-center justify-end gap-2.5">
                      <div class="w-20"><Charts.meter value={@counts[event]} top={@peak} /></div>
                      <span class="w-14 text-right font-mono text-xs">{Format.int(@counts[event])}</span>
                    </div>
                  </td>
                </tr>
              </tbody>
            <% end %>
          </table>
        </div>
      </Charts.panel>

      <Charts.panel title="Durable.Telemetry.metrics/0" sub="Telemetry.Metrics definitions, ready for any reporter" class="mt-4">
        <p :if={is_nil(@metrics)} class="px-4 pb-5 pt-1 text-xs text-muted-foreground">
          Add <span class="font-mono">{"{:telemetry_metrics, \"~> 1.0\"}"}</span> to your deps to get these definitions.
        </p>
        <table :if={@metrics} class="w-full border-collapse">
          <thead>
            <tr class="border-y border-border text-xs text-muted-foreground">
              <th class="px-4 py-2 text-left font-medium">Metric</th>
              <th class="px-4 py-2 text-left font-medium">Type</th>
              <th class="px-4 py-2 text-left font-medium" data-tip="What each metric splits its series by">Tags</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={m <- @metrics} class="h-9 border-b border-border last:border-b-0 hover:bg-accent">
              <td class="px-4 font-mono text-xs">{m.name}</td>
              <td class="px-4 text-xs text-subtle-foreground" data-tip={@metric_types[m.type]}>{m.type}</td>
              <td class="px-4 font-mono text-xs text-muted-foreground">{Enum.join(m.tags, ", ")}</td>
            </tr>
          </tbody>
        </table>
        <p :if={@metrics} class="border-t border-border px-4 py-2.5 text-xs text-muted-foreground">
          Tags are bounded — workflow, step, queue and schedule names, never run ids.
        </p>
      </Charts.panel>
    </Layouts.app>
    """
  end
end
