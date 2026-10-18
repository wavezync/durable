defmodule DurableDashboard.Live.WorkflowLive do
  @moduledoc """
  One run, on one page: header with actions, a banner saying what went wrong,
  a strip of run facts, and a body with a view switch — **Trace** (waterfall +
  step inspector), Graph, Logs, Context, Family.

  URL: `/executions/:id[/:view]?step=<step execution id>&pane=<pane>` — the
  selected step and inspector pane live in the URL so a link to "this step's
  error" is shareable. Older tab names (summary, timeline, history, flow, io)
  map onto the new views.
  """

  use Phoenix.LiveView

  import Ecto.Query

  alias Durable.PubSub, as: DurablePubSub
  alias Durable.Storage.Schemas.{PendingInput, StepExecution, WorkflowExecution}
  alias DurableDashboard.Format
  alias DurableDashboard.Access
  alias DurableDashboard.Components.Core
  alias DurableDashboard.Components.Workflow.{ChildrenTab, FamilyChip, IoTab, LogLine, LogsTab}
  alias DurableDashboard.Components.Workflow.FlowGraph
  alias DurableDashboard.Layouts
  alias DurableDashboard.Path, as: DPath
  alias DurableDashboard.Trace
  alias Phoenix.LiveView.JS

  @workflow_kinds [
    :workflow_started,
    :workflow_resumed,
    :workflow_waiting,
    :workflow_completed,
    :workflow_failed,
    :workflow_cancelled,
    :workflow_retried
  ]

  @step_kinds [:step_started, :step_completed, :step_failed, :step_waiting]
  @input_kinds [:input_requested, :input_provided]
  @detail_kinds @workflow_kinds ++ @step_kinds ++ @input_kinds

  @views %{
    "trace" => :trace,
    "graph" => :graph,
    "logs" => :logs,
    "context" => :context,
    "family" => :family,
    # Pre-1.0 tab names.
    "summary" => :trace,
    "timeline" => :trace,
    "history" => :trace,
    "flow" => :graph,
    "io" => :context
  }

  @live_statuses [:pending, :running, :waiting, :compensating]
  @finished_statuses [:completed, :failed, :cancelled, :compensated, :compensation_failed]

  @impl true
  def mount(params, session, socket) do
    config = session["config"]
    durable = config.durable

    id =
      case params do
        %{"id" => id} -> id
        _ -> nil
      end

    if connected?(socket) and id != nil do
      if durable_config = Durable.Config.get_safe(durable) do
        DurablePubSub.subscribe(durable_config, DurablePubSub.workflow_topic(durable_config, id))
      end
    end

    {:ok,
     socket
     |> assign(
       config: config,
       base_path: config.base_path,
       durable: durable,
       workflow_id: id,
       page_title: "Run",
       not_found?: false,
       now: DateTime.utc_now(),
       action_error: nil,
       rerun_editor: nil,
       graph_pick: false
     )
     |> load_workflow()
     |> maybe_schedule_clock_tick()}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {:noreply,
     socket
     |> assign(
       view: Map.get(@views, params["tab"] || "trace", :trace),
       selected_key: params["step"],
       pane: params["pane"],
       current_path: URI.parse(uri).path,
       breadcrumbs: breadcrumbs(socket.assigns)
     )
     |> assign_selection()}
  end

  defp breadcrumbs(%{base_path: base, workflow_id: id} = assigns) do
    name =
      case assigns do
        %{workflow: %{workflow_name: name}} when is_binary(name) -> name
        _ -> nil
      end

    [%{label: "Runs", href: DPath.executions(base)}] ++
      if(name, do: [%{label: name, href: DPath.workflow_detail(base, name)}], else: []) ++
      [%{label: short(id)}]
  end

  # ============================================================================
  # Live updates
  # ============================================================================

  @impl true
  def handle_info({:durable_event, kind, _payload}, socket) when kind in @detail_kinds do
    {:noreply, socket |> load_workflow() |> assign_selection() |> maybe_schedule_clock_tick()}
  end

  def handle_info(:clock_tick, socket) do
    {:noreply,
     socket
     |> assign(now: DateTime.utc_now())
     |> assign_trace()
     |> assign_selection()
     |> maybe_schedule_clock_tick()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Tick twice a second while anything is in flight so running bars grow;
  # stop once the run has settled.
  defp maybe_schedule_clock_tick(%{assigns: %{workflow: %{status: status}}} = socket)
       when status in @live_statuses do
    Process.send_after(self(), :clock_tick, 500)
    socket
  end

  defp maybe_schedule_clock_tick(socket), do: socket

  # ============================================================================
  # Actions
  # ============================================================================

  @impl true
  def handle_event("cancel", _params, socket) do
    id = socket.assigns.workflow_id
    result = Access.perform(socket, :operator, :cancel, [id], fn -> Durable.cancel(id) end)
    {:noreply, after_action(socket, result)}
  end

  def handle_event("retry", _params, socket) do
    id = socket.assigns.workflow_id
    durable = socket.assigns.durable

    result =
      Access.perform(socket, :operator, :retry, [id], fn ->
        Durable.retry(id, durable: durable)
      end)

    {:noreply, after_action(socket, result)}
  end

  def handle_event("rerun", params, socket) do
    with {:ok, opts} <- rerun_opts(params),
         {:ok, new_id} <-
           Access.perform(socket, :operator, :rerun, [socket.assigns.workflow_id], fn ->
             Durable.rerun(socket.assigns.workflow_id, [durable: socket.assigns.durable] ++ opts)
           end) do
      {:noreply, push_navigate(socket, to: DPath.execution(socket.assigns.base_path, new_id))}
    else
      {:error, reason} -> {:noreply, assign(socket, action_error: describe_error(reason))}
    end
  end

  def handle_event("edit-input", _params, socket) do
    input = Jason.encode!(socket.assigns.workflow.input || %{}, pretty: true)
    {:noreply, assign(socket, rerun_editor: input, action_error: nil)}
  end

  def handle_event("close-editor", _params, socket) do
    {:noreply, assign(socket, rerun_editor: nil, action_error: nil)}
  end

  defp rerun_opts(%{"input" => json}) do
    case Jason.decode(json) do
      {:ok, input} when is_map(input) -> {:ok, input: input}
      {:ok, _} -> {:error, :input_not_an_object}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp rerun_opts(_params), do: {:ok, []}

  defp after_action(socket, result) do
    case result do
      {:error, reason} ->
        assign(socket, action_error: describe_error(reason))

      _ ->
        socket
        |> assign(action_error: nil, rerun_editor: nil)
        |> load_workflow()
        |> assign_selection()
        |> maybe_schedule_clock_tick()
    end
  end

  defp describe_error(:forbidden), do: "You don't have permission to do that."
  defp describe_error(:rolled_back), do: "This run was rolled back — rerun it instead."
  defp describe_error(:not_failed), do: "Only failed runs can be retried."
  defp describe_error(:not_finished), do: "Only finished runs can be rerun."
  defp describe_error(:already_completed), do: "The run already finished."
  defp describe_error(:invalid_json), do: "That input isn't valid JSON."
  defp describe_error(:input_not_an_object), do: "The input must be a JSON object."
  defp describe_error(other), do: "That didn't work: #{inspect(other)}"

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
      <%= if @not_found? do %>
        <Core.empty_state
          icon="exclamation-triangle"
          title="Run not found"
          description={"No run with id " <> (@workflow_id || "—") <> " on this instance."}
        >
          <:action>
            <Core.button kind="link" navigate={DPath.executions(@base_path)}>Back to runs</Core.button>
          </:action>
        </Core.empty_state>
      <% else %>
        <.run_header
          workflow={@workflow}
          family={@family}
          steps={@steps}
          base_path={@base_path}
          access={@access}
          failed_row={@failed_row}
          action_error={@action_error}
        />
        <.rerun_editor :if={@rerun_editor} input={@rerun_editor} />
        <.banner
          workflow={@workflow}
          trace={@trace}
          failed_row={@failed_row}
          pending_inputs={@pending_inputs}
          base_path={@base_path}
          view={@view}
        />
        <.facts workflow={@workflow} trace={@trace} family={@family} now={@now} base_path={@base_path} />

        <div class="mt-4 flex flex-wrap items-start gap-4">
          <section class="flex-[3_1_560px] min-w-0 overflow-hidden rounded-[10px] border border-border bg-card">
            <div class="flex flex-wrap items-center justify-between gap-2 px-3.5 py-2.5">
              <.view_switch view={@view} views={view_list(@family)} base_path={@base_path} id={@workflow_id} />
              <span :if={@view == :trace} class="text-xs text-muted-foreground">
                Select a step to inspect it
              </span>
            </div>
            <.view_body
              view={@view}
              workflow={@workflow}
              steps={@steps}
              family={@family}
              trace={@trace}
              selected={@selected}
              picked={@graph_pick}
              base_path={@base_path}
            />
          </section>

          <.inspector
            :if={(@view == :trace and @selected != nil) or @graph_pick}
            row={@selected}
            pane={@active_pane}
            panes={@panes}
            view={@view}
            base_path={@base_path}
            id={@workflow_id}
          />
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  # ---- Header -----------------------------------------------------------------

  attr :workflow, :map, required: true
  attr :family, :map, required: true
  attr :base_path, :string, required: true
  attr :access, :atom, required: true
  attr :failed_row, :map, default: nil
  attr :action_error, :string, default: nil
  attr :steps, :list, default: []

  defp run_header(assigns) do
    assigns =
      assign(assigns,
        can_operate?: Access.allowed?(assigns.access, :operator),
        parent_step_lookup: ChildrenTab.step_lookup(assigns.family, assigns.steps)
      )

    ~H"""
    <header class="flex flex-wrap items-center justify-between gap-3">
      <div class="flex min-w-0 flex-wrap items-center gap-3">
        <Core.status_pill status={@workflow.status} />
        <Core.heading level={1}>{@workflow.workflow_name}</Core.heading>
        <Core.code copy={to_string(@workflow.id)} class="text-muted-foreground">{@workflow.id}</Core.code>
        <FamilyChip.family_chip
          family={@family}
          workflow={@workflow}
          base_path={@base_path}
          parent_step_lookup={@parent_step_lookup}
        />
      </div>

      <div :if={@can_operate?} class="flex flex-wrap items-center gap-2">
        <Core.button
          :if={@workflow.status in [:pending, :running, :waiting]}
          kind="destructive"
          phx-click="cancel"
          data-confirm="Cancel this run? Steps already done stay done; nothing after the current step runs."
          data-tip-title="Cancel run"
          data-tip="Nothing after the current step runs · steps already done stay done"
        >
          Cancel
        </Core.button>
        <Core.button
          :if={@workflow.status in finished_statuses()}
          phx-click="edit-input"
          data-tip="Start a new run with input you edit first · this one stays as it is"
        >
          Rerun with edited input…
        </Core.button>
        <Core.button
          :if={@workflow.status in finished_statuses()}
          kind={if @workflow.status == :failed, do: "secondary", else: "primary"}
          phx-click="rerun"
          data-tip="Start a new run from the first step with the same input · linked back here"
        >
          Rerun
        </Core.button>
        <Core.button
          :if={@workflow.status == :failed}
          kind="primary"
          phx-click="retry"
          data-tip="Carry on in this run from the failed step · the steps before it keep their results"
        >
          Retry from {(@failed_row && @failed_row.name) || "failed step"}
        </Core.button>
      </div>
      <p :if={@action_error} class="w-full text-xs text-destructive" role="alert">{@action_error}</p>
    </header>
    """
  end

  defp finished_statuses, do: @finished_statuses

  attr :input, :string, required: true

  defp rerun_editor(assigns) do
    ~H"""
    <form
      phx-submit="rerun"
      class="mt-3 flex flex-col gap-2.5 rounded-[10px] border border-input bg-secondary p-3.5"
    >
      <label class="flex flex-col gap-1.5 text-xs text-subtle-foreground">
        Input for the new run (JSON)
        <textarea
          name="input"
          rows="8"
          class="rounded-md border border-input bg-background p-2.5 font-mono text-xs text-foreground"
        >{@input}</textarea>
      </label>
      <div class="flex justify-end gap-2">
        <Core.button size="sm" phx-click="close-editor">Cancel</Core.button>
        <Core.button size="sm" kind="primary" type="submit">Start rerun</Core.button>
      </div>
    </form>
    """
  end

  # ---- Banner -----------------------------------------------------------------

  attr :workflow, :map, required: true
  attr :trace, :map, required: true
  attr :failed_row, :map, default: nil
  attr :pending_inputs, :list, required: true
  attr :base_path, :string, required: true
  attr :view, :atom, required: true

  defp banner(%{workflow: %{status: status}} = assigns)
       when status in [:failed, :compensated, :compensation_failed] do
    row = assigns.failed_row
    error = row && Trace.error_parts(row.latest.error || assigns.workflow.error)
    comps = Enum.filter(assigns.trace.rows, & &1.compensation?)

    assigns = assign(assigns, row: row, error: error, comps: comps)

    ~H"""
    <div
      role="alert"
      class="mt-4 flex items-start gap-3 rounded-[10px] border border-destructive/35 bg-destructive/10 px-3.5 py-3"
    >
      <Core.status_dot status={:failed} class="mt-1.5" />
      <div class="flex min-w-0 flex-1 flex-col gap-1">
        <p>
          <%= if @row do %>
            <span class="font-mono font-medium">{@row.name}</span>
            failed after {@row.attempts} {if @row.attempts == 1, do: "attempt", else: "attempts"}
          <% else %>
            The run failed
          <% end %>
          <span :if={@error} class="font-mono text-destructive">
            — {error_line(@error)}
          </span>
        </p>
        <p :if={@workflow.status == :compensated} class="text-xs text-subtle-foreground">
          Rolled back: {Enum.map_join(@comps, ", ", & &1.name)}. Retry-from-step is off for
          rolled-back runs because earlier results were undone — Rerun starts a fresh run with
          the same input.
        </p>
        <p :if={@workflow.status == :compensation_failed} class="text-xs text-subtle-foreground">
          The rollback itself failed, so some effects may still be in place — check the
          compensation steps below.
        </p>
      </div>
      <.link
        :if={@row}
        patch={run_path(@base_path, @workflow.id, :trace, step: @row.key, pane: "error")}
        class="shrink-0 text-xs font-medium text-primary hover:underline"
      >
        Show error
      </.link>
    </div>
    """
  end

  defp banner(%{workflow: %{status: :cancelled}} = assigns) do
    assigns = assign(assigns, reason: get_in(assigns.workflow.error || %{}, ["message"]))

    ~H"""
    <div class="mt-4 flex items-center gap-3 rounded-[10px] border border-border bg-secondary px-3.5 py-3">
      <Core.status_dot status={:cancelled} />
      <p>Cancelled{if @reason, do: " — #{@reason}"}. Steps that finished stay finished.</p>
    </div>
    """
  end

  defp banner(%{workflow: %{status: :waiting}} = assigns) do
    assigns =
      assign(assigns, inputs: Enum.filter(assigns.pending_inputs, &(&1.status == :pending)))

    ~H"""
    <div class="mt-4 flex items-center gap-3 rounded-[10px] border border-warning/35 bg-warning/10 px-3.5 py-3">
      <Core.status_dot status={:waiting} />
      <p :if={@inputs != []} class="flex-1">
        Waiting for input
        <span class="font-mono">{Enum.map_join(@inputs, ", ", & &1.input_name)}</span>
      </p>
      <p :if={@inputs == []} class="flex-1">
        Suspended at <span class="font-mono">{Trace.display_name(@workflow.current_step || "")}</span>
        — waiting for an event, a child run, or the clock.
      </p>
      <.link
        :if={@inputs != []}
        navigate={DPath.inputs(@base_path)}
        class="shrink-0 text-xs font-medium text-primary hover:underline"
      >
        Answer in Inbox
      </.link>
    </div>
    """
  end

  defp banner(assigns), do: ~H""

  # ---- Facts ------------------------------------------------------------------

  attr :workflow, :map, required: true
  attr :trace, :map, required: true
  attr :family, :map, required: true
  attr :now, :any, required: true
  attr :base_path, :string, required: true

  defp facts(assigns) do
    w = assigns.workflow
    attempts = assigns.trace.rows |> Enum.map(& &1.attempts) |> Enum.sum()

    assigns =
      assign(assigns,
        duration: run_duration(w, assigns.now),
        duration_tip:
          if(w.status in @live_statuses,
            do: "From starting until now · waits count",
            else: "From starting to finishing · waits count"
          ),
        queued: queued_for(w),
        attempts: "#{attempts} across #{Format.count(length(assigns.trace.rows), "step")}",
        children: length(assigns.family.children || [])
      )

    ~H"""
    <dl class="mt-4 grid grid-cols-[repeat(auto-fit,minmax(140px,1fr))] gap-px overflow-hidden rounded-[10px] border border-border bg-border">
      <.fact label="Started" tip="When a worker first picked it up">
        <Core.local_time :if={@workflow.started_at} at={@workflow.started_at} format="time" />
        <span :if={!@workflow.started_at}>not yet</span>
      </.fact>
      <.fact
        label="Duration"
        tip={@duration_tip}
        meta={span_meta(@workflow.started_at, @workflow.completed_at || @workflow.compensated_at)}
      >
        {@duration}
      </.fact>
      <.fact
        label="Queued for"
        tip="From being created (or its scheduled time) to a worker starting it"
        meta={span_meta(@workflow.scheduled_at || @workflow.inserted_at, @workflow.started_at)}
      >
        {@queued}
      </.fact>
      <.fact label="Attempts" tip="Every try of every step, retries included">{@attempts}</.fact>
      <.fact label="Trigger" mono={false} tip={trigger_tip(@workflow)}>
        <.trigger workflow={@workflow} base_path={@base_path} />
      </.fact>
      <.fact
        label="Queue · node"
        tip="The queue it runs on · and, while running, the node holding it"
        meta={@workflow.locked_by}
      >
        {@workflow.queue}{if @workflow.locked_by && @workflow.status == :running, do: " · " <> short_node(@workflow.locked_by)}
      </.fact>
      <.fact
        :if={@workflow.deadline_at && @workflow.status in [:pending, :running, :waiting]}
        label="Times out"
        mono={false}
        tip="The workflow's timeout · if it isn't done by then, it fails and compensates"
      >
        <Core.relative_time at={@workflow.deadline_at} />
      </.fact>
      <.fact :if={@children > 0} label="Child runs" mono={false} tip="Runs its steps started · see Family">
        <.link patch={run_path(@base_path, @workflow.id, :family)} class="text-primary hover:underline">
          {@children}
        </.link>
      </.fact>
    </dl>
    """
  end

  attr :label, :string, required: true
  attr :mono, :boolean, default: true
  attr :tip, :string, default: nil
  attr :meta, :string, default: nil
  slot :inner_block, required: true

  defp fact(assigns) do
    ~H"""
    <div
      class="flex min-w-0 flex-col gap-0.5 bg-card px-3.5 py-2.5"
      data-tip-title={@tip && @label}
      data-tip={@tip}
      data-tip-meta={@meta}
    >
      <dt><Core.label>{@label}</Core.label></dt>
      <dd class={["truncate text-[13px] font-medium", @mono && "font-mono"]}>
        {render_slot(@inner_block)}
      </dd>
    </div>
    """
  end

  attr :workflow, :map, required: true
  attr :base_path, :string, required: true

  defp trigger(%{workflow: %{trigger: :schedule}} = assigns) do
    ~H"""
    Schedule
    <.link
      :if={@workflow.trigger_ref}
      navigate={DPath.schedule(@base_path, @workflow.trigger_ref)}
      class="font-mono text-primary hover:underline"
    >
      {@workflow.trigger_ref}
    </.link>
    """
  end

  defp trigger(%{workflow: %{trigger: :rerun, trigger_ref: ref}} = assigns) when is_binary(ref) do
    ~H"""
    Rerun of
    <.link navigate={DPath.execution(@base_path, @workflow.trigger_ref)} class="font-mono text-primary hover:underline">
      {short(@workflow.trigger_ref)}
    </.link>
    """
  end

  defp trigger(%{workflow: %{parent_workflow_id: parent}} = assigns) when is_binary(parent) do
    ~H"""
    Child of
    <.link navigate={DPath.execution(@base_path, @workflow.parent_workflow_id)} class="font-mono text-primary hover:underline">
      {short(@workflow.parent_workflow_id)}
    </.link>
    """
  end

  defp trigger(%{workflow: %{trigger: :api}} = assigns), do: ~H"API"
  defp trigger(assigns), do: ~H"—"

  # ---- View switch + bodies -----------------------------------------------------

  attr :view, :atom, required: true
  attr :views, :list, required: true
  attr :base_path, :string, required: true
  attr :id, :string, required: true

  defp view_switch(assigns) do
    ~H"""
    <nav class="inline-flex overflow-hidden rounded-md border border-input" aria-label="Run view">
      <.link
        :for={{view, label} <- @views}
        patch={run_path(@base_path, @id, view)}
        aria-current={@view == view && "page"}
        data-tip={view_tip(view)}
        class={[
          "h-7 px-3 inline-flex items-center text-xs font-medium transition-colors",
          "[&+&]:border-l [&+&]:border-border",
          if(@view == view,
            do: "bg-secondary text-foreground",
            else: "text-subtle-foreground hover:text-foreground"
          )
        ]}
      >
        {label}
      </.link>
    </nav>
    """
  end

  defp view_tip(:trace), do: "Every step on a timeline, with each attempt"
  defp view_tip(:graph), do: "The workflow's shape, and the path this run took"
  defp view_tip(:logs), do: "What the steps logged"
  defp view_tip(:context), do: "The run's input and what its steps stored"
  defp view_tip(:family), do: "Its parent and child runs"

  defp trigger_tip(%{trigger: :schedule}), do: "Started by a schedule"
  defp trigger_tip(%{trigger: :rerun}), do: "A rerun of an earlier run, with its input"

  defp trigger_tip(%{parent_workflow_id: parent}) when is_binary(parent),
    do: "Started by a step of its parent run"

  defp trigger_tip(%{trigger: :api}), do: "Started from code"
  defp trigger_tip(_workflow), do: "What started this run"

  defp span_meta(%DateTime{} = from, %DateTime{} = to), do: "#{hms(from)} → #{hms(to)} UTC"

  defp span_meta(_from, _to), do: nil

  defp hms(at), do: at |> Calendar.strftime("%H:%M:%S.%f") |> String.slice(0, 12)

  defp view_list(family) do
    base = [trace: "Trace", graph: "Graph", logs: "Logs", context: "Context"]
    if family_visible?(family), do: base ++ [family: "Family"], else: base
  end

  attr :view, :atom, required: true
  attr :workflow, :map, required: true
  attr :steps, :list, required: true
  attr :family, :map, required: true
  attr :trace, :map, required: true
  attr :selected, :map, default: nil
  attr :picked, :boolean, default: false, doc: "graph: a step was clicked (`?step=`)"
  attr :base_path, :string, required: true

  defp view_body(%{view: :trace} = assigns) do
    ~H"""
    <.trace_view trace={@trace} selected={@selected} base_path={@base_path} id={@workflow.id} />
    """
  end

  defp view_body(%{view: :graph} = assigns) do
    ~H"""
    <div class="px-3.5 pb-3.5">
      <.live_component
        module={FlowGraph}
        id={"flow-" <> @workflow.id}
        kind={:flow}
        workflow={@workflow}
        steps={@steps}
        family={@family}
        selected={@picked && @selected}
        base_path={@base_path}
      />
    </div>
    """
  end

  defp view_body(%{view: :logs} = assigns) do
    ~H"""
    <div class="border-t border-border">
      <.live_component module={LogsTab} id={"logs-" <> @workflow.id} steps={@steps} />
    </div>
    """
  end

  defp view_body(%{view: :context} = assigns) do
    ~H"""
    <div class="px-3.5 pb-3.5"><IoTab.io_tab workflow={@workflow} /></div>
    """
  end

  defp view_body(%{view: :family} = assigns) do
    ~H"""
    <div class="px-3.5 pb-3.5">
      <ChildrenTab.children_tab workflow={@workflow} family={@family} steps={@steps} base_path={@base_path} />
    </div>
    """
  end

  # ---- Trace ------------------------------------------------------------------

  attr :trace, :map, required: true
  attr :selected, :map, default: nil
  attr :base_path, :string, required: true
  attr :id, :string, required: true

  defp trace_view(%{trace: %{rows: []}} = assigns) do
    ~H"""
    <div class="border-t border-border px-4 py-10 text-center text-xs text-muted-foreground">
      No steps have run yet.
    </div>
    """
  end

  defp trace_view(assigns) do
    assigns = assign(assigns, first_comp: Enum.find(assigns.trace.rows, & &1.compensation?))

    ~H"""
    <div>
      <div class="grid grid-cols-[minmax(150px,240px)_minmax(0,1fr)_76px] items-end border-b border-border pl-3.5">
        <span class="pb-1.5 text-xs text-muted-foreground">Step</span>
        <div class="relative h-6" data-tip="Time since the run started">
          <span
            :for={tick <- @trace.ticks}
            class="absolute bottom-1.5 whitespace-nowrap font-mono text-[11px] text-muted-foreground [&:not(:first-child)]:-translate-x-1/2"
            style={"left: #{tick.pct}%"}
          >
            {tick.label}
          </span>
        </div>
        <span
          class="pb-1.5 pr-3.5 text-right text-xs text-muted-foreground"
          data-tip-title="Active time"
          data-tip="Time spent running, every attempt added up · backoff and waits left out"
        >
          Time
        </span>
      </div>

      <div :for={row <- @trace.rows}>
        <div
          :if={@first_comp && row.key == @first_comp.key}
          class="flex h-7 items-center gap-2 border-b border-border bg-comp/7 px-3.5 text-xs text-comp"
        >
          <span aria-hidden="true">↺</span>
          <span data-tip="A step failed for good, so the steps marked compensate: run their undo steps · newest first">
            Compensation — undoing completed steps in reverse order
          </span>
        </div>
        <.link
          patch={run_path(@base_path, @id, :trace, step: row.key)}
          aria-current={@selected && @selected.key == row.key && "true"}
          class={[
            "grid grid-cols-[minmax(150px,240px)_minmax(0,1fr)_76px] items-center h-[34px] pl-3.5",
            "border-b border-border last:border-b-0 transition-colors",
            if(@selected && @selected.key == row.key,
              do: "bg-primary/9",
              else: "hover:bg-accent"
            )
          ]}
        >
          <span class="flex min-w-0 items-center gap-2 pr-2.5" style={"padding-left: #{row.depth * 18}px"}>
            <Core.status_dot status={row.status} />
            <span
              class={[
                "truncate font-mono text-[12.5px]",
                row.status == :failed && "text-destructive",
                row.status in [:pending] && "text-muted-foreground"
              ]}
              data-tip-title={row.name}
              data-tip={row_kind(row) <> " · " <> row_summary(row)}
              data-tip-meta={row.raw_name != row.name && row.raw_name}
            >
              {row.name}
            </span>
            <span
              :if={row.attempts > 1}
              class="text-xs text-muted-foreground"
              data-tip-title={"#{row.attempts} attempts"}
              data-tip="Retried after failing · each try is its own bar"
            >
              ×{row.attempts}
            </span>
            <span
              :if={row.child_workflow_id}
              class="text-xs text-muted-foreground"
              data-tip="This step started a run of its own · open it from Output"
              data-tip-meta={row.child_workflow_id}
            >
              child run
            </span>
          </span>
          <span class="relative h-full">
            <span
              :for={tick <- tl(@trace.ticks)}
              class="absolute inset-y-0 border-l border-dashed border-border"
              style={"left: #{tick.pct}%"}
            >
            </span>
            <span
              :for={seg <- row.segments}
              class={["absolute", segment_class(seg.kind)]}
              style={"left: #{seg.left}%; width: #{seg.width}%"}
              data-tip-title={seg.title}
              data-tip={seg.tip}
              data-tip-meta={seg.meta}
            >
            </span>
          </span>
          <span
            class="pr-3.5 text-right font-mono text-xs text-subtle-foreground"
            data-tip-title="Active time"
            data-tip="Time spent running, every attempt added up · backoff and waits left out"
          >
            {Trace.format_ms(row.duration_ms)}
          </span>
        </.link>
      </div>

      <div class="flex flex-wrap gap-x-4 gap-y-1.5 border-t border-border px-3.5 py-2.5 text-xs text-subtle-foreground">
        <span class="inline-flex items-center gap-1.5"><span class="h-2 w-3.5 rounded-sm bg-chart-ok"></span>Completed</span>
        <span class="inline-flex items-center gap-1.5"><span class="h-2 w-3.5 rounded-sm bg-chart-fail"></span>Failed attempt</span>
        <span class="inline-flex items-center gap-1.5"><span class="h-2 w-3.5 rounded-sm bg-primary"></span>Running</span>
        <span class="inline-flex items-center gap-1.5"><span class="h-0 w-3.5 border-t-2 border-dashed border-muted-foreground"></span>Backoff</span>
        <span class="inline-flex items-center gap-1.5"><span class="h-0 w-3.5 border-t-2 border-dashed border-warning"></span>Waiting</span>
        <span class="inline-flex items-center gap-1.5"><span class="h-2 w-3.5 rounded-sm bg-comp"></span>Compensation</span>
      </div>
    </div>
    """
  end

  defp segment_class(:ok), do: "top-[10px] h-3.5 min-w-[3px] rounded-[3px] bg-chart-ok"
  defp segment_class(:fail), do: "top-[10px] h-3.5 min-w-[3px] rounded-[3px] bg-chart-fail"
  defp segment_class(:comp), do: "top-[10px] h-3.5 min-w-[3px] rounded-[3px] bg-comp"

  defp segment_class(:running),
    do: "top-[10px] h-3.5 min-w-[3px] rounded-[3px] bg-primary animate-pulse"

  defp segment_class(:backoff), do: "top-[16px] border-t-2 border-dashed border-muted-foreground"
  defp segment_class(:wait), do: "top-[16px] border-t-2 border-dashed border-warning"
  defp segment_class(_), do: "top-[10px] h-3.5 min-w-[3px] rounded-[3px] bg-off"

  # ---- Inspector --------------------------------------------------------------

  attr :row, :map, required: true
  attr :pane, :string, required: true
  attr :panes, :list, required: true
  attr :view, :atom, required: true
  attr :base_path, :string, required: true
  attr :id, :string, required: true

  defp inspector(assigns) do
    ~H"""
    <aside
      class="flex-[2_1_380px] min-w-0 overflow-hidden rounded-[10px] border border-border bg-card"
      aria-label="Step inspector"
    >
      <div class="flex flex-col gap-1.5 px-4 pt-3.5 pb-2.5">
        <div class="flex items-center justify-between gap-2">
          <div class="flex min-w-0 items-center gap-2.5">
            <Core.status_pill status={@row.status} />
            <span
              class="truncate font-mono text-sm font-medium"
              data-tip={@row.name}
              data-tip-meta={@row.raw_name != @row.name && @row.raw_name}
            >
              {@row.name}
            </span>
          </div>
          <div class="flex shrink-0 items-center gap-1.5">
            <span class="text-xs text-muted-foreground" data-tip={kind_tip(@row)}>
              {row_kind(@row)}
            </span>
            <.link
              :if={@view == :graph}
              patch={run_path(@base_path, @id, :graph)}
              aria-label="Close the inspector"
              data-tip="Close"
              data-tip-kbd="Esc"
              phx-window-keydown={JS.patch(run_path(@base_path, @id, :graph))}
              phx-key="Escape"
              class="-mr-1.5 inline-flex size-6 items-center justify-center rounded-md text-muted-foreground hover:bg-accent hover:text-foreground"
            >
              <Core.icon name="x-mark" class="size-3.5" />
            </.link>
          </div>
        </div>
        <p class="text-xs text-subtle-foreground">{row_summary(@row)}</p>
        <p class="flex flex-wrap gap-x-3 gap-y-0.5 text-xs text-muted-foreground">
          <span :if={@row.first_at}>Started <Core.local_time at={@row.first_at} format="time" /></span>
          <.link
            :if={@row.depth == 1}
            navigate={DPath.execution(@base_path, @row.workflow_id)}
            class="text-primary hover:underline"
            data-tip="It ran as a run of its own, started by this one"
            data-tip-meta={@row.workflow_id}
          >
            ran in child run {short(@row.workflow_id)} →
          </.link>
          <.link
            :if={@row.child_workflow_id}
            navigate={DPath.execution(@base_path, @row.child_workflow_id)}
            class="text-primary hover:underline"
            data-tip="The run this step started"
            data-tip-meta={@row.child_workflow_id}
          >
            started run {short(@row.child_workflow_id)} →
          </.link>
        </p>
      </div>

      <nav class="flex gap-0.5 overflow-x-auto border-b border-border px-2.5" aria-label="Step details">
        <.link
          :for={{pane, label} <- @panes}
          patch={run_path(@base_path, @id, @view, step: @row.key, pane: pane)}
          aria-current={@pane == pane && "page"}
          data-tip={pane_tip(pane)}
          class={[
            "-mb-px whitespace-nowrap border-b-2 px-2.5 py-2 text-[13px] font-medium transition-colors",
            cond do
              @pane == pane and pane == "error" -> "border-destructive text-destructive"
              @pane == pane -> "border-foreground text-foreground"
              pane == "error" -> "border-transparent text-destructive"
              true -> "border-transparent text-subtle-foreground hover:text-foreground"
            end
          ]}
        >
          {label}
        </.link>
      </nav>

      <.pane pane={@pane} row={@row} base_path={@base_path} />
    </aside>
    """
  end

  attr :pane, :string, required: true
  attr :row, :map, required: true
  attr :base_path, :string, required: true

  defp pane(%{pane: "error"} = assigns) do
    assigns = assign(assigns, error: Trace.error_parts(assigns.row.latest.error))

    ~H"""
    <div class="flex flex-col gap-3 p-4">
      <div class="flex flex-col gap-0.5">
        <span class="font-mono font-medium text-destructive">
          {@error.type || "Returned {:error, …}"}
        </span>
        <span>{@error.message}</span>
      </div>
      <div :if={@error.details} class="flex flex-col gap-1.5">
        <Core.label>Other fields</Core.label>
        <Core.json value={@error.details} />
      </div>
      <.stack :if={@error.frames != []} frames={@error.frames} />
    </div>
    """
  end

  defp pane(%{pane: "input"} = assigns) do
    ~H"""
    <div class="p-4"><Core.json value={@row.latest.input} /></div>
    """
  end

  defp pane(%{pane: "output"} = assigns) do
    ~H"""
    <div class="flex flex-col gap-3 p-4">
      <Core.json value={Trace.returned(@row.latest.output)} />
      <Core.button
        :if={@row.child_workflow_id}
        size="sm"
        navigate={DPath.execution(@base_path, @row.child_workflow_id)}
        class="self-start"
      >
        Open child run →
      </Core.button>
    </div>
    """
  end

  defp pane(%{pane: "logs"} = assigns) do
    assigns = assign(assigns, logs: Enum.flat_map(assigns.row.execs, &(&1.logs || [])))

    ~H"""
    <div :if={@logs == []} class="px-4 py-8 text-center text-xs text-muted-foreground">
      No logs captured for this step.
    </div>
    <div :if={@logs != []} class="py-1">
      <LogLine.row :for={entry <- @logs} entry={entry} show_step={false} />
    </div>
    """
  end

  defp pane(%{pane: "attempts"} = assigns) do
    ~H"""
    <ol>
      <li
        :for={exec <- @row.execs}
        class="grid grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-2.5 border-b border-border px-4 py-2.5 last:border-b-0"
      >
        <Core.status_dot status={exec.status} />
        <div class="flex min-w-0 flex-col">
          <span>
            {attempt_label(exec)}
            <span :if={exec.started_at} class="text-xs text-muted-foreground">
              · <Core.local_time at={exec.started_at} format="time" />
            </span>
          </span>
          <span
            :if={exec.error}
            class="truncate font-mono text-xs text-muted-foreground"
            data-tip-title={Trace.error_parts(exec.error).type || "Error"}
            data-tip={Trace.error_parts(exec.error).message}
          >
            {error_line(Trace.error_parts(exec.error))}
          </span>
        </div>
        <span class="font-mono text-xs text-subtle-foreground" data-tip="How long this attempt ran">
          {Trace.format_ms(exec.duration_ms)}
        </span>
      </li>
    </ol>
    """
  end

  attr :frames, :list, required: true

  # The stack, innermost first: your app's frames in full, each run of library
  # frames folded to one line you can open (all open when none are yours).
  defp stack(assigns) do
    assigns =
      assign(assigns,
        chunks: Enum.chunk_by(assigns.frames, & &1.app?),
        mine?: Enum.any?(assigns.frames, & &1.app?)
      )

    ~H"""
    <section class="overflow-hidden rounded-lg border border-border bg-background">
      <header class="flex items-center justify-between gap-2 border-b border-border py-1 pl-3 pr-1">
        <span
          class="text-xs text-muted-foreground"
          data-tip="Innermost call first · frames from your app are shown, library frames are folded"
        >
          Stack · {length(@frames)} frames
        </span>
        <Core.copy_button
          text={Enum.map_join(@frames, "\n", & &1.text)}
          label="Copy the stack"
          class="border-0 bg-transparent"
        />
      </header>
      <ol class="py-1">
        <%= for chunk <- @chunks do %>
          <%= if hd(chunk).app? or length(chunk) == 1 do %>
            <.frame :for={frame <- chunk} frame={frame} />
          <% else %>
            <li>
              <details class="group/frames" open={not @mine?}>
                <summary class="flex cursor-pointer list-none items-center gap-1.5 px-3 py-1 text-xs text-muted-foreground hover:text-foreground [&::-webkit-details-marker]:hidden">
                  <Core.icon name="chevron-right" class="size-3 transition-transform group-open/frames:rotate-90" />
                  {length(chunk)} library frames
                  <span class="truncate text-muted-foreground/70">
                    · {chunk |> Enum.map(& &1.app) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.join(", ")}
                  </span>
                </summary>
                <ol><.frame :for={frame <- chunk} frame={frame} /></ol>
              </details>
            </li>
          <% end %>
        <% end %>
      </ol>
    </section>
    """
  end

  attr :frame, :map, required: true

  defp frame(assigns) do
    ~H"""
    <li
      class={["px-3 py-1", @frame.app? && "border-l-2 border-foreground/50 bg-accent/40"]}
      data-tip={@frame.app? && "Your app's code"}
      data-tip-meta={@frame.text}
    >
      <div class={[
        "break-all font-mono text-xs",
        if(@frame.app?, do: "font-medium text-foreground", else: "text-subtle-foreground")
      ]}>
        {@frame.function}
      </div>
      <div :if={@frame.where} class="break-all font-mono text-[11px] text-muted-foreground">
        {@frame.where}<span :if={@frame.app}> · {@frame.app}</span>
      </div>
    </li>
    """
  end

  defp error_line(%{type: nil, message: message}), do: message
  defp error_line(%{type: type, message: message}), do: "#{type}: #{message}"

  defp attempt_label(%{status: :waiting}), do: "Suspended"
  defp attempt_label(exec), do: "Attempt #{exec.attempt}"

  defp kind_tip(%{compensation?: true}), do: "Undoes an earlier step after a later one failed"

  defp kind_tip(%{child_workflow_id: id}) when is_binary(id),
    do: "A step that started a run of its own"

  defp kind_tip(%{depth: 1}), do: "Ran inside a child run · shown here with its parent's steps"
  defp kind_tip(_row), do: "The kind of step, as the workflow defines it"

  defp pane_tip("error"), do: "The error from its last attempt, with the stack"
  defp pane_tip("input"), do: "What the step was given"
  defp pane_tip("output"), do: "What the step returned"
  defp pane_tip("logs"), do: "What the step logged, every attempt"
  defp pane_tip("attempts"), do: "Each try, with its error and how long it took"
  defp pane_tip(_pane), do: nil

  defp row_kind(%{compensation?: true}), do: "compensation"
  defp row_kind(%{child_workflow_id: id}) when is_binary(id), do: "step · child run"
  defp row_kind(%{depth: 1}), do: "step in a child run"
  defp row_kind(%{step_type: type}), do: type || "step"

  defp row_summary(%{status: :failed} = row),
    do:
      "Failed on #{Format.count(row.attempts, "attempt")} · #{Trace.format_ms(row.duration_ms)} active"

  defp row_summary(%{status: :completed, attempts: n} = row) when n > 1,
    do: "Completed on attempt #{n} · #{Trace.format_ms(row.duration_ms)} active"

  defp row_summary(%{status: :completed} = row),
    do: "Completed in #{Trace.format_ms(row.duration_ms)}"

  defp row_summary(%{status: :running}), do: "Running now"
  defp row_summary(%{status: :waiting}), do: "Suspended — waiting to resume"
  defp row_summary(row), do: String.capitalize(to_string(row.status))

  # ============================================================================
  # Data
  # ============================================================================

  defp assign_trace(%{assigns: %{workflow: nil}} = socket), do: socket

  defp assign_trace(socket) do
    %{workflow: workflow, steps: steps, family: family, now: now} = socket.assigns
    child_ids = Enum.map(family.children || [], & &1.id)
    trace = Trace.build(workflow, steps, child_ids, now)

    failed_row =
      trace.rows |> Enum.filter(&(&1.status == :failed and not &1.compensation?)) |> List.last()

    assign(socket, trace: trace, failed_row: failed_row)
  end

  # The selected row comes from `?step=`, defaulting to the failed step, then
  # whatever is running, then the last step to run.
  defp assign_selection(%{assigns: %{not_found?: true}} = socket), do: socket

  defp assign_selection(socket) do
    %{trace: trace, failed_row: failed_row} = socket.assigns
    key = socket.assigns[:selected_key]
    picked = key && Enum.find(trace.rows, &(key in &1.ids))

    selected =
      picked || failed_row ||
        Enum.find(trace.rows, &(&1.status == :running)) || List.last(trace.rows)

    panes = panes(selected)
    pane = socket.assigns[:pane]
    names = Enum.map(panes, &elem(&1, 0))

    # The Trace view always inspects a step (the failed one by default); the
    # Graph view only once a card is clicked.
    assign(socket,
      selected: selected,
      graph_pick: socket.assigns[:view] == :graph and picked != nil,
      panes: panes,
      active_pane: if(pane in names, do: pane, else: default_pane(selected))
    )
  end

  defp panes(nil), do: []

  defp panes(row) do
    logs = Enum.reduce(row.execs, 0, &(&2 + length(&1.logs || [])))

    if(row.latest.error, do: [{"error", "Error"}], else: []) ++
      [
        {"input", "Input"},
        {"output", "Output"},
        {"logs", "Logs (#{logs})"},
        {"attempts", "Attempts (#{length(row.execs)})"}
      ]
  end

  defp default_pane(%{latest: %{error: error}}) when not is_nil(error), do: "error"
  defp default_pane(_row), do: "output"

  defp load_workflow(%{assigns: %{workflow_id: nil}} = socket), do: not_found(socket)

  defp load_workflow(socket) do
    case Durable.Config.get_safe(socket.assigns.durable) do
      nil -> not_found(socket)
      config -> do_load(socket, config)
    end
  end

  defp not_found(socket) do
    assign(socket,
      not_found?: true,
      workflow: nil,
      steps: [],
      pending_inputs: [],
      trace: %{rows: [], ticks: [], span_ms: 0, live?: false},
      failed_row: nil,
      selected: nil,
      family: %{root: nil, parent: nil, children: [], related_ids: []}
    )
  end

  defp do_load(socket, config) do
    case Durable.Repo.get(config, WorkflowExecution, socket.assigns.workflow_id) do
      nil ->
        not_found(socket)

      execution ->
        family = load_family(config, execution)

        socket
        |> assign(
          not_found?: false,
          workflow: execution,
          steps: fetch_steps(config, family.related_ids),
          pending_inputs: fetch_pending_inputs(config, execution.id),
          family: family,
          page_title: execution.workflow_name
        )
        |> assign_trace()
    end
  rescue
    Ecto.Query.CastError -> not_found(socket)
  end

  # Walk up to the root, then collect its descendants: the graph paints the
  # whole family's progress whichever member's URL is open.
  defp load_family(config, %WorkflowExecution{} = exec) do
    root = walk_to_root(config, exec)
    descendants = fetch_descendants(config, root.id)
    children = fetch_children(config, exec.id)

    parent =
      cond do
        exec.id == root.id -> nil
        exec.parent_workflow_id == root.id -> root
        true -> Enum.find(descendants, &(&1.id == exec.parent_workflow_id))
      end

    related_ids =
      [root.id | Enum.map(descendants, & &1.id)] ++ Enum.map(children, & &1.id)

    %{
      root: root,
      parent: parent,
      children: children,
      siblings: collect_siblings(descendants, exec),
      all_descendants: descendants,
      related_ids: Enum.uniq(related_ids)
    }
  end

  defp walk_to_root(_config, %WorkflowExecution{parent_workflow_id: nil} = exec), do: exec

  defp walk_to_root(config, %WorkflowExecution{parent_workflow_id: pid} = exec) do
    case Durable.Repo.get(config, WorkflowExecution, pid) do
      nil -> exec
      parent -> walk_to_root(config, parent)
    end
  end

  defp fetch_descendants(config, root_id), do: fetch_children(config, root_id)

  defp fetch_children(config, parent_id) do
    Durable.Repo.all(
      config,
      from(w in WorkflowExecution,
        where: w.parent_workflow_id == ^parent_id,
        order_by: [asc: w.inserted_at]
      )
    )
  end

  defp collect_siblings(_descendants, %WorkflowExecution{parent_workflow_id: nil}), do: []

  defp collect_siblings(descendants, %WorkflowExecution{} = exec) do
    Enum.filter(descendants, fn d ->
      d.parent_workflow_id == exec.parent_workflow_id and d.id != exec.id
    end)
  end

  defp fetch_steps(config, workflow_ids) do
    Durable.Repo.all(
      config,
      from(s in StepExecution,
        where: s.workflow_id in ^workflow_ids,
        order_by: [asc: s.inserted_at]
      )
    )
  end

  defp fetch_pending_inputs(config, workflow_id) do
    Durable.Repo.all(
      config,
      from(p in PendingInput,
        where: p.workflow_id == ^workflow_id,
        order_by: [asc: p.inserted_at]
      )
    )
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp run_path(base, id, view, query \\ []) do
    path = DPath.execution_tab(base, id, Atom.to_string(view))
    query = Enum.reject(query, fn {_k, v} -> is_nil(v) end)
    if query == [], do: path, else: path <> "?" <> URI.encode_query(query)
  end

  defp run_duration(%{started_at: nil}, _now), do: "—"

  # Runs rolled back before 1.0 have no completed_at; fall back to when the
  # rollback finished, then the last write.
  defp run_duration(%{started_at: started} = w, now) do
    finish =
      w.completed_at || w.compensated_at ||
        if(w.status in @live_statuses, do: now, else: w.updated_at)

    Trace.format_ms(max(DateTime.diff(finish, started, :millisecond), 0))
  end

  defp queued_for(%{started_at: nil}), do: "—"

  defp queued_for(%{started_at: started} = w) do
    from = w.scheduled_at || w.inserted_at
    Trace.format_ms(max(DateTime.diff(started, from, :millisecond), 0))
  end

  defp family_visible?(%{parent: parent, all_descendants: descs}),
    do: !is_nil(parent) or (is_list(descs) and descs != [])

  defp family_visible?(_family), do: false

  defp short(nil), do: "—"
  defp short(id) when is_binary(id), do: String.slice(id, 0, 8)

  # Node ids are `host-123456` or `name@host`; the host part is what people
  # recognise.
  defp short_node(node), do: node |> String.split("@") |> List.last() |> String.slice(0, 24)
end
