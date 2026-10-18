defmodule DurableDashboard.Live.WorkflowDetailLive do
  @moduledoc """
  One workflow's health over a range: headline numbers, its structure
  annotated with each step's p95 and failure share, runs and duration over
  time, per-step performance (where the time and the failures go), errors
  grouped by signature, and the definition as compiled.

  Data: `Durable.Stats` for numbers, `module.__workflow_definition__/1` for
  structure. Route: `/workflows/:name`.
  """

  use Phoenix.LiveView

  alias Durable.PubSub, as: DurablePubSub
  alias DurableDashboard.Components.Charts
  alias DurableDashboard.Components.Core
  alias DurableDashboard.Components.Workflow.Structure
  alias DurableDashboard.Cron
  alias DurableDashboard.Format
  alias DurableDashboard.Layouts
  alias DurableDashboard.Path, as: DPath
  alias DurableDashboard.Trace

  @workflow_kinds [:workflow_completed, :workflow_failed, :workflow_cancelled]
  @refresh_ms 2_000
  @failed_statuses "failed,compensated,compensation_failed"

  @impl true
  def mount(%{"name" => name}, session, socket) do
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
       name: name,
       page_title: name,
       refresh_pending?: false
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {:noreply,
     socket
     |> assign(
       range: Charts.valid_range(params["range"]),
       current_path: URI.parse(uri).path,
       breadcrumbs: [
         %{label: "Workflows", href: DPath.workflows(socket.assigns.base_path)},
         %{label: socket.assigns.name}
       ]
     )
     |> load()}
  end

  @impl true
  def handle_info(
        {:durable_event, kind, %{workflow_name: name}},
        %{assigns: %{name: name}} = socket
      )
      when kind in @workflow_kinds do
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
    %{durable: durable, name: name, range: range} = socket.assigns
    {span, bucket} = Charts.range_window(range)
    now = DateTime.utc_now()

    window = [
      durable: durable,
      workflow: name,
      since: DateTime.add(now, -span, :second),
      until: now
    ]

    summary = Enum.find(Durable.Stats.workflows(window), &(&1.workflow == name))
    definition = definition(summary)
    steps = Durable.Stats.step_performance(window)
    stats = Durable.Stats.overview(window)

    assign(socket,
      summary: summary,
      stats: stats,
      timeline: Durable.Stats.timeline(window ++ [bucket_seconds: bucket]),
      steps: order_steps(steps, definition),
      structure: definition && Structure.build(definition, steps, stats.started),
      errors: Durable.Stats.error_groups(window),
      definition: definition,
      schedules: schedules(durable, name)
    )
  end

  defp definition(nil), do: nil

  defp definition(%{module: module, workflow: name}) do
    mod = String.to_existing_atom(module)

    case mod.__workflow_definition__(name) do
      {:ok, definition} -> definition
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp schedules(durable, name) do
    [durable: durable]
    |> Durable.list_schedules()
    |> Enum.filter(&(&1.workflow_name == name))
  rescue
    _ -> []
  end

  # Steps in definition order; ones the definition doesn't know (renamed or
  # removed since) go last.
  defp order_steps(steps, nil), do: steps

  defp order_steps(steps, definition) do
    index =
      definition.steps
      |> Enum.with_index()
      |> Map.new(fn {s, i} -> {Atom.to_string(s.name), i} end)

    Enum.sort_by(steps, &{&1.compensation, Map.get(index, &1.step, 10_000)})
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      base_path={@base_path}
      current_path={@current_path}
      breadcrumbs={@breadcrumbs}
      durable={@durable} inbox_count={@inbox_count}
    >
      <header class="flex flex-wrap items-end justify-between gap-3">
        <div class="min-w-0">
          <Core.heading level={1}>{@name}</Core.heading>
          <p :if={@summary} class="font-mono text-xs text-muted-foreground">
            {String.replace_prefix(@summary.module, "Elixir.", "")}
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <Charts.range_switch range={@range} path={DPath.workflow_detail(@base_path, @name)} />
          <Core.button navigate={DPath.workflow_executions(@base_path, @name)}>View runs</Core.button>
        </div>
      </header>

      <Core.empty_state
        :if={is_nil(@summary)}
        icon="queue"
        title={"#{@name} hasn't run yet"}
        description="Its numbers appear here once a run starts."
        class="mt-6"
      />

      <%= if @summary do %>
        <section class="mt-4 grid grid-cols-[repeat(auto-fit,minmax(170px,1fr))] gap-px overflow-hidden rounded-[10px] border border-border bg-border">
          <.kpi
            label="Runs"
            value={Format.int(@summary.started)}
            note={"#{@summary.running} running · #{@summary.waiting} waiting"}
            tip={"Runs started in the last #{@range} · running and waiting are as of now"}
          />
          <.kpi
            label="Failure rate"
            value={if @summary.finished > 0, do: Format.pct(@summary.failure_rate), else: "—"}
            note={"#{Format.int(@summary.failed)} failed"}
            tone={@summary.failure_rate > 0.05 && "text-destructive"}
            tip={"Failed ÷ finished runs · last #{@range} · red above 5%"}
            meta={"#{Format.int(@summary.failed)} of #{Format.int(@summary.finished)} finished"}
          />
          <.kpi
            label="Duration p50"
            value={Format.ms(@summary.p50_ms)}
            note="start to finish"
            tip="Half of completed runs took less · from first start to finish, waits included"
          />
          <.kpi
            label="Duration p95"
            value={Format.ms(@summary.p95_ms)}
            note={"max #{Format.ms(@stats.duration_ms.max)}"}
            tip={"95% of completed runs took less · the slowest took #{Format.ms(@stats.duration_ms.max)}"}
          />
          <.kpi
            label="Needed a retry"
            value={if @summary.started > 0, do: Format.pct(@summary.retried / @summary.started), else: "—"}
            note={"#{Format.int(@summary.retried)} runs"}
            tip="Runs with a step that failed and was tried again"
            meta={"#{Format.int(@summary.retried)} of #{Format.int(@summary.started)} runs"}
          />
        </section>

        <Charts.panel
          :if={@structure}
          title="Structure"
          sub={"the definition with the last #{@range} of traffic through it — numbers on the arrows are runs that reached the next step"}
          class="mt-4"
        >
          <:legend>
            <Charts.swatch class="bg-chart-ok">Reached</Charts.swatch>
            <Charts.swatch class="bg-chart-fail">Gave up there</Charts.swatch>
            <Charts.swatch class="bg-comp">Compensation</Charts.swatch>
          </:legend>
          <Structure.map structure={@structure} finished={@stats.finished} base_path={@base_path} workflow={@name} />
        </Charts.panel>

        <div class="mt-4 flex flex-wrap gap-4">
          <Charts.panel title="Runs" sub="finished per bucket" class="flex-[1_1_420px]">
            <:legend>
              <Charts.swatch class="bg-chart-ok">Completed</Charts.swatch>
              <Charts.swatch class="bg-chart-fail">Failed</Charts.swatch>
              <Charts.swatch class="bg-off">Cancelled</Charts.swatch>
            </:legend>
            <Charts.stacked_bars timeline={@timeline} />
          </Charts.panel>
          <Charts.panel title="Duration" sub="start to finish of completed runs, waits included" class="flex-[1_1_420px]">
            <:legend>
              <Charts.swatch class="bg-chart-1" line>p50</Charts.swatch>
              <Charts.swatch class="bg-chart-2" line>p95</Charts.swatch>
            </:legend>
            <Charts.percentile_lines timeline={@timeline} />
          </Charts.panel>
        </div>

        <Charts.panel title="Steps" sub={"where the time and the failures go · last #{@range}"} class="mt-4">
          <p :if={@steps == []} class="px-4 pb-5 pt-1 text-xs text-muted-foreground">No steps ran in the last {@range}.</p>
          <div :if={@steps != []} class="thin-scroll overflow-x-auto">
            <table class="w-full border-collapse">
              <thead>
                <tr class="border-b border-border text-xs text-muted-foreground">
                  <th
                    :for={{label, align, tip} <- step_columns()}
                    class={[
                      "px-4 py-2 font-medium",
                      if(align == :right, do: "text-right", else: "text-left"),
                      label == "p95 vs the run's p95" && "w-[18%]"
                    ]}
                  >
                    <span data-tip={tip}>{label}</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={s <- @steps} class="border-b border-border last:border-b-0">
                  <td class="px-4 py-2">
                    <span
                      class={["font-mono text-[12.5px]", s.compensation && "text-comp"]}
                      data-tip={s.compensation && "Undoes a step when a later one fails"}
                      data-tip-meta={s.step}
                    >
                      {Trace.display_name(s.step)}
                    </span>
                    <span :if={s.compensation} class="text-xs text-muted-foreground"> compensation</span>
                  </td>
                  <td class="px-4 text-right font-mono">{Format.int(s.runs)}</td>
                  <td class="px-4 text-right font-mono">{Format.int(s.attempts)}</td>
                  <td class={["px-4 text-right font-mono", share(s) > 0.05 && "text-destructive"]}>
                    <span data-tip={"#{Format.int(s.failed_attempts)} of #{Format.int(s.attempts)} attempts failed"}>
                      {Format.pct(share(s))}
                    </span>
                  </td>
                  <td class={["px-4 text-right font-mono", retried(s) > 0.1 && "text-warning"]}>
                    <span data-tip={"#{Format.int(s.retried_runs)} of #{Format.int(s.runs)} runs tried it more than once"}>
                      {Format.pct(retried(s))}
                    </span>
                  </td>
                  <td class="px-4 text-right font-mono text-subtle-foreground">{Format.ms(s.p50_ms)}</td>
                  <td class="px-4 text-right font-mono">{Format.ms(s.p95_ms)}</td>
                  <td class="px-4 text-right font-mono text-muted-foreground">{Format.ms(s.max_ms)}</td>
                  <td class="px-4" data-tip={meter_tip(s, @summary)}>
                    <Charts.meter value={s.p95_ms} top={@summary.p95_ms} />
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </Charts.panel>

        <div class="mt-4 flex flex-wrap gap-4">
          <Charts.panel title="Errors" sub="grouped by type + message, numbers stripped" class="flex-[3_1_520px]">
            <p :if={@errors == []} class="px-4 pb-5 pt-1 text-xs text-muted-foreground">No failures in the last {@range}.</p>
            <div
              :for={e <- @errors}
              class="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-3 border-t border-border px-4 py-3"
            >
              <div class="flex min-w-0 flex-col gap-0.5">
                <span
                  class="truncate font-mono text-[12.5px]"
                  data-tip-title={e.type || "Error"}
                  data-tip={e.message}
                  data-tip-meta={"at #{e.step || "—"}"}
                >
                  <span :if={e.type} class="text-destructive">{e.type}:</span> {e.message}
                </span>
                <span class="text-xs text-muted-foreground">
                  {Trace.display_name(e.step || "—")} · {Format.count(e.count, "run")} · last
                  <Core.relative_time at={e.last_at} /><span
                    :if={e.rolled_back > 0}
                    data-tip="Runs whose compensations undid the steps before the failure"
                  > · {e.rolled_back} rolled back</span>
                </span>
              </div>
              <Core.button
                size="sm"
                navigate={DPath.workflow_executions(@base_path, @name) <> "?" <> URI.encode_query(status: failed_statuses(), q: "step:#{e.step}")}
                data-tip={"Its failed runs that stopped at #{Trace.display_name(e.step || "—")}"}
              >
                View runs
              </Core.button>
            </div>
          </Charts.panel>

          <Charts.panel title="Definition" sub="as compiled" class="flex-[2_1_360px]">
            <dl class="grid grid-cols-[110px_minmax(0,1fr)] gap-x-3 gap-y-2 px-4 pb-4 text-[12.5px]">
              <dt data-tip="Top-level steps · a parallel or branch block counts once · compensations undo a step when a later one fails">
                <Core.label>Steps</Core.label>
              </dt>
              <dd>{definition_summary(@definition)}</dd>
              <dt data-tip="A deadline for the whole run, waits included · past it, the run fails before its next step and compensates">
                <Core.label>Timeout</Core.label>
              </dt>
              <dd class="font-mono text-xs">
                {if ms = @definition && @definition.opts[:timeout], do: Format.duration(ms), else: "none"}
              </dd>
              <dt data-tip="The queue its jobs go through · set with queue: on the workflow">
                <Core.label>Queue</Core.label>
              </dt>
              <dd class="font-mono text-xs">{(@definition && @definition.opts[:queue]) || "default"}</dd>
              <dt data-tip="Steps with their own retry: max attempts and backoff · the rest run once">
                <Core.label>Retries</Core.label>
              </dt>
              <dd class="font-mono text-xs">{retries(@definition)}</dd>
              <dt data-tip="Schedules that start this workflow">
                <Core.label>Schedules</Core.label>
              </dt>
              <dd>
                <span :if={@schedules == []} class="text-muted-foreground">none</span>
                <.link
                  :for={s <- @schedules}
                  navigate={DPath.schedule(@base_path, s.name)}
                  class="block font-mono text-xs text-primary hover:underline"
                  data-tip-title={"Schedule #{s.name}"}
                  data-tip={schedule_tip(s)}
                >
                  {s.name} · {s.cron_expression}
                </.link>
              </dd>
              <dt data-tip="The file it was compiled from">
                <Core.label>Source</Core.label>
              </dt>
              <dd class="break-all font-mono text-xs text-subtle-foreground">{source(@summary)}</dd>
            </dl>
          </Charts.panel>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :note, :string, default: nil
  attr :tone, :any, default: nil
  attr :tip, :string, default: nil
  attr :meta, :string, default: nil

  defp kpi(assigns) do
    ~H"""
    <div
      class="flex min-w-0 flex-col gap-0.5 bg-card px-4 py-3"
      data-tip-title={@tip && @label}
      data-tip={@tip}
      data-tip-meta={@meta}
    >
      <Core.label>{@label}</Core.label>
      <span class={["font-mono text-[22px] font-medium tracking-tight", @tone]}>{@value}</span>
      <span :if={@note} class="text-xs text-muted-foreground">{@note}</span>
    </div>
    """
  end

  defp step_columns do
    [
      {"Step", :left, nil},
      {"Runs", :right, "Runs that reached this step"},
      {"Attempts", :right, "Times it ran, retries included"},
      {"Failed", :right, "Failed attempts ÷ attempts · red above 5%"},
      {"Retried", :right, "Runs that needed more than one attempt at it · amber above 10%"},
      {"p50", :right, "Half of its attempts took less"},
      {"p95", :right, "95% of its attempts took less"},
      {"Max", :right, "Its slowest attempt"},
      {"p95 vs the run's p95", :left, "How much of a slow run this step takes"}
    ]
  end

  defp meter_tip(step, summary) do
    pct =
      if summary.p95_ms in [nil, 0],
        do: "—",
        else: Format.pct((step.p95_ms || 0) / summary.p95_ms)

    "p95 #{Format.ms(step.p95_ms)} · #{pct} of the run's p95 (#{Format.ms(summary.p95_ms)})"
  end

  defp schedule_tip(schedule) do
    words = Cron.describe(schedule.cron_expression) || schedule.cron_expression
    "#{words} · #{schedule.timezone} · #{if schedule.enabled, do: "on", else: "off"}"
  end

  defp share(%{attempts: 0}), do: 0.0
  defp share(%{failed_attempts: f, attempts: a}), do: f / a

  defp retried(%{runs: 0}), do: 0.0
  defp retried(%{retried_runs: r, runs: n}), do: r / n

  defp failed_statuses, do: @failed_statuses

  defp definition_summary(nil), do: "—"

  defp definition_summary(definition) do
    top = Enum.count(definition.steps, &(not String.contains?(Atom.to_string(&1.name), "__")))
    comps = map_size(definition.compensations)

    "#{Format.count(top, "step")}" <>
      if(comps > 0, do: " · #{Format.count(comps, "compensation")}", else: "")
  end

  defp retries(nil), do: "—"

  defp retries(definition) do
    custom =
      for %{name: name, opts: %{retry: %{max_attempts: n} = retry}} <- definition.steps do
        "#{Trace.display_name(Atom.to_string(name))}: #{n}, #{retry[:backoff] || :exponential}"
      end

    if custom == [], do: "default (1 attempt)", else: Enum.join(custom, " · ")
  end

  defp source(%{module: module}) do
    mod = String.to_existing_atom(module)
    path = mod.module_info(:compile)[:source] |> to_string()
    Path.relative_to_cwd(path)
  rescue
    _ -> "—"
  end
end
