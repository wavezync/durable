defmodule DurableDashboard.Live.WorkflowLive do
  @moduledoc """
  Workflow detail view. One LiveView, six tabs (summary/flow/topology/logs/io/
  history). Tab routing is `live "/v2/workflows/:id/:tab"` — switching tabs
  re-runs `handle_params` without unmounting, so the loaded workflow + steps
  stay in memory.

  Phase 3 implements summary / I/O / history / logs. Flow + topology stub
  until phase 4 (ReactFlow island).
  """

  use Phoenix.LiveView

  import Ecto.Query

  alias Durable.PubSub, as: DurablePubSub
  alias Durable.Storage.Schemas.{PendingInput, StepExecution, WorkflowExecution}
  alias DurableDashboard.Components.Core
  alias DurableDashboard.Components.Workflow.{FamilyChip, Tabs}
  alias DurableDashboard.Layouts
  alias DurableDashboard.Path, as: DPath

  @workflow_kinds [
    :workflow_started,
    :workflow_resumed,
    :workflow_waiting,
    :workflow_completed,
    :workflow_failed,
    :workflow_cancelled
  ]

  @step_kinds [:step_started, :step_completed, :step_failed, :step_waiting]
  @input_kinds [:input_requested, :input_provided]
  @detail_kinds @workflow_kinds ++ @step_kinds ++ @input_kinds

  @valid_tabs ~w(summary flow logs io history family)a

  @impl true
  def mount(params, session, socket) do
    config = session["config"]
    durable = config.durable
    # `live_isolated/3` passes %Plug.Conn.Unfetched{} for params — guard against
    # that so the LV can be mounted in tests without a router-fed param map.
    id =
      case params do
        %{"id" => id} -> id
        _ -> nil
      end

    if connected?(socket) and id != nil do
      durable_config = Durable.Config.get_safe(durable)

      if durable_config do
        DurablePubSub.subscribe(durable_config, DurablePubSub.workflow_topic(durable_config, id))
      end
    end

    {:ok,
     assign(socket,
       config: config,
       base_path: config.base_path,
       durable: durable,
       workflow_id: id,
       page_title: "Workflow",
       not_found?: false
     )
     |> load_workflow()}
  end

  @impl true
  def handle_params(params, uri, socket) do
    tab =
      case params do
        %{"tab" => tab} -> parse_tab(tab)
        _ -> :summary
      end

    {:noreply,
     assign(socket,
       active_tab: tab,
       current_path: URI.parse(uri).path,
       breadcrumbs: build_breadcrumbs(socket.assigns)
     )}
  end

  defp parse_tab(nil), do: :summary

  defp parse_tab(tab) when is_binary(tab) do
    atom = String.to_existing_atom(tab)
    if atom in @valid_tabs, do: atom, else: :summary
  rescue
    ArgumentError -> :summary
  end

  defp build_breadcrumbs(%{base_path: base, workflow_id: id}) do
    [
      %{label: "Workflows", href: DPath.workflows(base)},
      %{label: short(id)}
    ]
  end

  @impl true
  def handle_info({:durable_event, kind, _payload}, socket) when kind in @detail_kinds do
    {:noreply, load_workflow(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      base_path={@base_path}
      current_path={@current_path}
      breadcrumbs={@breadcrumbs}
    >
      <%= if @not_found? do %>
        <Core.empty_state
          icon="exclamation-triangle"
          title="Workflow not found"
          description={"No execution with id " <> (@workflow_id || "—") <> " on this instance."}
        >
          <:action>
            <Core.button kind="link" navigate={DPath.workflows(@base_path)}>
              Back to workflows
            </Core.button>
          </:action>
        </Core.empty_state>
      <% else %>
        <.detail_header
          workflow={@workflow}
          family={@family}
          base_path={@base_path}
        />

        <Tabs.tabs
          base_path={@base_path}
          workflow_id={@workflow_id}
          active={@active_tab}
          show_family?={family_visible?(@family)}
          class="mt-6"
        />

        <div class="mt-6">
          <.tab_content
            active_tab={@active_tab}
            workflow={@workflow}
            steps={@steps}
            pending_inputs={@pending_inputs}
            base_path={@base_path}
            family={@family}
          />
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  # ============================================================================
  # Header
  # ============================================================================

  attr :workflow, :map, required: true
  attr :family, :map, required: true
  attr :base_path, :string, required: true

  defp detail_header(assigns) do
    assigns = assign(assigns, :parent_step_lookup, parent_step_lookup(assigns.family))

    ~H"""
    <div class="flex items-start justify-between gap-4">
      <div class="flex flex-col gap-1.5 min-w-0">
        <div class="flex items-center gap-3 flex-wrap">
          <Core.heading level={1}>{@workflow.workflow_name}</Core.heading>
          <Core.status_pill status={@workflow.status} />
          <FamilyChip.family_chip
            family={@family}
            workflow={@workflow}
            base_path={@base_path}
            parent_step_lookup={@parent_step_lookup}
          />
        </div>
        <div class="flex items-center gap-3 text-xs text-muted-foreground">
          <span class="font-mono">{strip_elixir(@workflow.workflow_module)}</span>
          <span class="text-border">·</span>
          <Core.code>{@workflow.id}</Core.code>
        </div>
      </div>
    </div>
    """
  end

  # Build a `child_workflow_id => step_name` map by reading the parent's
  # `__parallel_children` context. The parent's perspective is most
  # accurate; when viewing a child we still see its own context, so fall
  # back to walking siblings if necessary.
  defp parent_step_lookup(%{root: nil}), do: %{}

  defp parent_step_lookup(%{root: root}) when is_map(root) do
    case get_in(root.context || %{}, ["__parallel_children"]) do
      m when is_map(m) ->
        Map.new(m, fn {child_id, meta} ->
          {child_id, meta["step_name"] || meta[:step_name]}
        end)

      _ ->
        %{}
    end
  end

  defp parent_step_lookup(_), do: %{}

  defp family_visible?(%{parent: parent, all_descendants: descs}) do
    !is_nil(parent) or (is_list(descs) and descs != [])
  end

  defp family_visible?(%{parent: parent, children: children}) do
    !is_nil(parent) or (is_list(children) and children != [])
  end

  defp family_visible?(_), do: false

  # ============================================================================
  # Tab dispatch
  # ============================================================================

  alias DurableDashboard.Components.Workflow.{ChildrenTab, HistoryTab, IoTab, SummaryTab}

  attr :active_tab, :atom, required: true
  attr :workflow, :map, required: true
  attr :steps, :list, required: true
  attr :pending_inputs, :list, required: true
  attr :base_path, :string, required: true
  attr :family, :map, required: true

  defp tab_content(%{active_tab: :summary} = assigns) do
    ~H"""
    <SummaryTab.summary_tab
      workflow={@workflow}
      steps={@steps}
      pending_inputs={@pending_inputs}
    />
    """
  end

  defp tab_content(%{active_tab: :io} = assigns) do
    ~H"""
    <IoTab.io_tab workflow={@workflow} />
    """
  end

  defp tab_content(%{active_tab: :history} = assigns) do
    ~H"""
    <HistoryTab.history_tab steps={@steps} />
    """
  end

  defp tab_content(%{active_tab: :logs} = assigns) do
    ~H"""
    <.live_component
      module={DurableDashboard.Components.Workflow.LogsTab}
      id={"logs-" <> @workflow.id}
      steps={@steps}
    />
    """
  end

  defp tab_content(%{active_tab: :flow} = assigns) do
    ~H"""
    <.live_component
      module={DurableDashboard.Components.Workflow.FlowGraph}
      id={"flow-" <> @workflow.id}
      kind={:flow}
      workflow={@workflow}
      steps={@steps}
      family={@family}
      base_path={@base_path}
    />
    """
  end

  defp tab_content(%{active_tab: :family} = assigns) do
    ~H"""
    <ChildrenTab.children_tab
      workflow={@workflow}
      family={@family}
      base_path={@base_path}
    />
    """
  end

  # ============================================================================
  # Data loading
  # ============================================================================

  defp load_workflow(%{assigns: %{workflow_id: nil}} = socket) do
    assign(socket, not_found?: true, workflow: nil, steps: [], pending_inputs: [])
  end

  defp load_workflow(socket) do
    config = Durable.Config.get_safe(socket.assigns.durable)

    if config do
      do_load(socket, config)
    else
      assign(socket, not_found?: true, workflow: nil, steps: [], pending_inputs: [])
    end
  end

  defp do_load(socket, config) do
    case Durable.Repo.get(config, WorkflowExecution, socket.assigns.workflow_id) do
      nil ->
        assign(socket,
          not_found?: true,
          workflow: nil,
          steps: [],
          pending_inputs: [],
          family: %{root: nil, parent: nil, children: [], related_ids: []}
        )

      execution ->
        family = load_family(config, execution)
        steps = fetch_steps(config, family.related_ids)
        pending = fetch_pending_inputs(config, execution.id)

        assign(socket,
          not_found?: false,
          workflow: execution,
          steps: steps,
          pending_inputs: pending,
          family: family
        )
    end
  rescue
    _ ->
      assign(socket,
        not_found?: true,
        workflow: nil,
        steps: [],
        pending_inputs: [],
        family: %{root: nil, parent: nil, children: [], related_ids: []}
      )
  end

  # Walk up to the root parent (single hop is the common case but we
  # follow the chain in case nested parallels are ever introduced),
  # then collect every descendant. The graph's overlay_status indexes
  # by step_name — a top-level step ran on the root, each parallel
  # child ran on its own execution; merging them gives the FlowGraph
  # LC enough data to paint the entire family's progress on a single
  # screen regardless of which one's URL is open.
  defp load_family(config, %WorkflowExecution{} = exec) do
    root = walk_to_root(config, exec)
    descendants = fetch_descendants(config, root.id)

    parent =
      cond do
        exec.id == root.id -> nil
        exec.parent_workflow_id == root.id -> root
        true -> Enum.find(descendants, &(&1.id == exec.parent_workflow_id))
      end

    related_ids = [root.id | Enum.map(descendants, & &1.id)] |> Enum.uniq()

    %{
      root: root,
      parent: parent,
      children: Enum.filter(descendants, &(&1.parent_workflow_id == exec.id)),
      siblings: collect_siblings(descendants, exec),
      all_descendants: descendants,
      related_ids: related_ids
    }
  end

  defp walk_to_root(_config, %WorkflowExecution{parent_workflow_id: nil} = exec), do: exec

  defp walk_to_root(config, %WorkflowExecution{parent_workflow_id: pid} = exec) do
    case Durable.Repo.get(config, WorkflowExecution, pid) do
      nil -> exec
      parent -> walk_to_root(config, parent)
    end
  end

  defp fetch_descendants(config, root_id) do
    Durable.Repo.all(
      config,
      from(w in WorkflowExecution,
        where: w.parent_workflow_id == ^root_id,
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

  defp fetch_steps(_config, []), do: []

  defp fetch_steps(config, workflow_ids) when is_list(workflow_ids) do
    Durable.Repo.all(
      config,
      from(s in StepExecution,
        where: s.workflow_id in ^workflow_ids,
        order_by: [asc: s.inserted_at]
      )
    )
  end

  defp fetch_steps(config, workflow_id) when is_binary(workflow_id),
    do: fetch_steps(config, [workflow_id])

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
  # Misc
  # ============================================================================

  defp short(nil), do: "—"
  defp short(id) when is_binary(id), do: String.slice(id, 0, 8)

  defp strip_elixir(nil), do: ""
  defp strip_elixir(s) when is_binary(s), do: String.replace_prefix(s, "Elixir.", "")
end
