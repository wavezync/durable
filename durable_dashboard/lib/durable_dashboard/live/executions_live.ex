defmodule DurableDashboard.Live.ExecutionsLive do
  @moduledoc """
  The Runs list. One LiveView covers two URLs:

  - `/executions`        — every top-level run on this instance
  - `/workflows/:name/runs` — runs of one workflow

  Saved views (All / Failed / Running / Waiting / Cancelled) over the query
  bar (`ExecutionFilters`). Rows can be selected for bulk retry, rerun or
  cancel; each action applies only to the selected runs it fits. The URL is
  the source of truth for the query, so every view is shareable.

  Nothing moves under the pointer: live events reload at most once a second
  (`@refresh_ms`), rows in view update in place, and a change in *which* runs
  are listed waits behind a "new runs" pill (`reconcile/2`). Columns have
  fixed widths and the bulk bar floats.
  """

  use Phoenix.LiveView

  import Ecto.Query

  alias Durable.PubSub, as: DurablePubSub
  alias Durable.Storage.Schemas.StepExecution
  alias DurableDashboard.Format
  alias DurableDashboard.Access
  alias DurableDashboard.Components.Core
  alias DurableDashboard.Components.Data.ExecutionFilters
  alias DurableDashboard.Layouts
  alias DurableDashboard.Path, as: DPath
  alias DurableDashboard.RunSearch
  alias DurableDashboard.Trace

  @filters_id "executions-filters"
  @per_page 25
  @refresh_ms 1_000

  @workflow_kinds [
    :workflow_started,
    :workflow_resumed,
    :workflow_waiting,
    :workflow_completed,
    :workflow_failed,
    :workflow_cancelled,
    :workflow_retried
  ]

  @statuses ~w(running waiting completed failed compensated compensation_failed cancelled pending)

  @views [
    {"all", "All runs", []},
    {"failed", "Failed", ~w(failed compensated compensation_failed)},
    {"running", "Running", ~w(running pending)},
    {"waiting", "Waiting", ~w(waiting)},
    {"cancelled", "Cancelled", ~w(cancelled)}
  ]

  @preset_seconds %{
    "15m" => 900,
    "1h" => 3_600,
    "24h" => 86_400,
    "7d" => 604_800,
    "30d" => 2_592_000
  }

  @impl true
  def mount(_params, session, socket) do
    config = session["config"]
    durable = config.durable

    if connected?(socket) do
      if durable_config = Durable.Config.get_safe(durable) do
        DurablePubSub.subscribe(durable_config, DurablePubSub.workflows_topic(durable_config))
      end
    end

    {:ok,
     assign(socket,
       config: config,
       base_path: config.base_path,
       durable: durable,
       filters_id: @filters_id,
       status_options: @statuses,
       workflows: fetch_workflows(durable),
       schedules: fetch_schedules(durable),
       selected: MapSet.new(),
       bulk_result: nil,
       refresh: nil,
       rows: [],
       held: nil
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    workflow_name = params["name"]
    query = parse_query(params)

    breadcrumbs =
      case workflow_name do
        nil ->
          [%{label: "Runs"}]

        name ->
          base = socket.assigns.base_path

          [
            %{label: "Workflows", href: DPath.workflows(base)},
            %{label: name, href: DPath.workflow_detail(base, name)},
            %{label: "Runs"}
          ]
      end

    {:noreply,
     socket
     # A selection belongs to the rows on screen: bulk actions act on those, so
     # a new page or filter starts it over rather than counting runs it can't
     # reach.
     |> assign(
       selected: MapSet.new(),
       current_path: URI.parse(uri).path,
       breadcrumbs: breadcrumbs,
       query: query,
       workflow_name: workflow_name,
       page_title: if(workflow_name, do: "Runs · #{workflow_name}", else: "Runs")
     )
     |> load_rows()}
  end

  @impl true
  def handle_info({:durable_event, kind, _payload}, socket) when kind in @workflow_kinds do
    {:noreply, schedule_refresh(socket)}
  end

  def handle_info(:refresh, socket),
    do: {:noreply, socket |> assign(refresh: nil) |> load_rows(:live)}

  def handle_info({:execution_filters, patch}, socket) do
    {:noreply, patch_query(socket, Map.merge(socket.assigns.query, patch))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("view", %{"view" => view}, socket) do
    statuses = Enum.find_value(@views, [], fn {key, _, s} -> if key == view, do: s end)
    {:noreply, patch_query(socket, Map.put(socket.assigns.query, :statuses, statuses))}
  end

  def handle_event("page", %{"page" => page}, socket) do
    query = %{socket.assigns.query | page: max(parse_int(page, 1), 1)}
    {:noreply, push_patch(socket, to: query_path(socket.assigns, query))}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    selected = socket.assigns.selected

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, selected: selected, bulk_result: nil)}
  end

  def handle_event("toggle-all", _params, socket) do
    page_ids = MapSet.new(socket.assigns.rows, & &1.id)

    selected =
      if MapSet.subset?(page_ids, socket.assigns.selected),
        do: MapSet.difference(socket.assigns.selected, page_ids),
        else: MapSet.union(socket.assigns.selected, page_ids)

    {:noreply, assign(socket, selected: selected, bulk_result: nil)}
  end

  def handle_event("show-latest", _params, socket), do: {:noreply, load_rows(socket)}

  def handle_event("dismiss-result", _params, socket),
    do: {:noreply, assign(socket, bulk_result: nil)}

  def handle_event("clear-selection", _params, socket) do
    {:noreply, assign(socket, selected: MapSet.new(), bulk_result: nil)}
  end

  def handle_event("bulk", %{"action" => action}, socket) when action in ~w(retry rerun cancel) do
    action = String.to_existing_atom(action)
    ids = eligible_ids(socket.assigns, action)
    durable = socket.assigns.durable
    required = if length(ids) > 100, do: :admin, else: :operator

    result =
      Access.perform(socket, required, action, ids, fn ->
        results = Enum.map(ids, &run_action(action, &1, durable))
        {:ok, Enum.count(results, &match?({:ok, _}, &1)) + Enum.count(results, &(&1 == :ok))}
      end)

    message =
      case result do
        {:ok, done} -> "#{verb(action)} #{done} of #{Format.count(length(ids), "run")}."
        {:error, :forbidden} -> "You don't have permission to do that."
      end

    {:noreply, socket |> assign(selected: MapSet.new(), bulk_result: message) |> load_rows()}
  end

  defp run_action(:retry, id, durable), do: Durable.retry(id, durable: durable)
  defp run_action(:rerun, id, durable), do: Durable.rerun(id, durable: durable)
  defp run_action(:cancel, id, _durable), do: Durable.cancel(id)

  defp verb(:retry), do: "Retried"
  defp verb(:rerun), do: "Started reruns for"
  defp verb(:cancel), do: "Cancelled"

  defp eligible_ids(assigns, action) do
    assigns.rows
    |> Enum.filter(&(MapSet.member?(assigns.selected, &1.id) and eligible?(action, &1.status)))
    |> Enum.map(& &1.id)
  end

  defp eligible?(:retry, status), do: status == :failed

  defp eligible?(:rerun, status),
    do: status in [:completed, :failed, :cancelled, :compensated, :compensation_failed]

  defp eligible?(:cancel, status), do: status in [:pending, :running, :waiting]

  defp patch_query(socket, query) do
    push_patch(socket, to: query_path(socket.assigns, %{query | page: 1}))
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        view: current_view(assigns.query.statuses),
        can_operate?: Access.allowed?(assigns.access, :operator),
        counts: bulk_counts(assigns)
      )

    ~H"""
    <Layouts.app
      base_path={@base_path}
      current_path={@current_path}
      breadcrumbs={@breadcrumbs}
      durable={@durable} inbox_count={@inbox_count}
    >
      <Core.heading level={1} subtitle={"#{format_int(@total)} matching · newest first"}>
        {@workflow_name || "Runs"}
      </Core.heading>

      <div
        :if={@query.parent}
        class="mt-4 flex items-center justify-between gap-3 rounded-[10px] border border-border bg-secondary px-4 py-2.5"
      >
        <p class="text-[13px]">
          Child runs of <Core.code>{short(@query.parent)}</Core.code>
        </p>
        <.link patch={DPath.execution(@base_path, @query.parent)} class="text-xs text-primary hover:underline">
          ← Back to parent
        </.link>
      </div>

      <nav class="mt-4 flex gap-0.5 overflow-x-auto border-b border-border" aria-label="Saved views">
        <button
          :for={{key, label, _} <- views()}
          type="button"
          phx-click="view"
          phx-value-view={key}
          aria-current={@view == key && "page"}
          data-tip={view_tip(key)}
          data-tip-meta={"#{format_int(view_count(@status_counts, key))} runs"}
          class={[
            "-mb-px inline-flex h-9 items-center gap-2 whitespace-nowrap border-b-2 px-3 text-[13px] font-medium transition-colors",
            if(@view == key,
              do: "border-foreground text-foreground",
              else: "border-transparent text-subtle-foreground hover:text-foreground"
            )
          ]}
        >
          {label} <span class="font-mono text-xs text-muted-foreground">{format_int(view_count(@status_counts, key))}</span>
        </button>
      </nav>

      <div class="mt-3.5">
        <.live_component
          module={ExecutionFilters}
          id={@filters_id}
          workflows={@workflows}
          schedules={@schedules}
          status_options={@status_options}
          q={@query.q}
          workflow={@workflow_name || @query.workflow}
          locked_workflow?={not is_nil(@workflow_name)}
          statuses={@query.statuses}
          status_tag?={@view == "all"}
          range={@query.range}
          from={@query.from}
          to={@query.to}
        />
      </div>


      <section class="relative mt-3.5 overflow-hidden rounded-[10px] border border-border bg-card">
        <button
          :if={@held}
          type="button"
          phx-click="show-latest"
          data-tip-title="The list is holding still"
          data-tip="Runs changed while you were reading · click to show the latest"
          class="absolute left-1/2 top-1 z-10 inline-flex h-7 -translate-x-1/2 items-center gap-1.5 rounded-full bg-primary px-3 text-xs font-medium text-primary-foreground shadow-lg hover:bg-primary/90 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
        >
          ↑ {held_label(@held)}
        </button>
        <%= if @rows == [] do %>
          <Core.empty_state
            icon="queue"
            title={if @workflow_name, do: "No #{@workflow_name} runs match", else: "No runs match"}
            description="Change the view, the search or the filters."
          />
        <% else %>
          <div class="thin-scroll overflow-x-auto">
            <table class="w-full min-w-[1120px] table-fixed border-collapse">
              <colgroup>
                <col :if={@can_operate?} class="w-11" />
                <col :for={label <- headers(@workflow_name)} class={col_class(label, @workflow_name)} />
              </colgroup>
              <thead>
                <tr class="border-b border-border">
                  <th :if={@can_operate?} class="pl-3.5 text-left">
                    <input
                      type="checkbox"
                      class="size-[15px] cursor-pointer accent-primary"
                      aria-label="Select every run on this page"
                      data-tip={"Select the #{Format.count(length(@rows), "run")} on this page"}
                      checked={all_selected?(@rows, @selected)}
                      phx-click="toggle-all"
                    />
                  </th>
                  <th :for={label <- headers(@workflow_name)} class={th_class(label)}>
                    <span data-tip={header_tip(label)}>{label}</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={row <- @rows}
                  class={[
                    "border-b border-border last:border-b-0 transition-colors",
                    if(MapSet.member?(@selected, row.id), do: "bg-primary/7", else: "hover:bg-accent")
                  ]}
                >
                  <td :if={@can_operate?} class="pl-3.5">
                    <input
                      type="checkbox"
                      class="size-[15px] cursor-pointer accent-primary"
                      aria-label={"Select run " <> short(row.id)}
                      checked={MapSet.member?(@selected, row.id)}
                      phx-click="toggle"
                      phx-value-id={row.id}
                    />
                  </td>
                  <td class="h-11 px-3"><Core.status_pill status={row.status} /></td>
                  <td class="px-3">
                    <.link
                      navigate={DPath.execution(@base_path, row.id)}
                      class="flex min-w-0 flex-col leading-tight"
                      data-tip-title={row.workflow_name}
                      data-tip="Open the run · its trace, logs and context"
                      data-tip-meta={row.id}
                    >
                      <span :if={!@workflow_name} class="truncate font-medium">{row.workflow_name}</span>
                      <span class={["font-mono text-xs", if(@workflow_name, do: "text-foreground", else: "text-muted-foreground")]}>
                        {short(row.id)}
                      </span>
                    </.link>
                  </td>
                  <td class="truncate px-3 text-xs"><.trigger row={row} base_path={@base_path} /></td>
                  <td class="whitespace-nowrap px-3 font-mono text-xs">
                    <Core.local_time at={row.inserted_at} format="datetime" />
                  </td>
                  <td class="whitespace-nowrap px-3 text-right font-mono text-xs">
                    <span {duration_tip(row)}>{duration(row, @now)}</span>
                  </td>
                  <td class="whitespace-nowrap px-3 text-right font-mono text-xs">
                    <span {steps_tip(row)}>
                      {row.step_count}<span :if={row.failures > 0} class="text-warning"> ↻{row.failures}</span>
                    </span>
                  </td>
                  <td class="px-3"><.where row={row} /></td>
                  <td class="truncate px-3 text-xs" {queue_tip(row)}>
                    <span class="font-mono text-subtle-foreground">{row.queue}</span>
                    <span :if={row.locked_by && row.status == :running} class="text-muted-foreground"> · {short_node(row.locked_by)}</span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <div class="flex flex-wrap items-center justify-between gap-3 border-t border-border px-3.5 py-2.5">
            <span class="text-xs text-muted-foreground">
              {range_label(@query.page, length(@rows), @total)}
            </span>
            <span class="flex gap-1.5">
              <Core.button size="sm" disabled={@query.page <= 1} phx-click="page" phx-value-page={@query.page - 1}>
                ← Newer
              </Core.button>
              <Core.button
                size="sm"
                disabled={@query.page * per_page() >= @total}
                phx-click="page"
                phx-value-page={@query.page + 1}
              >
                Older →
              </Core.button>
            </span>
          </div>
        <% end %>
      </section>

      <%!-- Floats over the list's foot instead of pushing the rows down. --%>
      <div
        :if={(@can_operate? and MapSet.size(@selected) > 0) or @bulk_result}
        class="sticky bottom-4 z-20 mx-auto mt-3 w-fit max-w-full"
      >
        <div
          :if={MapSet.size(@selected) > 0}
          class="flex flex-wrap items-center gap-2 rounded-xl border border-input bg-popover py-2 pl-3.5 pr-2.5 shadow-lg"
          role="region"
          aria-label="Bulk actions"
        >
          <span class="font-semibold">{MapSet.size(@selected)} selected</span>
          <span class="text-xs text-muted-foreground">each action applies only to the runs it fits</span>
          <span class="flex-1"></span>
          <Core.button
            :if={@counts.retry > 0}
            phx-click="bulk"
            phx-value-action="retry"
            data-tip-title="Retry from the failed step"
            data-tip={"Each failed run resumes at the step that failed · steps that finished don't run again\n#{bulk_fit(@counts.retry, @selected)} · only failed runs"}
          >
            Retry {@counts.retry} from failed step
          </Core.button>
          <Core.button
            :if={@counts.rerun > 0}
            phx-click="bulk"
            phx-value-action="rerun"
            data-tip-title="Rerun"
            data-tip={"Each one starts over as a new run, with the same input · linked back to it\n#{bulk_fit(@counts.rerun, @selected)} · only finished runs"}
          >
            Rerun {@counts.rerun}
          </Core.button>
          <Core.button
            kind="destructive"
            :if={@counts.cancel > 0}
            phx-click="bulk"
            phx-value-action="cancel"
            data-confirm={"Cancel #{Format.count(@counts.cancel, "run")}?"}
            data-tip-title="Cancel"
            data-tip={"Each one stops at its next step, with its child runs · no compensations run\n#{bulk_fit(@counts.cancel, @selected)} · only pending, running or waiting runs"}
          >
            Cancel {@counts.cancel}
          </Core.button>
          <Core.button kind="ghost" phx-click="clear-selection">Clear</Core.button>
        </div>
        <p
          :if={@bulk_result && MapSet.size(@selected) == 0}
          class="flex items-center gap-2 rounded-xl border border-input bg-popover py-1.5 pl-3.5 pr-1.5 text-xs shadow-lg"
          role="status"
        >
          {@bulk_result}
          <Core.button kind="ghost" size="sm" phx-click="dismiss-result" aria-label="Dismiss" data-tip="Dismiss">
            <Core.icon name="x-mark" class="size-3.5" />
          </Core.button>
        </p>
      </div>
    </Layouts.app>
    """
  end

  attr :row, :map, required: true
  attr :base_path, :string, required: true

  defp trigger(%{row: %{trigger: :schedule}} = assigns) do
    ~H"""
    <span class="text-muted-foreground">schedule</span>
    <.link
      :if={@row.trigger_ref}
      navigate={DPath.schedule(@base_path, @row.trigger_ref)}
      class="font-mono hover:text-primary hover:underline"
      data-tip-title={"Schedule #{@row.trigger_ref}"}
      data-tip="It started this run on its cadence · open it for its other runs and next fires"
    >
      {@row.trigger_ref}
    </.link>
    """
  end

  defp trigger(%{row: %{trigger: :rerun, trigger_ref: ref}} = assigns) when is_binary(ref) do
    ~H"""
    <span class="text-muted-foreground">rerun of</span>
    <.link
      navigate={DPath.execution(@base_path, @row.trigger_ref)}
      class="font-mono text-primary hover:underline"
      data-tip-title="Rerun"
      data-tip="A fresh start of an earlier run, with its input · open the original"
      data-tip-meta={@row.trigger_ref}
    >
      {short(@row.trigger_ref)}
    </.link>
    """
  end

  defp trigger(%{row: %{parent_workflow_id: parent}} = assigns) when is_binary(parent) do
    ~H"""
    <span class="text-muted-foreground">child of</span>
    <.link
      navigate={DPath.execution(@base_path, @row.parent_workflow_id)}
      class="font-mono text-primary hover:underline"
      data-tip-title="Child run"
      data-tip="Another run started it as one of its steps · open the parent"
      data-tip-meta={@row.parent_workflow_id}
    >
      {short(@row.parent_workflow_id)}
    </.link>
    """
  end

  defp trigger(%{row: %{trigger: :api}} = assigns),
    do:
      ~H[<span class="text-muted-foreground" data-tip="Started from code, with Durable.start/3">api</span>]

  defp trigger(assigns), do: ~H[<span class="text-muted-foreground">—</span>]

  attr :row, :map, required: true

  defp where(%{row: %{status: status}} = assigns) when status in [:completed, :pending] do
    ~H[<span class="text-muted-foreground">—</span>]
  end

  defp where(assigns) do
    error = Trace.error_parts(assigns.row.error)

    assigns =
      assign(assigns, step: Trace.display_name(assigns.row.current_step || ""), error: error)

    ~H"""
    <span
      class="flex min-w-0 items-baseline gap-1.5"
      data-tip-title={"#{where_label(@row.status)} #{@step}"}
      data-tip={where_body(@row.status, @error)}
      data-tip-meta={@error && @error.type}
    >
      <span class={["min-w-0 shrink-0 truncate font-mono text-xs", where_tone(@row.status)]}>{@step}</span>
      <span :if={@error} class="truncate text-xs text-muted-foreground">
        {@error.message}
      </span>
      <span :if={!@error and @row.status == :waiting} class="text-xs text-muted-foreground">waiting</span>
    </span>
    """
  end

  defp where_tone(status) when status in [:failed, :compensation_failed], do: "text-destructive"
  defp where_tone(:compensated), do: "text-comp"
  defp where_tone(:waiting), do: "text-warning"
  defp where_tone(:running), do: "text-primary"
  defp where_tone(_status), do: "text-subtle-foreground"

  defp where_label(status) when status in [:failed, :compensation_failed], do: "Failed at"
  defp where_label(:compensated), do: "Undone after"
  defp where_label(:waiting), do: "Waiting at"
  defp where_label(:cancelled), do: "Cancelled at"
  defp where_label(_status), do: "Running"

  defp where_body(_status, %{message: message}), do: message

  defp where_body(:waiting, nil),
    do: "Paused here until its sleep ends, its event arrives or someone answers"

  defp where_body(:running, nil), do: "This step is running now"
  defp where_body(_status, nil), do: "The step it stopped at"

  defp view_tip("all"), do: "Every top-level run the bar matches"
  defp view_tip("failed"), do: "Failed, compensated or compensation failed"
  defp view_tip("running"), do: "Running now, or queued for a worker"
  defp view_tip("waiting"), do: "Paused on a sleep, an event or a person's input"
  defp view_tip("cancelled"), do: "Stopped before they finished"

  defp header_tip("Trigger"),
    do: "What started the run · code, a schedule, a parent run or a rerun"

  defp header_tip("Started"), do: "When it was created, in your time zone"
  defp header_tip("Duration"), do: "First step to the last, or to now · waits included"
  defp header_tip("Steps"), do: "Distinct steps it reached · ↻ failed attempts that were retried"
  defp header_tip("Where it is"), do: "The step it's on, or where it stopped and why"
  defp header_tip("Queue · node"), do: "The queue its jobs go through · the node running it now"
  defp header_tip(_label), do: nil

  defp bulk_fit(n, selected), do: "applies to #{n} of the #{MapSet.size(selected)} selected"

  defp duration_tip(%{started_at: nil}),
    do: [
      "data-tip-title": "Not started",
      "data-tip": "Queued · waiting for a worker to pick it up"
    ]

  defp duration_tip(row) do
    queued_ms = DateTime.diff(row.started_at, row.scheduled_at || row.inserted_at, :millisecond)
    finished = row.completed_at || if(not in_flight?(row.status), do: row.updated_at)

    [
      "data-tip-title": if(finished, do: "Start to finish", else: "So far"),
      "data-tip":
        Enum.join(
          [
            "From its first step to #{if finished, do: "its last", else: "now"} · waits included",
            queued_ms > 0 && "queued #{Trace.format_ms(queued_ms)} before a worker picked it up"
          ]
          |> Enum.filter(& &1),
          "\n"
        ),
      "data-tip-meta": "#{utc(row.started_at)} → #{if finished, do: utc(finished), else: "now"}"
    ]
  end

  defp in_flight?(status), do: status in [:pending, :running, :waiting, :compensating]

  defp steps_tip(row) do
    [
      "data-tip-title":
        "#{row.step_count} #{if row.step_count == 1, do: "step", else: "steps"} reached",
      "data-tip":
        if(row.failures > 0,
          do:
            "↻ #{row.failures} failed #{if row.failures == 1, do: "attempt", else: "attempts"} · each retried until its step passed or gave up",
          else: "No failed attempts"
        )
    ]
  end

  defp queue_tip(%{locked_by: node, status: :running} = row) when is_binary(node),
    do: [
      "data-tip-title": "Queue #{row.queue}",
      "data-tip": "Running on this node now",
      "data-tip-meta": node
    ]

  defp queue_tip(row),
    do: ["data-tip-title": "Queue #{row.queue}", "data-tip": "The queue its jobs go through"]

  defp utc(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")

  defp headers(nil),
    do: [
      "Status",
      "Run",
      "Trigger",
      "Started",
      "Duration",
      "Steps",
      "Where it is",
      "Queue · node"
    ]

  defp headers(_name), do: headers(nil)

  # Fixed widths, so live updates and paging never move a column; Run (when
  # it names the workflow) and Where it is take what's left.
  defp col_class("Status", _name), do: "w-[150px]"
  defp col_class("Run", nil), do: "w-[180px]"
  defp col_class("Run", _name), do: "w-[110px]"
  defp col_class("Trigger", _name), do: "w-[136px]"
  defp col_class("Started", _name), do: "w-[184px]"
  defp col_class("Duration", _name), do: "w-[80px]"
  defp col_class("Steps", _name), do: "w-[64px]"
  defp col_class("Queue · node", _name), do: "w-[120px]"
  defp col_class(_label, _name), do: nil

  defp held_label(%{new: 0}), do: "List changed · show latest"
  defp held_label(%{new: 1}), do: "1 new run"
  defp held_label(%{new: n}), do: "#{format_int(n)} new runs"

  defp th_class(label) when label in ["Duration", "Steps"],
    do: "h-9 whitespace-nowrap px-3 text-right text-xs font-medium text-muted-foreground"

  defp th_class(_label),
    do: "h-9 whitespace-nowrap px-3 text-left text-xs font-medium text-muted-foreground"

  defp views, do: @views
  defp per_page, do: @per_page

  defp current_view(statuses) do
    sorted = Enum.sort(statuses || [])
    Enum.find_value(@views, "all", fn {key, _, s} -> if Enum.sort(s) == sorted, do: key end)
  end

  defp view_count(counts, "all"), do: counts |> Map.values() |> Enum.sum()

  defp view_count(counts, key) do
    statuses = Enum.find_value(@views, [], fn {k, _, s} -> if k == key, do: s end)
    statuses |> Enum.map(&Map.get(counts, String.to_existing_atom(&1), 0)) |> Enum.sum()
  end

  defp bulk_counts(assigns) do
    for action <- [:retry, :rerun, :cancel], into: %{} do
      {action, length(eligible_ids(assigns, action))}
    end
  end

  defp all_selected?(rows, selected),
    do: rows != [] and Enum.all?(rows, &MapSet.member?(selected, &1.id))

  # ============================================================================
  # Data
  # ============================================================================

  # `:now` shows the query's rows; `:live` (an event-driven refresh) keeps the
  # listed runs in place — see `reconcile/2`.
  defp load_rows(socket, mode \\ :now) do
    %{durable: durable, query: query, workflow_name: name} = socket.assigns
    filters = filters(durable, name, query)
    offset = (query.page - 1) * @per_page

    {rows, total} =
      Durable.Query.list_executions_with_total(filters ++ [limit: @per_page, offset: offset])

    fresh = attach_step_stats(rows, durable)
    {rows, held} = if mode == :live, do: reconcile(socket.assigns.rows, fresh), else: {fresh, nil}

    assign(socket,
      rows: rows,
      held: held,
      total: total,
      status_counts: Durable.Query.count_by_status(filters),
      now: DateTime.utc_now()
    )
  end

  defp schedule_refresh(%{assigns: %{refresh: nil}} = socket),
    do: assign(socket, refresh: Process.send_after(self(), :refresh, @refresh_ms))

  defp schedule_refresh(socket), do: socket

  @doc """
  Merges a live refresh into the rows on screen without moving them: when the
  same runs are listed they update in place; when the list itself changed
  (new runs arrived, or some left the view) the rows on screen stay — with
  fresh data where it exists — and the change is held as `%{new: n}` behind
  a pill.
  """
  @spec reconcile([map()], [map()]) :: {[map()], %{new: non_neg_integer()} | nil}
  def reconcile([], fresh), do: {fresh, nil}

  def reconcile(shown, fresh) do
    if Enum.map(shown, & &1.id) == Enum.map(fresh, & &1.id) do
      {fresh, nil}
    else
      by_id = Map.new(fresh, &{&1.id, &1})
      shown_ids = MapSet.new(shown, & &1.id)

      {Enum.map(shown, &Map.get(by_id, &1.id, &1)),
       %{new: Enum.count(fresh, &(not MapSet.member?(shown_ids, &1.id)))}}
    end
  end

  defp filters(durable, locked_name, query) do
    [durable: durable]
    |> put_if(:workflow_name, locked_name || query.workflow)
    |> put_statuses(query.statuses)
    |> put_time_range(query)
    |> Kernel.++(RunSearch.parse(query.q))
    |> scope(query.parent)
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, _key, ""), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

  defp put_statuses(opts, statuses) do
    atoms = for s <- statuses || [], s in @statuses, do: String.to_existing_atom(s)
    if atoms == [], do: opts, else: Keyword.put(opts, :status, atoms)
  end

  defp put_time_range(opts, query) do
    cond do
      Map.has_key?(@preset_seconds, query.range) ->
        Keyword.put(
          opts,
          :from,
          DateTime.add(DateTime.utc_now(), -@preset_seconds[query.range], :second)
        )

      query.from || query.to ->
        opts
        |> put_if(:from, parse_local_datetime(query.from))
        |> put_if(:to, parse_local_datetime(query.to))

      true ->
        opts
    end
  end

  # Lists show top-level runs; children appear under their parent, or in the
  # per-parent drill-down (`?parent=<id>`).
  defp scope(opts, parent) when is_binary(parent),
    do: Keyword.put(opts, :parent_workflow_id, parent)

  defp scope(opts, _parent), do: Keyword.put(opts, :top_level_only, true)

  # Distinct steps and failed attempts per run, in one query for the page.
  defp attach_step_stats([], _durable), do: []

  defp attach_step_stats(rows, durable) do
    config = Durable.Config.get(durable)
    ids = Enum.map(rows, & &1.id)

    stats =
      Durable.Repo.all(
        config,
        from(s in StepExecution,
          where: s.workflow_id in ^ids,
          group_by: s.workflow_id,
          select:
            {s.workflow_id, count(s.step_name, :distinct),
             filter(count(s.id), s.status == :failed)}
        )
      )
      |> Map.new(fn {id, steps, failures} -> {id, {steps, failures}} end)

    Enum.map(rows, fn row ->
      {steps, failures} = Map.get(stats, row.id, {0, 0})
      Map.merge(row, %{step_count: steps, failures: failures})
    end)
  end

  defp fetch_workflows(durable) do
    Durable.Query.list_workflows(durable: durable)
  rescue
    _ -> []
  end

  defp fetch_schedules(durable) do
    [durable: durable] |> Durable.list_schedules() |> Enum.map(& &1.name)
  rescue
    _ -> []
  end

  # ============================================================================
  # URL <-> query
  # ============================================================================

  defp parse_query(params) do
    %{
      page: max(parse_int(params["page"], 1), 1),
      q: nilify(params["q"]),
      workflow: nilify(params["workflow"]),
      statuses: parse_list(params["status"]),
      range: nilify(params["range"]),
      from: nilify(params["from"]),
      to: nilify(params["to"]),
      parent: nilify(params["parent"])
    }
  end

  defp query_path(%{base_path: base, workflow_name: name}, query) do
    path = if name, do: DPath.workflow_executions(base, name), else: DPath.executions(base)

    params =
      [
        {"page", if(query.page > 1, do: to_string(query.page))},
        {"q", query.q},
        {"status", if(query.statuses != [], do: Enum.join(query.statuses, ","))},
        {"range", query.range},
        {"from", query.from},
        {"to", query.to},
        {"parent", query.parent},
        {"workflow", if(is_nil(name), do: query.workflow)}
      ]
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)

    if params == [], do: path, else: path <> "?" <> URI.encode_query(params)
  end

  defp parse_list(nil), do: []
  defp parse_list(s), do: String.split(s, ",", trim: true)

  defp parse_int(nil, default), do: default

  defp parse_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(v, _default) when is_integer(v), do: v

  defp nilify(nil), do: nil
  defp nilify(""), do: nil
  defp nilify(v), do: v

  # datetime-local ("YYYY-MM-DDTHH:MM"), read as UTC.
  defp parse_local_datetime(nil), do: nil

  defp parse_local_datetime(s) do
    s = if String.length(s) == 16, do: s <> ":00", else: s

    case NaiveDateTime.from_iso8601(s) do
      {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
      _ -> nil
    end
  end

  # ============================================================================
  # Formatting
  # ============================================================================

  defp duration(%{started_at: nil}, _now), do: "—"

  defp duration(row, now) do
    finish =
      row.completed_at ||
        if(row.status in [:pending, :running, :waiting, :compensating],
          do: now,
          else: row.updated_at
        )

    Trace.format_ms(max(DateTime.diff(finish, row.started_at, :millisecond), 0))
  end

  defp range_label(_page, 0, _total), do: "No runs"

  defp range_label(page, count, total) do
    first = (page - 1) * @per_page + 1
    "#{format_int(first)}–#{format_int(first + count - 1)} of #{format_int(total)}"
  end

  defp format_int(n) when is_integer(n) do
    n |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  end

  defp short(nil), do: "—"
  defp short(id), do: String.slice(id, 0, 8)

  defp short_node(node), do: node |> String.split("@") |> List.last() |> String.slice(0, 20)
end
