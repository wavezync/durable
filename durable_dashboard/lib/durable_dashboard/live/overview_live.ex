defmodule DurableDashboard.Live.OverviewLive do
  @moduledoc """
  Health at a glance, over a time range (1h / 24h / 7d / 30d in `?range=`):
  headline numbers with change against the previous window, runs finished
  and failure rate over time, the workflows that are failing and why, queue
  pressure, the slowest steps, and a live feed of lifecycle events.

  Numbers come from `Durable.Stats` (Postgres — true across nodes). Lifecycle
  events refresh them, throttled to one reload per #{2} seconds.
  """

  use Phoenix.LiveView

  alias Durable.PubSub, as: DurablePubSub
  alias DurableDashboard.Components.Charts
  alias DurableDashboard.Components.Core
  alias DurableDashboard.Format
  alias DurableDashboard.Layouts
  alias DurableDashboard.Path, as: DPath
  alias DurableDashboard.Trace

  @workflow_kinds [
    :workflow_started,
    :workflow_resumed,
    :workflow_waiting,
    :workflow_completed,
    :workflow_failed,
    :workflow_cancelled,
    :workflow_retried
  ]

  @refresh_ms 2_000
  @feed_size 10

  @impl true
  def mount(_params, session, socket) do
    config = session["config"]

    if connected?(socket) do
      if durable_config = Durable.Config.get_safe(config.durable) do
        DurablePubSub.subscribe(durable_config, DurablePubSub.workflows_topic(durable_config))
      end
    end

    {:ok,
     assign(socket,
       config: config,
       base_path: config.base_path,
       durable: config.durable,
       page_title: "Overview",
       feed: [],
       refresh_pending?: false
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    range = Charts.valid_range(params["range"])

    {:noreply,
     socket
     |> assign(
       range: range,
       current_path: URI.parse(uri).path,
       breadcrumbs: [%{label: "Overview"}]
     )
     |> load()}
  end

  @impl true
  def handle_info({:durable_event, kind, payload}, socket) when kind in @workflow_kinds do
    socket = update(socket, :feed, &Enum.take([feed_item(kind, payload) | &1], @feed_size))

    if socket.assigns.refresh_pending? do
      {:noreply, socket}
    else
      Process.send_after(self(), :refresh, @refresh_ms)
      {:noreply, assign(socket, refresh_pending?: true)}
    end
  end

  def handle_info(:refresh, socket),
    do: {:noreply, socket |> assign(refresh_pending?: false) |> load()}

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ============================================================================
  # Data
  # ============================================================================

  defp load(socket) do
    %{durable: durable, range: range} = socket.assigns
    {span, bucket} = Charts.range_window(range)
    now = DateTime.utc_now()
    since = DateTime.add(now, -span, :second)
    window = [durable: durable, since: since, until: now]

    stats = Durable.Stats.overview(window)

    previous =
      Durable.Stats.overview(
        durable: durable,
        since: DateTime.add(since, -span, :second),
        until: since
      )

    timeline = Durable.Stats.timeline(window ++ [bucket_seconds: bucket])

    slowest =
      window
      |> Durable.Stats.step_performance()
      |> Enum.reject(&(&1.compensation or is_nil(&1.p95_ms)))
      |> Enum.sort_by(& &1.p95_ms, :desc)
      |> Enum.take(5)

    assign(socket,
      stats: stats,
      previous: previous,
      timeline: timeline,
      failing: Durable.Stats.failing_workflows(window),
      slowest: slowest,
      queues: Durable.Stats.queues(durable: durable),
      nodes: Durable.list_nodes(durable: durable),
      workflows: length(Durable.Query.list_workflows(durable: durable))
    )
  end

  defp feed_item(kind, payload) do
    %{
      at: DateTime.utc_now(),
      id: payload[:id],
      workflow: payload[:workflow_name],
      status: feed_status(kind),
      text: feed_text(kind, payload)
    }
  end

  defp feed_status(:workflow_completed), do: :completed
  defp feed_status(:workflow_failed), do: :failed
  defp feed_status(:workflow_cancelled), do: :cancelled
  defp feed_status(:workflow_waiting), do: :waiting
  defp feed_status(_kind), do: :running

  defp feed_text(:workflow_started, _p), do: "started"
  defp feed_text(:workflow_resumed, p), do: "running #{step(p)}"
  defp feed_text(:workflow_waiting, p), do: "waiting at #{step(p)}"
  defp feed_text(:workflow_completed, _p), do: "completed"
  defp feed_text(:workflow_failed, p), do: "failed at #{step(p)}"
  defp feed_text(:workflow_cancelled, _p), do: "cancelled"
  defp feed_text(:workflow_retried, p), do: "retried from #{step(p)}"

  defp step(p), do: Trace.display_name(p[:current_step] || "start")

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, kpis: kpis(assigns), spark_labels: Charts.bucket_labels(assigns.timeline))

    ~H"""
    <Layouts.app
      base_path={@base_path}
      current_path={@current_path}
      breadcrumbs={@breadcrumbs}
      durable={@durable} inbox_count={@inbox_count}
    >
      <header class="flex flex-wrap items-end justify-between gap-3">
        <Core.heading
          level={1}
          subtitle={"#{Format.count(@workflows, "workflow")} · #{Format.count(length(@queues), "queue")} · #{Format.count(alive(@nodes), "node")} · updated live"}
        >
          Overview
        </Core.heading>
        <Charts.range_switch range={@range} path={DPath.overview(@base_path)} />
      </header>

      <section
        class="mt-4 grid grid-cols-[repeat(auto-fit,minmax(190px,1fr))] gap-px overflow-hidden rounded-[10px] border border-border bg-border"
        aria-label="Key metrics"
      >
        <div :for={k <- @kpis} class="flex min-w-0 flex-col gap-0.5 bg-card px-4 pb-3 pt-3.5">
          <div class="flex flex-col gap-0.5" data-tip-title={k.label} data-tip={k.tip} data-tip-meta={k.tip_meta}>
            <Core.label>{k.label}</Core.label>
            <span class={["font-mono text-2xl font-medium tracking-tight", k.tone]}>{k.value}</span>
            <span class={["text-xs", k.delta_tone]}>{k.delta}</span>
          </div>
          <Charts.sparkline
            :if={k.spark}
            values={k.spark}
            labels={@spark_labels}
            format={k.spark_format}
            class={"mt-1.5 " <> k.spark_tone}
          />
        </div>
      </section>

      <div class="mt-4 flex flex-wrap gap-4">
        <Charts.panel title="Runs finished" sub={Format.count(finished_total(@stats), "run")} class="flex-[2_1_560px]">
          <:legend>
            <Charts.swatch class="bg-chart-ok">Completed</Charts.swatch>
            <Charts.swatch class="bg-chart-fail">Failed</Charts.swatch>
            <Charts.swatch class="bg-off">Cancelled</Charts.swatch>
          </:legend>
          <Charts.stacked_bars timeline={@timeline} />
        </Charts.panel>
        <Charts.panel title="Failure rate" sub="failed ÷ finished, per bucket" class="flex-[1_1_340px]">
          <Charts.rate_line timeline={@timeline} />
        </Charts.panel>
      </div>

      <div class="mt-4 flex flex-wrap gap-4">
        <Charts.panel title="Failing workflows" sub={"grouped by error · last #{@range}"} class="flex-[2_1_560px]">
          <:action>
            <.link navigate={DPath.executions(@base_path) <> "?status=failed,compensated,compensation_failed"} class="text-xs font-medium text-primary hover:underline">
              All failed runs →
            </.link>
          </:action>
          <p :if={@failing == []} class="px-4 pb-5 pt-1 text-xs text-muted-foreground">
            Nothing failed in the last {@range}.
          </p>
          <table :if={@failing != []} class="w-full border-collapse">
            <thead>
              <tr class="border-b border-border text-left text-xs text-muted-foreground">
                <th class="px-4 py-2 font-medium">Workflow</th>
                <th class="px-4 py-2 text-right font-medium" data-tip={"Runs that ended failed, compensated or compensation failed · last #{@range}"}>Failed</th>
                <th class="px-4 py-2 text-right font-medium" data-tip="Failed ÷ finished runs of the workflow · red above 5%">Rate</th>
                <th class="px-4 py-2 font-medium" data-tip="Its most common error · numbers are ignored, so messages that differ only by a count or an id group together">Top error</th>
                <th class="px-4 py-2 text-right font-medium">Last</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={f <- @failing} class="border-b border-border last:border-b-0 hover:bg-accent">
                <td class="px-4 py-2">
                  <.link navigate={DPath.workflow_executions(@base_path, f.workflow) <> "?status=failed,compensated,compensation_failed"} class="flex flex-col leading-tight">
                    <span class="font-medium">{f.workflow}</span>
                    <span :if={f.top_error && f.top_error.step} class="text-xs text-muted-foreground">
                      at <span class="font-mono">{Trace.display_name(f.top_error.step)}</span>
                    </span>
                  </.link>
                </td>
                <td class="px-4 text-right font-mono">{Format.int(f.failed)}</td>
                <td
                  class={["px-4 text-right font-mono", f.failure_rate > 0.05 && "text-destructive"]}
                  data-tip={"#{Format.int(f.failed)} of #{Format.int(f.finished)} finished runs"}
                >
                  {Format.pct(f.failure_rate)}
                </td>
                <td
                  class="max-w-[300px] truncate px-4 font-mono text-xs text-subtle-foreground"
                  data-tip-title={f.top_error && f.top_error.type}
                  data-tip={f.top_error && f.top_error.message}
                  data-tip-meta={f.top_error && top_error_meta(f)}
                >
                  {f.top_error && error_text(f.top_error)}
                </td>
                <td class="whitespace-nowrap px-4 text-right text-xs text-muted-foreground">
                  <Core.relative_time at={f.last_failed_at} />
                </td>
              </tr>
            </tbody>
          </table>
        </Charts.panel>

        <Charts.panel title="Queues" sub="right now, across all nodes" class="flex-[1_1_340px]">
          <:action>
            <.link navigate={DPath.queues(@base_path)} class="text-xs font-medium text-primary hover:underline">
              Queues & nodes →
            </.link>
          </:action>
          <ul>
            <li :for={q <- @queues} class="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-3 border-t border-border px-4 py-2.5">
              <span class="flex min-w-0 flex-col leading-tight">
                <span class="font-mono font-medium">{q.queue}</span>
                <span class={["text-xs", queue_note_tone(q)]} data-tip={queue_note_tip(q)}>{queue_note(q)}</span>
              </span>
              <span
                class="flex flex-col text-right leading-tight"
                data-tip="Due now, waiting for a free worker"
                data-tip-meta={"wait p95 #{Format.ms(q.wait_p95_ms)} · last hour"}
              >
                <span class="font-mono">{Format.int(q.ready)}</span>
                <span class="text-xs text-muted-foreground">ready</span>
              </span>
            </li>
          </ul>
        </Charts.panel>
      </div>

      <div class="mt-4 flex flex-wrap gap-4">
        <Charts.panel title="Slowest steps" sub={"p95 active time — waits excluded · last #{@range}"} class="flex-[2_1_560px]">
          <p :if={@slowest == []} class="px-4 pb-5 pt-1 text-xs text-muted-foreground">No steps ran in the last {@range}.</p>
          <table :if={@slowest != []} class="w-full border-collapse">
            <thead>
              <tr class="border-b border-border text-left text-xs text-muted-foreground">
                <th class="px-4 py-2 font-medium">Step</th>
                <th class="px-4 py-2 text-right font-medium" data-tip="Every try at the step, retries included">Attempts</th>
                <th class="px-4 py-2 text-right font-medium" data-tip="Half the attempts took less · active time, waits excluded">p50</th>
                <th class="px-4 py-2 text-right font-medium" data-tip="95% of attempts took less · active time, waits excluded">p95</th>
                <th class="w-[28%] px-4 py-2 font-medium" data-tip="Each step's p95 against the slowest step's">p95 vs slowest</th>
                <th class="px-4 py-2 text-right font-medium" data-tip="Share of runs that needed more than one attempt at the step · amber above 10%">Retried</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={s <- @slowest} class="border-b border-border last:border-b-0">
                <td class="px-4 py-2">
                  <span class="text-xs text-muted-foreground">{s.workflow} › </span>
                  <span class="font-mono text-[12.5px]" data-tip={step_tip(s)} data-tip-meta={s.step}>
                    {Trace.display_name(s.step)}
                  </span>
                </td>
                <td class="px-4 text-right font-mono">{Format.int(s.attempts)}</td>
                <td class="px-4 text-right font-mono text-subtle-foreground">{Format.ms(s.p50_ms)}</td>
                <td class="px-4 text-right font-mono">{Format.ms(s.p95_ms)}</td>
                <td class="px-4">
                  <Charts.meter value={s.p95_ms} top={hd(@slowest).p95_ms} tip={slowest_tip(s, hd(@slowest))} />
                </td>
                <td
                  class={["px-4 text-right font-mono", retry_share(s) > 0.1 && "text-warning"]}
                  data-tip={"#{Format.int(s.retried_runs)} of #{Format.int(s.runs)} runs"}
                >
                  {Format.pct(retry_share(s))}
                </td>
              </tr>
            </tbody>
          </table>
        </Charts.panel>

        <Charts.panel title="Live activity" sub="lifecycle events as they happen" class="flex-[1_1_340px]">
          <p :if={@feed == []} class="px-4 pb-5 pt-1 text-xs text-muted-foreground">
            Waiting for the next event…
          </p>
          <ol>
            <li :for={e <- @feed} class="grid grid-cols-[auto_14px_minmax(0,1fr)] items-baseline gap-2 border-t border-border px-4 py-2 text-[12.5px]">
              <Core.local_time at={e.at} format="time" class="whitespace-nowrap font-mono text-[11.5px] tabular-nums text-muted-foreground" />
              <span data-tip-title={e.text} data-tip={Core.status_help(e.status)}>
                <Core.status_dot status={e.status} />
              </span>
              <.link navigate={DPath.execution(@base_path, e.id)} class="min-w-0" data-tip="Open the run" data-tip-meta={e.id}>
                <span class="font-semibold">{e.workflow}</span>
                <span class="font-mono text-xs text-muted-foreground">{String.slice(e.id || "", 0, 8)}</span>
                <span class="text-subtle-foreground">{e.text}</span>
              </.link>
            </li>
          </ol>
        </Charts.panel>
      </div>
    </Layouts.app>
    """
  end

  # ============================================================================
  # View model
  # ============================================================================

  defp kpis(%{stats: s, previous: p, timeline: t, queues: queues}) do
    failure_up? = s.failure_rate > p.failure_rate and s.failure_rate > 0

    [
      %{
        label: "Runs started",
        value: Format.int(s.started),
        delta: (Format.change(s.started, p.started) || "no earlier data") <> " vs previous",
        delta_tone: "text-muted-foreground",
        tone: nil,
        spark: Enum.map(t, & &1.started),
        spark_tone: "text-subtle-foreground",
        spark_format: &"#{Format.int(&1)} started",
        tip: "Runs created in the window · child runs included",
        tip_meta: "#{Format.int(p.started)} in the window before"
      },
      %{
        label: "Failure rate",
        value: Format.pct(s.failure_rate),
        delta:
          "#{Format.pt_change(s.failure_rate, p.failure_rate)} · #{Format.int(failed_total(s))} failed",
        delta_tone: if(failure_up?, do: "text-destructive", else: "text-muted-foreground"),
        tone: nil,
        spark: Enum.map(t, & &1.failure_rate),
        spark_tone: "text-chart-fail",
        spark_format: &"#{Format.pct(&1)} failed",
        tip: "Failed, compensated or compensation-failed ÷ finished runs",
        tip_meta:
          "#{Format.int(failed_total(s))} of #{Format.int(finished_total(s))} finished · #{Format.pct(p.failure_rate)} before"
      },
      %{
        label: "Duration p95",
        value: Format.ms(s.duration_ms.p95),
        delta: "p50 #{Format.ms(s.duration_ms.p50)}",
        delta_tone: "text-muted-foreground",
        tone: nil,
        spark: Enum.map(t, & &1.p95_ms),
        spark_tone: "text-subtle-foreground",
        spark_format: &"p95 #{Format.ms(&1)}",
        tip: "95% of completed runs took less · start to finish",
        tip_meta: "max #{Format.ms(s.duration_ms.max)} · #{Format.ms(p.duration_ms.p95)} before"
      },
      %{
        label: "Queue wait p95",
        value: Format.ms(s.queue_wait_ms.p95),
        delta: "scheduled → started",
        delta_tone: "text-muted-foreground",
        tone: nil,
        spark: nil,
        spark_tone: nil,
        spark_format: nil,
        tip: "95% of runs waited less between being due and a worker starting them",
        tip_meta:
          "p50 #{Format.ms(s.queue_wait_ms.p50)} · #{Format.ms(p.queue_wait_ms.p95)} before"
      },
      %{
        label: "Backlog",
        value: Format.int(s.backlog),
        delta: "ready to run now · #{Format.count(length(queues), "queue")}",
        delta_tone: "text-muted-foreground",
        tone: nil,
        spark: nil,
        spark_tone: nil,
        spark_format: nil,
        tip: "Runs due now that no worker has claimed yet",
        tip_meta: Enum.map_join(queues, " · ", &"#{&1.queue} #{Format.int(&1.ready)}")
      },
      %{
        label: "Waiting",
        value: Format.int(s.waiting.input + s.waiting.event + s.waiting.sleeping),
        delta:
          "#{s.waiting.event} event · #{s.waiting.input} input · #{s.waiting.sleeping} sleep",
        delta_tone: if(s.waiting.input > 0, do: "text-warning", else: "text-muted-foreground"),
        tone: nil,
        spark: nil,
        spark_tone: nil,
        spark_format: nil,
        tip: "Paused right now on an event, a person's input (the Inbox) or a sleep",
        tip_meta: nil
      }
    ]
  end

  defp finished_total(stats), do: stats.finished |> Map.values() |> Enum.sum()

  defp failed_total(stats),
    do:
      [:failed, :compensated, :compensation_failed]
      |> Enum.map(&Map.get(stats.finished, &1, 0))
      |> Enum.sum()

  defp alive(nodes), do: Enum.count(nodes, &(&1.status == :alive))

  defp queue_note(%{paused: true}), do: "paused"
  defp queue_note(%{running: r, scheduled: s}), do: "#{r} running · #{s} scheduled"

  defp queue_note_tip(%{paused: true}),
    do: "No node claims new runs from it · running ones finish · resume on Queues & nodes"

  defp queue_note_tip(_queue),
    do:
      "Running: claimed by a worker now\nScheduled: set to start later — sleeps, backoffs, delays"

  defp queue_note_tone(%{paused: true}), do: "text-warning"
  defp queue_note_tone(_queue), do: "text-muted-foreground"

  defp error_text(%{type: nil, message: m}), do: m
  defp error_text(%{type: t, message: m}), do: "#{t}: #{m}"

  defp top_error_meta(%{top_error: %{count: count, step: step}, failed: failed}) do
    at = if step, do: " · at #{Trace.display_name(step)}", else: ""
    "#{Format.int(count)} of #{Format.int(failed)} failures#{at}"
  end

  defp step_tip(s), do: "#{s.workflow} · #{Format.int(s.runs)} runs reached it"

  defp slowest_tip(s, slowest) when s == slowest, do: "The slowest step"

  defp slowest_tip(s, slowest),
    do:
      "#{Format.pct(s.p95_ms / max(slowest.p95_ms, 1))} of the slowest · #{Trace.display_name(slowest.step)} #{Format.ms(slowest.p95_ms)}"

  defp retry_share(%{runs: 0}), do: 0.0
  defp retry_share(%{retried_runs: r, runs: n}), do: r / n
end
