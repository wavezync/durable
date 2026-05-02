defmodule DurableDashboard.Components.Workflow.FlowGraph do
  @moduledoc """
  LiveComponent that wraps the ReactFlow island defined in
  `assets/src/v2/react/flow_graph.tsx` (mounted by the JS hook in
  `assets/src/v2/hooks/flow_graph.ts`).

  ## Communication contract

  - **LV → JS:** Initial graph passes through `data-graph` (JSON in the host
    element's dataset). Subsequent updates use `push_event/3`:
    - `"<id>:replace"` `%{graph: %{nodes: [...], edges: [...]}}`
    - `"<id>:patch-node"` `%{id: node_id, patch: %{...}}` — partial updates
      for status overlays (defer real wiring to phase 5 polish).
  - **JS → LV:** `step-clicked` — fired when the user clicks a step node;
    payload `%{"step_name" => name}`. The LC resolves the matching
    `StepExecution` from `assigns.steps` and opens the inspector sheet.

  ## Why a LiveComponent

  Each instance owns a graph version + a JS hook id; render-time identity
  matters. Stateful → LC. Function-component would force every parent LV
  to track the version assign manually — exactly the duplication we're
  avoiding.
  """

  use Phoenix.LiveComponent

  alias DurableDashboard.Components.Core
  alias DurableDashboard.GraphBuilder
  alias DurableDashboard.Path, as: DPath

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       graph: %{nodes: [], edges: []},
       version: 0,
       error?: false,
       selected_step: nil,
       selected_step_name: nil,
       sheet_open?: false,
       active_tab: "info",
       child_workflow: nil,
       child_steps: []
     )}
  end

  @impl true
  def update(%{kind: :flow} = assigns, socket) do
    new_graph = build_graph(assigns)
    next_version = socket.assigns.version + 1
    socket = assign(socket, Map.merge(assigns, %{graph: new_graph, version: next_version}))

    # If the open inspector is bound to a step that just refreshed, swap
    # in the latest version so timestamps + status stay accurate without
    # closing the sheet.
    socket = refresh_selected_step(socket)

    socket =
      if connected?(socket) and socket.assigns.version > 1 do
        push_event(socket, replace_event(socket.assigns.id), %{graph: new_graph})
      else
        socket
      end

    {:ok, socket}
  end

  def update(assigns, socket) do
    # Default: no graph — render the empty state.
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("step-clicked", payload, socket) do
    step_name = payload["step_name"]
    child_id = payload["child_workflow_id"]

    case find_step(socket.assigns[:steps] || [], step_name) do
      %{workflow_id: foreign_id} = step
      when not is_nil(foreign_id) and foreign_id != nil ->
        cond do
          # Parallel-child step (its execution lives in a different workflow
          # row). Navigate to that child's flow page — keeps URL truthful.
          foreign_id != socket.assigns.workflow.id ->
            {:noreply,
             push_navigate(socket,
               to: DPath.workflow_tab(socket.assigns.base_path, foreign_id, :flow)
             )}

          # call_workflow / start_workflow: the calling step ran in the parent
          # but spawned a child execution. Open the inspector and load the
          # child's data so the sheet can preview its mini-flow + I/O.
          true ->
            open_inspector(socket, step, step_name, child_id)
        end

      step ->
        open_inspector(socket, step, step_name, child_id)
    end
  end

  def handle_event("close-inspector", _params, socket) do
    {:noreply, assign(socket, sheet_open?: false, child_workflow: nil, child_steps: [])}
  end

  def handle_event("set-tab", %{"tab" => tab}, socket) when tab in ~w(info io error child) do
    {:noreply, assign(socket, active_tab: tab)}
  end

  defp open_inspector(socket, nil, step_name, child_id) do
    {child_workflow, child_steps} = load_child(socket, child_id)

    {:noreply,
     assign(socket,
       selected_step: nil,
       selected_step_name: step_name,
       sheet_open?: true,
       active_tab: if(child_workflow, do: "child", else: "info"),
       child_workflow: child_workflow,
       child_steps: child_steps
     )}
  end

  defp open_inspector(socket, step, step_name, child_id) do
    {child_workflow, child_steps} = load_child(socket, child_id)

    {:noreply,
     assign(socket,
       selected_step: step,
       selected_step_name: step_name,
       sheet_open?: true,
       active_tab: default_tab(step, child_workflow),
       child_workflow: child_workflow,
       child_steps: child_steps
     )}
  end

  # Resolve a child workflow id (received via the click event) into the
  # WorkflowExecution row + its step executions, both serialized via the
  # dashboard's existing serializer. Returns {nil, []} when no child id is
  # provided or the lookup fails — the caller renders the rest of the
  # inspector unchanged in that case.
  defp load_child(_socket, nil), do: {nil, []}
  defp load_child(_socket, ""), do: {nil, []}

  defp load_child(socket, child_id) when is_binary(child_id) do
    require Ecto.Query
    alias Durable.Storage.Schemas.{StepExecution, WorkflowExecution}

    durable = socket.assigns[:durable] || Durable
    config = Durable.Config.get(durable)

    case Durable.Repo.get(config, WorkflowExecution, child_id) do
      nil ->
        {nil, []}

      child ->
        steps =
          Durable.Repo.all(
            config,
            Ecto.Query.from(s in StepExecution,
              where: s.workflow_id == ^child_id,
              order_by: [asc: s.inserted_at]
            )
          )

        {child, steps}
    end
  rescue
    _ -> {nil, []}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <%= if @graph.nodes == [] do %>
        <Core.empty_state
          icon="exclamation-triangle"
          title="No graph available"
          description="The workflow definition isn't loaded on this node, so we can't reconstruct the graph. Make sure the workflow module is compiled into the dashboard's code path."
        />
      <% else %>
        <div
          id={@id}
          phx-hook="FlowGraph"
          phx-update="ignore"
          data-graph={Jason.encode!(@graph)}
          data-graph-version={@version}
          class="rounded-md border border-border bg-card overflow-hidden"
        >
        </div>
        <.step_inspector
          :if={@sheet_open?}
          step={@selected_step}
          step_name={@selected_step_name}
          active_tab={@active_tab}
          target={@myself}
          child_workflow={@child_workflow}
          child_steps={@child_steps}
          base_path={@base_path}
        />
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Step inspector — full-detail right-side sheet, opened on node click
  # ============================================================================

  attr :step, :any, default: nil
  attr :step_name, :string, required: true
  attr :active_tab, :string, default: "info"
  attr :target, :any, required: true
  attr :child_workflow, :any, default: nil
  attr :child_steps, :list, default: []
  attr :base_path, :string, default: "/dashboard"

  defp step_inspector(assigns) do
    ~H"""
    <div class="fixed inset-0 z-40">
      <div
        class="absolute inset-0 bg-background/70 backdrop-blur-[1px]"
        phx-click="close-inspector"
        phx-target={@target}
      >
      </div>
      <aside
        class="absolute right-0 top-0 flex h-full w-full max-w-xl flex-col border-l border-border bg-card shadow-2xl"
        role="dialog"
        aria-modal="true"
      >
        <header class="flex items-start justify-between gap-3 border-b border-border px-6 py-5">
          <div class="flex flex-col gap-1.5 min-w-0">
            <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-muted-foreground">
              Step inspector
            </p>
            <h2 class="font-sans text-2xl leading-[1.1] tracking-[-0.01em] text-foreground truncate">
              {display_name(@step, @step_name)}
            </h2>
            <div :if={@step} class="flex items-center gap-3 pt-1">
              <Core.status_pill status={@step.status} />
              <span class="font-mono text-[10px] uppercase tracking-[0.16em] text-muted-foreground">
                attempt ×{@step.attempt}
              </span>
              <span
                :if={@step.duration_ms}
                class="font-mono text-[10px] uppercase tracking-[0.16em] text-muted-foreground"
              >
                · {format_duration(@step.duration_ms)}
              </span>
            </div>
          </div>
          <Core.icon_button
            kind="ghost"
            size="sm"
            icon="x-mark"
            aria-label="Close"
            phx-click="close-inspector"
            phx-target={@target}
            class="shrink-0"
          />
        </header>

        <%= if @step do %>
          <nav class="flex items-center gap-1 border-b border-border px-6">
            <.tab_button
              :if={@child_workflow}
              label="Child"
              tab="child"
              active_tab={@active_tab}
              target={@target}
            />
            <.tab_button label="Info" tab="info" active_tab={@active_tab} target={@target} />
            <.tab_button label="I/O" tab="io" active_tab={@active_tab} target={@target} />
            <.tab_button
              :if={@step.error}
              label="Error"
              tab="error"
              active_tab={@active_tab}
              target={@target}
            />
          </nav>

          <div class="min-h-0 flex-1 overflow-auto thin-scroll">
            <%= case @active_tab do %>
              <% "info" -> %>
                <.info_tab step={@step} />
              <% "io" -> %>
                <.io_tab step={@step} />
              <% "error" -> %>
                <.error_tab step={@step} />
              <% "child" -> %>
                <.child_tab
                  child_workflow={@child_workflow}
                  child_steps={@child_steps}
                  base_path={@base_path}
                />
              <% _ -> %>
                <.info_tab step={@step} />
            <% end %>
          </div>
        <% else %>
          <div class="flex flex-1 items-center justify-center px-6 py-12 text-center">
            <Core.empty_state
              icon="information-circle"
              title="No execution data"
              description="This step hasn't been executed for this workflow yet, or it belongs to an unfired branch."
            />
          </div>
        <% end %>
      </aside>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :tab, :string, required: true
  attr :active_tab, :string, required: true
  attr :target, :any, required: true

  # Private sub-tab control used inside the inspector sheet only. Visual
  # style (mono uppercase + border-bottom indicator) is intentionally
  # distinct from `Workflow.Tabs` which is the page-level tab strip.
  defp tab_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="set-tab"
      phx-value-tab={@tab}
      phx-target={@target}
      class={[
        "border-b-2 px-3 py-3 font-mono text-[11px] uppercase tracking-[0.18em] transition-colors",
        if(@active_tab == @tab,
          do: "border-primary text-foreground",
          else: "border-transparent text-muted-foreground hover:text-foreground"
        )
      ]}
    >
      {@label}
    </button>
    """
  end

  attr :step, :any, required: true

  defp info_tab(assigns) do
    ~H"""
    <dl class="divide-y divide-border border-y border-border">
      <.info_row label="Step" value={@step.step_name} mono={true} />
      <.info_row label="Type" value={@step.step_type} mono={true} />
      <.info_row label="Status" value={to_string(@step.status)} mono={true} />
      <.info_row label="Attempt" value={Integer.to_string(@step.attempt)} mono={true} />
      <.info_row
        label="Duration"
        value={if @step.duration_ms, do: format_duration(@step.duration_ms), else: "—"}
        mono={true}
      />
      <.info_row label="Started" value={format_timestamp(@step.started_at)} />
      <.info_row label="Completed" value={format_timestamp(@step.completed_at)} />
    </dl>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :mono, :boolean, default: false

  defp info_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-4 px-6 py-2.5">
      <dt class="font-mono text-[10px] uppercase tracking-[0.18em] text-muted-foreground">
        {@label}
      </dt>
      <dd class={[
        "truncate text-right text-xs text-foreground",
        @mono && "font-mono"
      ]}>
        {@value}
      </dd>
    </div>
    """
  end

  attr :step, :any, required: true

  defp io_tab(assigns) do
    ~H"""
    <div class="space-y-5 p-6">
      <.io_block label="Input" value={@step.input} />
      <.io_block label="Output" value={@step.output} />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, default: nil

  defp io_block(assigns) do
    ~H"""
    <div class="border border-border">
      <div class="flex items-center justify-between border-b border-border bg-muted/30 px-3 py-1.5">
        <span class="font-mono text-[10px] uppercase tracking-[0.18em] text-muted-foreground">
          {@label}
        </span>
        <span class="font-mono text-[9px] text-muted-foreground/60">
          {if @value, do: "JSON", else: "null"}
        </span>
      </div>
      <pre class="thin-scroll max-h-[40vh] overflow-auto bg-background/50 p-3 font-mono text-[11px] text-foreground/90">{format_json(@value)}</pre>
    </div>
    """
  end

  attr :child_workflow, :any, required: true
  attr :child_steps, :list, required: true
  attr :base_path, :string, required: true

  # "Child" tab — opens when the clicked step spawned a sub-workflow via
  # call_workflow / start_workflow. Shows a header with the child's status,
  # a horizontal mini-flow of the child's step executions (status-tinted
  # chips), and a link to the child's full Flow page.
  defp child_tab(assigns) do
    ~H"""
    <div class="space-y-5 p-6">
      <header class="flex items-start justify-between gap-3">
        <div class="flex flex-col gap-1.5 min-w-0">
          <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-muted-foreground">
            Child workflow
          </p>
          <h3 class="font-sans text-base text-foreground truncate">
            {@child_workflow.workflow_name}
          </h3>
          <p class="font-mono text-[10px] text-muted-foreground/70 truncate">
            {short_module(@child_workflow.workflow_module)}
          </p>
          <div class="flex items-center gap-3 pt-1">
            <Core.status_pill status={to_string(@child_workflow.status)} />
            <span
              :if={@child_workflow.completed_at && @child_workflow.started_at}
              class="font-mono text-[10px] uppercase tracking-[0.16em] text-muted-foreground"
            >
              {format_duration(
                DateTime.diff(@child_workflow.completed_at, @child_workflow.started_at, :millisecond)
              )}
            </span>
          </div>
        </div>
        <.link
          navigate={DPath.workflow_tab(@base_path, @child_workflow.id, :flow)}
          class="shrink-0 rounded-md border border-border px-3 py-1.5 font-mono text-[10px] uppercase tracking-[0.16em] text-muted-foreground hover:border-foreground/30 hover:text-foreground transition-colors"
        >
          Open full flow →
        </.link>
      </header>

      <section :if={@child_steps != []}>
        <p class="font-mono text-[10px] uppercase tracking-[0.18em] text-muted-foreground mb-2">
          Mini-flow
        </p>
        <div class="flex flex-wrap items-center gap-1 rounded-md border border-border bg-background/50 p-3">
          <%= for {step, idx} <- Enum.with_index(@child_steps) do %>
            <.mini_chip step={step} />
            <span :if={idx < length(@child_steps) - 1} class="text-muted-foreground/40">›</span>
          <% end %>
        </div>
      </section>

      <section :if={@child_steps == []} class="rounded-md border border-border bg-background/50 p-4 text-center">
        <p class="font-mono text-[11px] text-muted-foreground">
          Child has not produced any steps yet.
        </p>
      </section>

      <section :if={@child_workflow.input || @child_workflow.context}>
        <.io_block label="Child input" value={@child_workflow.input} />
        <.io_block
          :if={@child_workflow.status == :completed}
          label="Child result"
          value={@child_workflow.context}
        />
        <.io_block
          :if={@child_workflow.error}
          label="Child error"
          value={@child_workflow.error}
        />
      </section>
    </div>
    """
  end

  attr :step, :any, required: true

  # Compact step chip for the mini-flow strip in the child tab. Status-tinted
  # box (no icon) with the step name beneath — single-line, clamped.
  defp mini_chip(assigns) do
    tone = mini_tone(to_string(assigns.step.status))
    assigns = assign(assigns, tone: tone)

    ~H"""
    <div class="flex flex-col items-center gap-1 min-w-0">
      <div class={[
        "flex items-center gap-1.5 rounded border px-2 py-1",
        @tone.border,
        @tone.bg
      ]}>
        <span class={["size-1.5 rounded-full", @tone.dot]} />
        <span class="font-mono text-[10px] text-foreground truncate max-w-[90px]">
          {@step.step_name}
        </span>
      </div>
      <span class="font-mono text-[9px] uppercase tracking-wider text-muted-foreground">
        {@step.status}
      </span>
    </div>
    """
  end

  defp mini_tone("completed"),
    do: %{border: "border-success/40", bg: "bg-success/5", dot: "bg-success"}

  defp mini_tone("failed"),
    do: %{border: "border-destructive/50", bg: "bg-destructive/5", dot: "bg-destructive"}

  defp mini_tone("running"),
    do: %{border: "border-primary/50", bg: "bg-primary/5", dot: "bg-primary"}

  defp mini_tone("waiting"),
    do: %{border: "border-warning/50", bg: "bg-warning/5", dot: "bg-warning"}

  defp mini_tone(_),
    do: %{border: "border-border", bg: "bg-background/50", dot: "bg-muted-foreground/50"}

  defp short_module(nil), do: ""
  defp short_module(mod), do: mod |> to_string() |> String.split(".") |> List.last()

  attr :step, :any, required: true

  defp error_tab(assigns) do
    ~H"""
    <div class="space-y-4 p-6">
      <div :if={Map.get(@step.error || %{}, "type") || Map.get(@step.error || %{}, :type)}>
        <p class="font-mono text-[10px] uppercase tracking-[0.18em] text-muted-foreground">
          Type
        </p>
        <p class="mt-1 font-mono text-xs text-destructive">
          {error_field(@step.error, "type")}
        </p>
      </div>
      <div :if={Map.get(@step.error || %{}, "message") || Map.get(@step.error || %{}, :message)}>
        <p class="font-mono text-[10px] uppercase tracking-[0.18em] text-muted-foreground">
          Message
        </p>
        <p class="mt-1 text-[13px] text-destructive/90">
          {error_field(@step.error, "message")}
        </p>
      </div>
      <div class="border border-destructive/40">
        <div class="border-b border-destructive/30 bg-destructive/5 px-3 py-1.5 font-mono text-[10px] uppercase tracking-[0.18em] text-destructive">
          Full trace
        </div>
        <pre class="thin-scroll max-h-[40vh] overflow-auto bg-destructive/5 p-3 font-mono text-[11px] text-destructive/80">{format_json(@step.error)}</pre>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp display_name(nil, step_name), do: step_name
  defp display_name(step, _), do: step.step_name

  defp default_tab(_step, child) when not is_nil(child), do: "child"
  defp default_tab(%{error: error}, _) when not is_nil(error), do: "error"
  defp default_tab(_, _), do: "info"

  defp find_step(steps, name) do
    Enum.find(steps, fn step -> step.step_name == name end) ||
      Enum.find(steps, fn step ->
        case String.split(step.step_name, "__") do
          [_, _, original] -> original == name
          [_, original] -> original == name
          _ -> false
        end
      end)
  end

  defp refresh_selected_step(socket) do
    case socket.assigns do
      %{sheet_open?: true, selected_step_name: name} when not is_nil(name) ->
        case find_step(socket.assigns[:steps] || [], name) do
          nil -> socket
          step -> assign(socket, selected_step: step)
        end

      _ ->
        socket
    end
  end

  defp error_field(error, key) when is_map(error) do
    error
    |> Map.get(key)
    |> Kernel.||(Map.get(error, String.to_atom(key)))
    |> to_string()
  rescue
    _ -> ""
  end

  defp error_field(_, _), do: ""

  defp format_duration(ms) when is_integer(ms) and ms < 1000, do: "#{ms}ms"

  defp format_duration(ms) when is_integer(ms) and ms < 60_000,
    do: "#{Float.round(ms / 1000, 2)}s"

  defp format_duration(ms) when is_integer(ms),
    do: "#{div(ms, 60_000)}m #{div(rem(ms, 60_000), 1000)}s"

  defp format_duration(_), do: "—"

  defp format_timestamp(nil), do: "—"

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %H:%M:%S")
  end

  defp format_timestamp(other) when is_binary(other), do: other
  defp format_timestamp(_), do: "—"

  defp format_json(nil), do: "null"

  defp format_json(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(value, pretty: true)
    end
  end

  # ============================================================================
  # Graph construction
  # ============================================================================

  defp build_graph(%{kind: :flow, workflow: workflow, steps: steps} = assigns) do
    case definition_for(workflow) do
      {:ok, definition} ->
        opts = [
          current_workflow_id: workflow.id,
          parallel_children_lookup: parallel_children_lookup(assigns[:family])
        ]

        definition
        |> GraphBuilder.build()
        |> GraphBuilder.overlay_status(steps, opts)
        |> normalize()

      :error ->
        %{nodes: [], edges: []}
    end
  end

  defp build_graph(_), do: %{nodes: [], edges: []}

  # Map step_name → child_workflow_id, sourced from the family root's
  # context. Merges parallel children (`__parallel_children`, written by
  # the executor) with sub-workflow children (`__call_children`, written
  # by `Durable.Orchestration` for `call_workflow` / `start_workflow`).
  # Empty if the family is flat.
  defp parallel_children_lookup(%{root: %{context: ctx}}) when is_map(ctx) do
    parallel = extract_step_to_child(ctx, "__parallel_children")
    call = extract_step_to_child(ctx, "__call_children")
    Map.merge(parallel, call)
  end

  defp parallel_children_lookup(_), do: %{}

  defp extract_step_to_child(ctx, key) do
    case Map.get(ctx, key) do
      m when is_map(m) ->
        m
        |> Enum.map(fn {child_id, meta} ->
          step_name = meta["step_name"] || meta[:step_name]
          if step_name in [nil, ""], do: nil, else: {step_name, child_id}
        end)
        |> Enum.reject(&is_nil/1)
        |> Map.new()

      _ ->
        %{}
    end
  end

  defp definition_for(%{workflow_module: module_str, workflow_name: name}) do
    module = Module.safe_concat([module_str])

    # In dev mode modules are lazy-loaded; `function_exported?/3` returns
    # false for an existing-but-not-yet-loaded module. Load it explicitly
    # so the exports check is meaningful.
    _ = Code.ensure_loaded(module)

    cond do
      function_exported?(module, :__workflow_definition__, 1) ->
        case module.__workflow_definition__(name) do
          {:ok, definition} -> {:ok, definition}
          _ -> :error
        end

      function_exported?(module, :__default_workflow__, 0) ->
        case module.__default_workflow__() do
          {:ok, definition} -> {:ok, definition}
          _ -> :error
        end

      true ->
        :error
    end
  rescue
    _ -> :error
  end

  defp definition_for(_), do: :error

  # ReactFlow-shaped: stringify atoms in node ids, types, and data keys so
  # JSON round-trips cleanly to the JS island.
  defp normalize(%{nodes: nodes, edges: edges}) do
    %{
      nodes: Enum.map(nodes, &normalize_node/1),
      edges: Enum.map(edges, &normalize_edge/1)
    }
  end

  defp normalize_node(node) do
    %{
      id: to_string(node.id),
      type: to_string(node.type),
      data: stringify_data(node.data || %{})
    }
  end

  defp normalize_edge(edge) do
    %{
      id: to_string(edge.id),
      source: to_string(edge.source),
      target: to_string(edge.target),
      animated: Map.get(edge, :animated, false),
      style: Map.get(edge, :style, %{})
    }
  end

  defp stringify_data(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_value(v)}
      {k, v} -> {k, stringify_value(v)}
    end)
  end

  defp stringify_value(v) when is_atom(v) and not is_nil(v) and not is_boolean(v),
    do: Atom.to_string(v)

  defp stringify_value(v), do: v

  defp replace_event(id), do: id <> ":replace"
end
