defmodule DurableDashboard.Live.QueuesLive do
  @moduledoc """
  Queues and the nodes that work them. Per queue: how busy it is against the
  cluster's capacity, the ready backlog now and over the last hour, its age,
  throughput and queue wait — with pause/resume, which applies to every node.
  Per node: whether it's heartbeating, what it's running and which queues it
  polls. Below, the operations record: recovered runs, fenced workers, queue
  pauses and the like over the last day.

  Data: `Durable.Stats.queues/1`, `Durable.Stats.queue_history/1`,
  `Durable.list_nodes/1` and `Durable.Activity.list/1`, polled every few
  seconds — node heartbeats don't publish events.
  """

  use Phoenix.LiveView

  alias DurableDashboard.Access
  alias DurableDashboard.Components.Charts
  alias DurableDashboard.Components.Core
  alias DurableDashboard.Format
  alias DurableDashboard.Layouts
  alias DurableDashboard.Path, as: DPath

  @refresh_ms 3_000

  @impl true
  def mount(_params, session, socket) do
    config = session["config"]
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)

    {:ok,
     socket
     |> assign(
       config: config,
       base_path: config.base_path,
       durable: config.durable,
       page_title: "Queues & nodes",
       breadcrumbs: [%{label: "Queues & nodes"}],
       action_error: nil
     )
     |> load()}
  end

  @impl true
  def handle_params(_params, uri, socket),
    do: {:noreply, assign(socket, current_path: URI.parse(uri).path)}

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("toggle", %{"queue" => queue}, socket) do
    durable = socket.assigns.durable
    paused? = Enum.any?(socket.assigns.queues, &(&1.queue == queue and &1.paused))
    action = if paused?, do: :resume_queue, else: :pause_queue

    result =
      Access.perform(socket, :operator, action, [queue], fn ->
        apply(Durable, action, [queue, [durable: durable, by: socket.assigns[:user]]])
      end)

    error = if result == {:error, :forbidden}, do: "You don't have permission to do that."
    {:noreply, socket |> assign(action_error: error) |> load()}
  end

  defp load(socket) do
    durable = socket.assigns.durable
    durable_config = Durable.Config.get_safe(durable)
    nodes = if durable_config, do: Durable.list_nodes(durable: durable), else: []
    queues = if durable_config, do: Durable.Stats.queues(durable: durable), else: []
    alive = Enum.filter(nodes, &(&1.status == :alive))
    now = DateTime.utc_now()

    history =
      if durable_config,
        do:
          Durable.Stats.queue_history(durable: durable, since: DateTime.add(now, -3_600, :second)),
        else: %{}

    assign(socket,
      nodes: nodes,
      alive: length(alive),
      this_node: durable_config && durable_config.node_id,
      queues: Enum.map(queues, &with_capacity(&1, alive, durable_config)),
      backlog: Map.new(history, fn {queue, samples} -> {queue, per_minute(samples, now)} end),
      backlog_labels: minute_labels(now),
      activity:
        if(durable_config, do: Durable.Activity.list(durable: durable, limit: 50), else: []),
      now: now
    )
  end

  # The last hour as 60 ready counts, oldest first; a minute nobody sampled
  # (no node was up) reads as nil.
  defp per_minute(samples, now) do
    by_minute = Map.new(samples, &{DateTime.to_unix(&1.at), &1.ready})
    current = div(DateTime.to_unix(now), 60) * 60

    # Start at the first sample, so a fresh install isn't drawn as an hour of 0s.
    for(m <- 59..0//-1, do: Map.get(by_minute, current - m * 60))
    |> Enum.drop_while(&is_nil/1)
  end

  # The 60 minutes `per_minute/2` covers, as tooltip titles, oldest first.
  defp minute_labels(now) do
    current = div(DateTime.to_unix(now), 60) * 60

    for m <- 59..0//-1,
        do: current |> Kernel.-(m * 60) |> DateTime.from_unix!() |> Calendar.strftime("%H:%M UTC")
  end

  # Capacity is an estimate: this node's concurrency for the queue times the
  # live nodes that poll it. Nodes don't report their own concurrency.
  defp with_capacity(queue, alive, config) do
    pollers = Enum.count(alive, &(queue.queue in &1.queues))

    concurrency =
      Enum.find_value(config.queues, 0, fn {name, opts} ->
        to_string(name) == queue.queue && Keyword.get(opts, :concurrency, 0)
      end)

    Map.merge(queue, %{pollers: pollers, capacity: pollers * concurrency})
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, can_operate?: Access.allowed?(assigns.access, :operator))

    ~H"""
    <Layouts.app
      base_path={@base_path}
      current_path={@current_path}
      breadcrumbs={@breadcrumbs}
      durable={@durable} inbox_count={@inbox_count}
    >
      <Core.heading
        level={1}
        subtitle="Every node polls the queues it runs and claims work from Postgres with FOR UPDATE SKIP LOCKED."
      >
        Queues & nodes
      </Core.heading>

      <p :if={@action_error} class="mt-3 text-xs text-destructive" role="alert">{@action_error}</p>

      <Charts.panel
        title="Queues"
        sub="Pausing a queue applies to every node, not just this one. Running work finishes."
        class="mt-5"
      >
        <Core.empty_state
          :if={@queues == []}
          icon="queue"
          title="No queues"
          description="Configure queues with the :queues option when starting Durable."
        />
        <div :if={@queues != []} class="thin-scroll overflow-x-auto">
          <table class="w-full border-collapse">
            <thead>
              <tr class="border-y border-border text-xs text-muted-foreground">
                <th class="px-4 py-2 text-left font-medium">Queue</th>
                <th class="px-4 py-2 text-left font-medium">State</th>
                <th
                  class="px-4 py-2 text-left font-medium"
                  data-tip="Runs being worked now against the slots for the queue"
                  data-tip-meta="slots = this node's concurrency × live nodes polling the queue (an estimate)"
                >
                  Running / capacity
                </th>
                <th class="px-4 py-2 text-right font-medium" data-tip="Due now, waiting for a free worker">Ready</th>
                <th class="w-[140px] px-4 py-2 text-left font-medium" data-tip="The ready count, sampled once a minute">Ready, last hour</th>
                <th class="px-4 py-2 text-right font-medium" data-tip="Set to start later · sleeps, retry backoffs, delayed starts">Scheduled</th>
                <th class="px-4 py-2 text-right font-medium" data-tip="How long the longest-waiting ready run has waited · amber after a minute">Oldest ready</th>
                <th class="px-4 py-2 text-right font-medium" data-tip="Runs finished per minute, averaged over the last 5 minutes">Done / min</th>
                <th class="px-4 py-2 text-right font-medium" data-tip="95% of runs waited less between being due and starting · last hour">Wait p95</th>
                <th :if={@can_operate?} class="px-4 py-2"><span class="sr-only">Actions</span></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={q <- @queues} class="h-[46px] border-b border-border last:border-b-0 hover:bg-accent">
                <td class="px-4 font-mono font-medium">{q.queue}</td>
                <td class="px-4"><Core.status_pill status={queue_state(q)} tip={queue_tip(q)} /></td>
                <td class="px-4">
                  <div :if={q.capacity > 0} class="flex w-44 items-center gap-2.5">
                    <Charts.meter
                      value={q.running}
                      top={q.capacity}
                      class={if q.running >= q.capacity, do: "bg-warning", else: "bg-primary"}
                      tip_title={if q.running >= q.capacity, do: "At capacity"}
                      tip={"#{q.running} running · #{q.capacity} slots\n#{q.pollers} #{if q.pollers == 1, do: "node", else: "nodes"} × #{div(q.capacity, q.pollers)} concurrency"}
                    />
                    <span class="shrink-0 font-mono text-xs text-subtle-foreground">
                      {q.running} / {q.capacity}
                    </span>
                  </div>
                  <span
                    :if={q.capacity == 0}
                    class="text-xs text-warning"
                    data-tip="Its runs wait until a node that lists this queue in :queues starts"
                  >
                    No live node polls this queue
                  </span>
                </td>
                <td class="px-4 text-right font-mono">{Format.int(q.ready)}</td>
                <td class="px-4">
                  <.backlog values={@backlog[q.queue]} labels={@backlog_labels} />
                </td>
                <td class="px-4 text-right font-mono text-subtle-foreground">{Format.int(q.scheduled)}</td>
                <td class={["px-4 text-right font-mono text-xs", stale?(q, @now) && "text-warning"]}>
                  <Core.relative_time :if={q.oldest_ready_at} at={q.oldest_ready_at} />
                  <span :if={!q.oldest_ready_at} class="text-muted-foreground">—</span>
                </td>
                <td class="px-4 text-right font-mono" data-tip={"#{Format.int(q.done_last_5m)} in the last 5 minutes"}>
                  {per_minute(q.done_last_5m)}
                </td>
                <td class="px-4 text-right font-mono">{Format.ms(q.wait_p95_ms)}</td>
                <td :if={@can_operate?} class="px-4 text-right">
                  <Core.button
                    size="sm"
                    phx-click="toggle"
                    phx-value-queue={q.queue}
                    data-tip={
                      if q.paused,
                        do: "Every node starts claiming runs from #{q.queue} again",
                        else: "Every node stops claiming new runs from #{q.queue} · running ones finish"
                    }
                  >
                    {if q.paused, do: "Resume", else: "Pause"}
                  </Core.button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </Charts.panel>

      <Charts.panel
        title="Nodes"
        sub={"One row per running Durable instance, from its heartbeat · #{@alive} alive"}
        class="mt-4"
      >
        <Core.empty_state
          :if={@nodes == []}
          icon="nav-queues"
          title="No node has checked in"
          description="Nodes heartbeat into durable.nodes every 10 s. If this stays empty, the schema may need upgrading — see Settings."
        />
        <div :if={@nodes != []} class="thin-scroll overflow-x-auto">
          <table class="w-full border-collapse">
            <thead>
              <tr class="border-y border-border text-xs text-muted-foreground">
                <th class="px-4 py-2 text-left font-medium">Node</th>
                <th class="px-4 py-2 text-left font-medium">Status</th>
                <th class="px-4 py-2 text-right font-medium" data-tip="Runs this node is executing now">Running</th>
                <th class="px-4 py-2 text-left font-medium" data-tip="The queues this node polls for work">Queues</th>
                <th class="px-4 py-2 text-right font-medium" data-tip="Nodes heartbeat every 10 s · missing after 30 s without one">Last heartbeat</th>
                <th class="px-4 py-2 text-right font-medium">Uptime</th>
                <th class="px-4 py-2 text-right font-medium" data-tip="The Durable version the node runs">Version</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={n <- @nodes} class="h-[46px] border-b border-border last:border-b-0 hover:bg-accent">
                <td class="px-4">
                  <span class="font-mono">{n.id}</span>
                  <Core.badge :if={n.id == @this_node} class="ml-2">This node</Core.badge>
                </td>
                <td class="px-4"><Core.status_pill status={n.status} /></td>
                <td class="px-4 text-right font-mono">{Format.int(n.running)}</td>
                <td class="px-4 font-mono text-xs text-subtle-foreground">
                  {if n.queues == [], do: "none — queue processing off", else: Enum.join(n.queues, ", ")}
                </td>
                <td class="px-4 text-right text-xs text-muted-foreground">
                  <Core.relative_time at={n.heartbeat_at} />
                </td>
                <td
                  class="px-4 text-right font-mono text-xs"
                  data-tip-title="Up since"
                  data-tip={Calendar.strftime(n.started_at, "%b %-d, %Y, %H:%M:%S UTC")}
                >
                  {Format.ms(DateTime.diff(@now, n.started_at, :millisecond))}
                </td>
                <td class="px-4 text-right font-mono text-xs text-subtle-foreground">{n.version}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </Charts.panel>

      <Charts.panel
        title="Operations"
        sub="what Durable did on its own, and queue changes — last 24h, newest first"
        class="mt-4"
      >
        <p :if={@activity == []} class="px-4 pb-5 pt-1 text-xs text-muted-foreground">
          Nothing to report: no recovered runs, fenced workers or queue changes in the last day.
        </p>
        <ol :if={@activity != []}>
          <li :for={a <- @activity} class="grid grid-cols-[86px_14px_minmax(0,1fr)_auto] items-baseline gap-x-2.5 border-t border-border px-4 py-2.5 text-[13px]">
            <span class="text-xs text-muted-foreground"><Core.relative_time at={a.at} /></span>
            <span data-tip={activity_tip(a.kind)}>
              <Core.status_dot status={activity_status(a.kind)} class="translate-y-px" />
            </span>
            <span class="min-w-0">
              <.activity_line event={a} base_path={@base_path} />
            </span>
            <span
              class="hidden truncate font-mono text-xs text-muted-foreground sm:block"
              data-tip-title="Node"
              data-tip={a.node_id}
            >
              {a.node_id}
            </span>
          </li>
        </ol>
      </Charts.panel>
    </Layouts.app>
    """
  end

  attr :values, :list, default: nil
  attr :labels, :list, required: true

  defp backlog(%{values: values} = assigns) when not is_list(values) or length(values) < 2 do
    ~H"""
    <span class="text-xs text-muted-foreground" data-tip="Sampled once a minute · the line appears after two samples">
      collecting…
    </span>
    """
  end

  defp backlog(assigns) do
    assigns =
      assign(assigns,
        peak: assigns.values |> Enum.reject(&is_nil/1) |> Enum.max(fn -> 0 end),
        # per_minute/2 drops the minutes before the first sample.
        labels: Enum.take(assigns.labels, -length(assigns.values))
      )

    ~H"""
    <span class="flex items-center gap-2">
      <span class="w-24">
        <Charts.sparkline values={@values} labels={@labels} format={&"#{Format.int(&1)} ready"} zero />
      </span>
      <span class="font-mono text-[11px] text-muted-foreground" data-tip="The most ready at once in the last hour">
        {@peak}
      </span>
    </span>
    """
  end

  attr :event, :map, required: true
  attr :base_path, :string, required: true

  defp activity_line(%{event: %{kind: "stale_recovered"}} = assigns) do
    ~H"""
    Put <b class="font-medium">{runs(@event.count)}</b> back on the queue — their node stopped heartbeating
    for {@event.details["after_s"] || "a while"}s, so another node will finish them.
    """
  end

  defp activity_line(%{event: %{kind: "zombie_recovered"}} = assigns) do
    ~H"""
    Failed <b class="font-medium">{runs(@event.count)}</b> left running with no live worker.
    """
  end

  defp activity_line(%{event: %{kind: "worker_fenced"}} = assigns) do
    ~H"""
    A worker on <span class="font-mono">{@event.queue}</span> stopped: another node had reclaimed run
    <.run_link id={@event.workflow_id} base_path={@base_path} />, so it won't run twice.
    """
  end

  defp activity_line(%{event: %{kind: "ack_failed"}} = assigns) do
    ~H"""
    Couldn't release the lock on run <.run_link id={@event.workflow_id} base_path={@base_path} />
    after {@event.details["attempts"]} attempts; stale-lock recovery will free it.
    """
  end

  defp activity_line(%{event: %{kind: kind}} = assigns)
       when kind in ["queue_paused", "queue_resumed"] do
    ~H"""
    {if @event.kind == "queue_paused", do: "Paused", else: "Resumed"}
    <span class="font-mono font-medium">{@event.queue}</span> on every node<span :if={@event.details["by"]}>
      — by {@event.details["by"]}</span>.
    """
  end

  defp activity_line(%{event: %{kind: "schedule_disabled"}} = assigns) do
    ~H"""
    Turned off schedule <span class="font-mono font-medium">{@event.details["schedule"]}</span>
    after {@event.details["failures"]} failures in a row: <span class="text-destructive">{@event.details["error"]}</span>
    """
  end

  defp activity_line(%{event: %{kind: "pruned"}} = assigns) do
    ~H"""
    Pruned <b class="font-medium">{runs(@event.count)}</b> past their retention.
    """
  end

  defp activity_line(assigns) do
    ~H"""
    <span class="font-mono">{@event.kind}</span>
    """
  end

  attr :id, :string, default: nil
  attr :base_path, :string, required: true

  defp run_link(assigns) do
    ~H"""
    <.link
      :if={@id}
      navigate={DPath.execution(@base_path, @id)}
      class="font-mono text-primary hover:underline"
      data-tip="Open the run"
      data-tip-meta={@id}
    >
      {String.slice(@id, 0, 8)}
    </.link>
    """
  end

  defp runs(1), do: "1 run"
  defp runs(n), do: Format.count(n, "run")

  defp activity_status(kind) when kind in ["stale_recovered", "zombie_recovered"], do: :waiting

  defp activity_status(kind) when kind in ["worker_fenced", "ack_failed", "schedule_disabled"],
    do: :failed

  defp activity_status("queue_paused"), do: :paused
  defp activity_status(_kind), do: :idle

  defp activity_tip("stale_recovered"),
    do: "Recovered · runs whose node stopped heartbeating, put back on the queue"

  defp activity_tip("zombie_recovered"),
    do: "Recovered · runs marked running with no live worker"

  defp activity_tip("worker_fenced"),
    do: "Fenced · a worker stopped because another node had taken its run over"

  defp activity_tip("ack_failed"), do: "Lock not released · stale-lock recovery frees it"
  defp activity_tip("queue_paused"), do: "Queue paused"
  defp activity_tip("queue_resumed"), do: "Queue resumed"

  defp activity_tip("schedule_disabled"),
    do: "Schedule turned off · it failed to start its workflow too many times in a row"

  defp activity_tip("pruned"), do: "Pruned · finished runs deleted past their retention"
  defp activity_tip(kind), do: kind

  defp queue_tip(%{paused: true}), do: "Paused on every node · new runs wait until it's resumed"
  defp queue_tip(%{running: r}) when r > 0, do: "Workers are running runs from it now"
  defp queue_tip(_queue), do: "Nothing running from it right now"

  defp queue_state(%{paused: true}), do: :paused
  defp queue_state(%{running: r}) when r > 0, do: :running
  defp queue_state(_queue), do: :idle

  # A ready run that's waited over a minute means the queue is behind.
  defp stale?(%{oldest_ready_at: nil}, _now), do: false
  defp stale?(%{oldest_ready_at: at}, now), do: DateTime.diff(now, at) > 60

  defp per_minute(0), do: "0"

  defp per_minute(done_last_5m) do
    rate = done_last_5m / 5
    if rate >= 10, do: Format.int(rate), else: :erlang.float_to_binary(rate, decimals: 1)
  end
end
