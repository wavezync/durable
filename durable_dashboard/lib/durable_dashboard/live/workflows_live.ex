defmodule DurableDashboard.Live.WorkflowsLive do
  @moduledoc """
  The workflow catalog: every workflow that has run, with its numbers for the
  range — runs, failure rate, p50/p95 duration, how often it needs a retry,
  and what's running or waiting now. Busiest first; a row opens the workflow
  page. Data: `Durable.Stats.workflows/1`.
  """

  use Phoenix.LiveView

  alias Durable.PubSub, as: DurablePubSub
  alias DurableDashboard.Components.Charts
  alias DurableDashboard.Components.Core
  alias DurableDashboard.Format
  alias DurableDashboard.Layouts
  alias DurableDashboard.Path, as: DPath

  @workflow_kinds [:workflow_started, :workflow_completed, :workflow_failed, :workflow_cancelled]
  @refresh_ms 2_000

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
       page_title: "Workflows",
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
       breadcrumbs: [%{label: "Workflows"}]
     )
     |> load()}
  end

  @impl true
  def handle_info({:durable_event, kind, _payload}, socket) when kind in @workflow_kinds do
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

  defp load(socket) do
    {span, _bucket} = Charts.range_window(socket.assigns.range)
    now = DateTime.utc_now()

    rows =
      Durable.Stats.workflows(
        durable: socket.assigns.durable,
        since: DateTime.add(now, -span, :second),
        until: now
      )

    assign(socket, rows: rows)
  end

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
        <Core.heading level={1} subtitle={"#{Format.count(length(@rows), "workflow")} · numbers for the last #{@range}"}>
          Workflows
        </Core.heading>
        <Charts.range_switch range={@range} path={DPath.workflows(@base_path)} />
      </header>

      <section class="mt-4 overflow-hidden rounded-[10px] border border-border bg-card">
        <Core.empty_state
          :if={@rows == []}
          icon="queue"
          title="No workflows have run yet"
          description="Start a workflow with Durable.start/3 and it will show up here."
        />
        <div :if={@rows != []} class="thin-scroll overflow-x-auto">
          <table class="w-full border-collapse">
            <thead>
              <tr class="border-b border-border text-xs text-muted-foreground">
                <th
                  :for={{label, align, tip} <- columns(@range)}
                  class={["px-4 py-2.5 font-medium", if(align == :right, do: "text-right", else: "text-left")]}
                >
                  <span data-tip={tip}>{label}</span>
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={w <- @rows} class="border-b border-border last:border-b-0 hover:bg-accent">
                <td class="px-4 py-2.5">
                  <.link
                    navigate={DPath.workflow_detail(@base_path, w.workflow)}
                    class="flex flex-col leading-tight"
                    data-tip="Open its structure, timings and errors"
                    data-tip-meta={strip_elixir(w.module)}
                  >
                    <span class="font-medium">{w.workflow}</span>
                    <span class="font-mono text-xs text-muted-foreground">{strip_elixir(w.module)}</span>
                  </.link>
                </td>
                <td class="px-4 text-right font-mono">
                  <span data-tip={"#{Format.int(w.started)} started · #{Format.int(w.finished)} finished"}>
                    {Format.int(w.started)}
                  </span>
                </td>
                <td class={["px-4 text-right font-mono", w.failure_rate > 0.05 && "text-destructive"]}>
                  <span data-tip={failure_tip(w)}>
                    {if w.finished > 0, do: Format.pct(w.failure_rate), else: "—"}
                  </span>
                </td>
                <td class="px-4 text-right font-mono text-subtle-foreground">{Format.ms(w.p50_ms)}</td>
                <td class="px-4 text-right font-mono">{Format.ms(w.p95_ms)}</td>
                <td class={["px-4 text-right font-mono", retry_share(w) > 0.1 && "text-warning"]}>
                  <span data-tip={w.started > 0 && "#{Format.int(w.retried)} of #{Format.int(w.started)} runs had a step fail and retry"}>
                    {if w.started > 0, do: Format.pct(retry_share(w)), else: "—"}
                  </span>
                </td>
                <td class="px-4">
                  <span class="flex flex-wrap gap-1.5">
                    <Core.status_pill :if={w.running > 0} status={:running} />
                    <span :if={w.running > 1} class="font-mono text-xs text-subtle-foreground">×{w.running}</span>
                    <Core.status_pill :if={w.waiting > 0} status={:waiting} />
                    <span :if={w.waiting > 1} class="font-mono text-xs text-subtle-foreground">×{w.waiting}</span>
                    <span :if={w.running == 0 and w.waiting == 0} class="text-xs text-muted-foreground">idle</span>
                  </span>
                </td>
                <td class="whitespace-nowrap px-4 text-right text-xs text-muted-foreground">
                  <Core.relative_time at={w.last_run_at} />
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp columns(range) do
    [
      {"Workflow", :left, nil},
      {"Runs", :right, "Runs started in the last #{range}"},
      {"Failure rate", :right, "Failed ÷ finished runs · last #{range} · red above 5%"},
      {"p50", :right, "Median time of a completed run"},
      {"p95", :right, "95% of completed runs finished within this"},
      {"Needed a retry", :right,
       "Runs with a step that failed and was retried · amber above 10%"},
      {"Now", :left, "Running or waiting right now"},
      {"Last run", :right, "When its newest run started"}
    ]
  end

  defp failure_tip(%{finished: 0}), do: "No finished runs yet"

  defp failure_tip(w),
    do: "#{Format.int(w.failed)} of #{Format.int(w.finished)} finished runs failed"

  defp retry_share(%{started: 0}), do: 0.0
  defp retry_share(%{retried: r, started: n}), do: r / n

  defp strip_elixir(nil), do: ""
  defp strip_elixir(module), do: String.replace_prefix(module, "Elixir.", "")
end
