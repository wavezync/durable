defmodule PhoenixDemoWeb.ExecutionsLive do
  @moduledoc """
  Lists workflow executions with URL-driven filters. Replaces the older
  WorkflowLive dashboard.
  """
  use PhoenixDemoWeb, :live_view

  alias Durable.Config
  alias Durable.Storage.Schemas.WorkflowExecution

  import Ecto.Query

  @statuses ~w(all pending running waiting completed failed cancelled)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PhoenixDemo.PubSub, "workflows")
      :timer.send_interval(2_000, self(), :refresh)
    end

    {:ok,
     assign(socket,
       page_title: "Executions",
       active_nav: :executions,
       status: "all",
       module: nil,
       workflows: []
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    status = if params["status"] in @statuses, do: params["status"], else: "all"
    module = params["workflow"]

    socket =
      socket
      |> assign(status: status, module: module)
      |> assign(workflows: list_workflows(status, module))
      |> assign(modules: list_modules())

    {:noreply, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, workflows: list_workflows(socket.assigns.status, socket.assigns.module), modules: list_modules())}
  end

  def handle_info({event, _, _}, socket) when event in [:workflow_completed, :workflow_rejected] do
    {:noreply, assign(socket, workflows: list_workflows(socket.assigns.status, socket.assigns.module))}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp list_workflows(status, module) do
    config = Config.get(Durable)
    repo = config.repo

    query =
      from(w in WorkflowExecution,
        order_by: [desc: w.inserted_at],
        limit: 100
      )

    query =
      case status do
        "all" -> query
        s -> from(w in query, where: w.status == ^String.to_atom(s))
      end

    query =
      case module do
        nil -> query
        "" -> query
        m -> from(w in query, where: w.workflow_module == ^m)
      end

    repo.all(query)
  end

  defp list_modules do
    config = Config.get(Durable)
    repo = config.repo

    repo.all(
      from(w in WorkflowExecution,
        select: w.workflow_module,
        distinct: true,
        order_by: w.workflow_module
      )
    )
    |> Enum.reject(&is_nil/1)
  end

  defp status_badge(status) do
    case status do
      :pending -> "badge badge-warning"
      :running -> "badge badge-info"
      :waiting -> "badge badge-secondary"
      :completed -> "badge badge-success"
      :failed -> "badge badge-error"
      :cancelled -> "badge badge-ghost"
      _ -> "badge"
    end
  end

  defp short_module(nil), do: "-"
  defp short_module(mod), do: mod |> String.split(".") |> List.last()

  defp format_time(nil), do: "-"
  defp format_time(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav={@active_nav}>
      <div class="flex items-center justify-between mb-4">
        <div>
          <h1 class="text-2xl font-bold">Executions</h1>
          <p class="text-sm text-base-content/70">All workflow runs across the demo.</p>
        </div>
        <.link navigate={~p"/"} class="btn btn-sm btn-ghost">
          <.icon name="hero-plus" class="size-4" /> Run a workflow
        </.link>
      </div>

      <div class="flex flex-wrap items-center gap-2 mb-4">
        <div role="tablist" class="tabs tabs-bordered">
          <.link
            :for={s <- ~w(all pending running waiting completed failed cancelled)}
            patch={status_path(s, @module)}
            role="tab"
            class={["tab", @status == s && "tab-active"]}
          >
            {s}
          </.link>
        </div>

        <div class="ml-auto flex items-center gap-2">
          <form phx-change="filter_module">
            <select name="module" class="select select-bordered select-sm">
              <option value="" selected={@module == nil}>All workflows</option>
              <option :for={m <- @modules} value={m} selected={m == @module}>
                {short_module(m)}
              </option>
            </select>
          </form>
        </div>
      </div>

      <div class="overflow-x-auto bg-base-100 border border-base-300 rounded-md">
        <table class="table table-sm">
          <thead>
            <tr class="text-xs uppercase tracking-wide text-base-content/60">
              <th>ID</th>
              <th>Workflow</th>
              <th>Status</th>
              <th>Step</th>
              <th>Created</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={w <- @workflows} class="hover">
              <td class="font-mono text-xs">{String.slice(w.id, 0, 8)}</td>
              <td class="text-sm">
                <div class="font-semibold">{w.workflow_name}</div>
                <div class="text-xs text-base-content/50 font-mono">{short_module(w.workflow_module)}</div>
              </td>
              <td><span class={status_badge(w.status)}>{w.status}</span></td>
              <td class="text-sm">{w.current_step || "-"}</td>
              <td class="text-xs">{format_time(w.inserted_at)}</td>
              <td>
                <.link navigate={~p"/executions/#{w.id}"} class="btn btn-xs btn-ghost">
                  View
                </.link>
              </td>
            </tr>
            <tr :if={@workflows == []}>
              <td colspan="6" class="text-center py-8 text-base-content/60">
                No executions match these filters.
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("filter_module", %{"module" => mod}, socket) do
    {:noreply, push_patch(socket, to: status_path(socket.assigns.status, blank_to_nil(mod)))}
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp status_path(status, module) do
    params =
      [{"status", status}, {"workflow", module}]
      |> Enum.reject(fn {_k, v} -> v in [nil, "", "all"] end)

    case params do
      [] -> ~p"/executions"
      _ -> ~p"/executions?#{params}"
    end
  end
end
