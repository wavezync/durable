defmodule DurableDashboard.Live.InputsLive do
  @moduledoc """
  Pending inputs queue. Shows workflows waiting on human input
  (`wait_for_input`, `wait_for_approval`, etc) so an operator can resolve them.
  """

  use Phoenix.LiveView

  import Ecto.Query

  alias Durable.PubSub, as: DurablePubSub
  alias Durable.Storage.Schemas.PendingInput
  alias DurableDashboard.Components.Core
  alias DurableDashboard.Components.Data.DataTable
  alias DurableDashboard.Layouts
  alias DurableDashboard.Path, as: DPath

  @table_id "inputs-table"

  @input_kinds [:input_requested, :input_provided]

  @impl true
  def mount(_params, session, socket) do
    config = session["config"]
    durable = config.durable

    if connected?(socket) do
      durable_config = Durable.Config.get_safe(durable)

      if durable_config do
        DurablePubSub.subscribe(durable_config, DurablePubSub.inputs_topic(durable_config))
      end
    end

    {:ok,
     assign(socket,
       config: config,
       base_path: config.base_path,
       durable: durable,
       page_title: "Pending inputs",
       table_id: @table_id
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {:noreply,
     assign(socket,
       current_path: URI.parse(uri).path,
       breadcrumbs: [%{label: "Pending inputs"}],
       query: %{
         page: parse_int(params["page"], 1),
         search: nil,
         sort_by: nil,
         sort_dir: :asc
       }
     )}
  end

  @impl true
  def handle_info({:durable_event, kind, _payload}, socket) when kind in @input_kinds do
    Phoenix.LiveView.send_update(DataTable, id: @table_id, refresh: true)
    {:noreply, socket}
  end

  def handle_info({:data_table, @table_id, :query_changed, new_query}, socket) do
    base = DPath.inputs(socket.assigns.base_path)

    qs =
      if new_query[:page] && new_query[:page] > 1,
        do: "?" <> URI.encode_query(%{"page" => new_query[:page]}),
        else: ""

    {:noreply, push_patch(socket, to: base <> qs)}
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
      <Core.heading level={1} subtitle="Workflows waiting on human input">
        Pending inputs
      </Core.heading>

      <div class="mt-6">
        <.live_component
          module={DataTable}
          id={@table_id}
          fetcher={fetch_inputs(@durable)}
          columns={columns(@base_path)}
          query={@query}
          row_navigate={fn row -> DPath.workflow(@base_path, row.workflow_id) end}
          empty_title="No pending inputs"
          empty_description="Workflows that call wait_for_input/2 will appear here while they wait."
          empty_icon="inbox"
        />
      </div>
    </Layouts.app>
    """
  end

  # ============================================================================
  # Columns
  # ============================================================================

  defp columns(_base_path) do
    [
      %{
        key: :input_type,
        label: "Type",
        class: "w-[100px]",
        render: &render_type/1
      },
      %{
        key: :input_name,
        label: "Input",
        render: &render_input/1
      },
      %{
        key: :workflow,
        label: "Workflow",
        class: "w-[280px]",
        render: &render_workflow/1
      },
      %{
        key: :prompt,
        label: "Prompt",
        class: "text-muted-foreground",
        render: &render_prompt/1
      },
      %{
        key: :inserted_at,
        label: "Waiting",
        class: "w-[120px] text-right",
        render: &render_age/1
      }
    ]
  end

  defp render_type(p) do
    assigns = %{type: p.input_type}

    ~H"""
    <Core.badge kind="info">{@type}</Core.badge>
    """
  end

  defp render_input(p) do
    assigns = %{name: p.input_name, step: p.step_name}

    ~H"""
    <div class="flex flex-col leading-tight">
      <span class="font-medium text-foreground">{@name}</span>
      <span class="text-[11px] text-muted-foreground">step: {@step}</span>
    </div>
    """
  end

  defp render_workflow(p) do
    workflow = if Ecto.assoc_loaded?(p.workflow), do: p.workflow, else: nil

    assigns = %{
      wf_name: workflow && workflow.workflow_name,
      wf_id: p.workflow_id
    }

    ~H"""
    <div class="flex flex-col leading-tight">
      <span :if={@wf_name} class="text-xs">{@wf_name}</span>
      <Core.code>{short(@wf_id)}</Core.code>
    </div>
    """
  end

  defp render_prompt(p) do
    assigns = %{prompt: p.prompt}

    ~H"""
    <span class="line-clamp-1">{@prompt || "—"}</span>
    """
  end

  defp render_age(p) do
    assigns = %{at: p.inserted_at}

    ~H"""
    <Core.relative_time at={@at} />
    """
  end

  # ============================================================================
  # Fetcher
  # ============================================================================

  defp fetch_inputs(durable) do
    fn query ->
      page = query[:page] || 1
      per_page = query[:per_page] || 20
      offset = (page - 1) * per_page

      config = Durable.Config.get_safe(durable)

      if config do
        list_query =
          from(p in PendingInput,
            where: p.status == :pending,
            order_by: [asc: p.inserted_at],
            limit: ^per_page,
            offset: ^offset,
            preload: [:workflow]
          )

        total_query =
          from(p in PendingInput, where: p.status == :pending, select: count(p.id))

        rows = Durable.Repo.all(config, list_query)
        total = Durable.Repo.one(config, total_query) || 0
        {rows, total}
      else
        {[], 0}
      end
    end
  end

  # ============================================================================
  # Misc
  # ============================================================================

  defp parse_int(nil, default), do: default

  defp parse_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(v, _) when is_integer(v), do: v
  defp parse_int(_, default), do: default

  defp short(nil), do: "—"
  defp short(id) when is_binary(id), do: String.slice(id, 0, 8)
end
