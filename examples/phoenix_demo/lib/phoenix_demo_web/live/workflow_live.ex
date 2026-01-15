defmodule PhoenixDemoWeb.WorkflowLive do
  @moduledoc """
  LiveView dashboard for monitoring workflow executions.
  Shows all workflows with real-time status updates via PubSub.
  """

  use PhoenixDemoWeb, :live_view

  alias Durable.Config
  alias Durable.Storage.Schemas.WorkflowExecution

  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PhoenixDemo.PubSub, "workflows")
      # Poll for updates every 2 seconds
      :timer.send_interval(2000, self(), :refresh)
    end

    {:ok, assign(socket, page_title: "Workflow Dashboard", workflows: list_workflows())}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, workflows: list_workflows())}
  end

  def handle_info({:workflow_completed, _id, _report}, socket) do
    {:noreply, assign(socket, workflows: list_workflows())}
  end

  def handle_info({:workflow_rejected, _id, _result}, socket) do
    {:noreply, assign(socket, workflows: list_workflows())}
  end

  defp list_workflows do
    config = Config.get(Durable)
    repo = config.repo

    repo.all(
      from(w in WorkflowExecution,
        order_by: [desc: w.inserted_at],
        limit: 50
      )
    )
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

  defp format_time(nil), do: "-"

  defp format_time(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Workflow Dashboard
      <:subtitle>Monitor and manage workflow executions</:subtitle>
      <:actions>
        <.button navigate={~p"/workflows/new"} variant="primary">
          <.icon name="hero-plus" class="size-4 mr-1" /> New Workflow
        </.button>
      </:actions>
    </.header>

    <div class="mt-6">
      <div class="stats shadow mb-6 w-full">
        <div class="stat">
          <div class="stat-title">Total</div>
          <div class="stat-value text-primary">{length(@workflows)}</div>
        </div>
        <div class="stat">
          <div class="stat-title">Running</div>
          <div class="stat-value text-info">{Enum.count(@workflows, &(&1.status == :running))}</div>
        </div>
        <div class="stat">
          <div class="stat-title">Waiting</div>
          <div class="stat-value text-warning">
            {Enum.count(@workflows, &(&1.status == :waiting))}
          </div>
        </div>
        <div class="stat">
          <div class="stat-title">Completed</div>
          <div class="stat-value text-success">
            {Enum.count(@workflows, &(&1.status == :completed))}
          </div>
        </div>
      </div>

      <div class="overflow-x-auto">
        <table class="table table-zebra">
          <thead>
            <tr>
              <th>ID</th>
              <th>Workflow</th>
              <th>Status</th>
              <th>Current Step</th>
              <th>Created</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={workflow <- @workflows} class="hover">
              <td class="font-mono text-xs">
                {String.slice(workflow.id, 0, 8)}...
              </td>
              <td>{workflow.workflow_name}</td>
              <td>
                <span class={status_badge(workflow.status)}>
                  {workflow.status}
                </span>
              </td>
              <td>{workflow.current_step || "-"}</td>
              <td class="text-sm">{format_time(workflow.inserted_at)}</td>
              <td>
                <.link navigate={~p"/workflows/#{workflow.id}"} class="btn btn-ghost btn-xs">
                  View
                </.link>
                <.link
                  :if={workflow.status == :waiting}
                  navigate={~p"/approvals"}
                  class="btn btn-primary btn-xs"
                >
                  Review
                </.link>
              </td>
            </tr>
            <tr :if={@workflows == []}>
              <td colspan="6" class="text-center py-8 text-base-content/60">
                No workflows yet. Create one to get started!
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
