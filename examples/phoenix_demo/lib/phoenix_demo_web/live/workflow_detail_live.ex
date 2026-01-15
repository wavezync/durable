defmodule PhoenixDemoWeb.WorkflowDetailLive do
  @moduledoc """
  LiveView for viewing detailed workflow execution information.
  Shows the workflow status, context, and step execution history.
  """

  use PhoenixDemoWeb, :live_view

  alias Durable.Config
  alias Durable.Storage.Schemas.{StepExecution, WorkflowExecution}

  import Ecto.Query

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PhoenixDemo.PubSub, "workflows")
      :timer.send_interval(2000, self(), :refresh)
    end

    case get_workflow(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Workflow not found")
         |> redirect(to: ~p"/workflows")}

      workflow ->
        {:ok,
         assign(socket,
           page_title: "Workflow Details",
           workflow: workflow,
           steps: get_steps(id)
         )}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    workflow = get_workflow(socket.assigns.workflow.id)
    steps = get_steps(socket.assigns.workflow.id)
    {:noreply, assign(socket, workflow: workflow, steps: steps)}
  end

  def handle_info({:workflow_completed, id, _report}, socket) do
    if id == socket.assigns.workflow.id do
      {:noreply, assign(socket, workflow: get_workflow(id), steps: get_steps(id))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:workflow_rejected, id, _result}, socket) do
    if id == socket.assigns.workflow.id do
      {:noreply, assign(socket, workflow: get_workflow(id), steps: get_steps(id))}
    else
      {:noreply, socket}
    end
  end

  defp get_workflow(id) do
    config = Config.get(Durable)
    repo = config.repo
    repo.get(WorkflowExecution, id)
  end

  defp get_steps(workflow_id) do
    config = Config.get(Durable)
    repo = config.repo

    repo.all(
      from(s in StepExecution,
        where: s.workflow_id == ^workflow_id,
        order_by: [asc: s.inserted_at]
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
      :skipped -> "badge badge-ghost"
      _ -> "badge"
    end
  end

  defp step_icon(status) do
    case status do
      :completed -> "hero-check-circle"
      :failed -> "hero-x-circle"
      :running -> "hero-arrow-path"
      :pending -> "hero-clock"
      :skipped -> "hero-minus-circle"
      _ -> "hero-question-mark-circle"
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
      Workflow Details
      <:subtitle>
        <code class="font-mono text-xs">{@workflow.id}</code>
      </:subtitle>
      <:actions>
        <.button navigate={~p"/workflows"}>
          <.icon name="hero-arrow-left" class="size-4 mr-1" /> Back to Dashboard
        </.button>
      </:actions>
    </.header>

    <div class="mt-6 space-y-6">
      <!-- Status Card -->
      <div class="card bg-base-200 shadow-lg">
        <div class="card-body">
          <div class="flex justify-between items-center">
            <h2 class="card-title">Status</h2>
            <span class={status_badge(@workflow.status)}>
              {@workflow.status}
            </span>
          </div>

          <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mt-4">
            <div>
              <div class="text-sm text-base-content/60">Workflow</div>
              <div class="font-semibold">{@workflow.workflow_name}</div>
            </div>
            <div>
              <div class="text-sm text-base-content/60">Current Step</div>
              <div class="font-semibold">{@workflow.current_step || "-"}</div>
            </div>
            <div>
              <div class="text-sm text-base-content/60">Queue</div>
              <div class="font-semibold">{@workflow.queue}</div>
            </div>
            <div>
              <div class="text-sm text-base-content/60">Priority</div>
              <div class="font-semibold">{@workflow.priority}</div>
            </div>
          </div>

          <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mt-4">
            <div>
              <div class="text-sm text-base-content/60">Created</div>
              <div class="text-sm">{format_time(@workflow.inserted_at)}</div>
            </div>
            <div>
              <div class="text-sm text-base-content/60">Started</div>
              <div class="text-sm">{format_time(@workflow.started_at)}</div>
            </div>
            <div>
              <div class="text-sm text-base-content/60">Completed</div>
              <div class="text-sm">{format_time(@workflow.completed_at)}</div>
            </div>
            <div :if={@workflow.scheduled_at}>
              <div class="text-sm text-base-content/60">Scheduled</div>
              <div class="text-sm">{format_time(@workflow.scheduled_at)}</div>
            </div>
          </div>

          <div :if={@workflow.status == :waiting} class="mt-4">
            <.link navigate={~p"/approvals"} class="btn btn-primary btn-sm">
              <.icon name="hero-hand-raised" class="size-4 mr-1" /> Go to Approvals
            </.link>
          </div>
        </div>
      </div>
      
    <!-- Input -->
      <div class="card bg-base-200 shadow-lg">
        <div class="card-body">
          <h2 class="card-title">Input</h2>
          <pre class="text-xs overflow-auto max-h-48 bg-base-300 p-4 rounded-lg"><code>{Jason.encode!(@workflow.input || %{}, pretty: true)}</code></pre>
        </div>
      </div>
      
    <!-- Context -->
      <div class="card bg-base-200 shadow-lg">
        <div class="card-body">
          <h2 class="card-title">Context</h2>
          <pre class="text-xs overflow-auto max-h-64 bg-base-300 p-4 rounded-lg"><code>{Jason.encode!(@workflow.context || %{}, pretty: true)}</code></pre>
        </div>
      </div>
      
    <!-- Error (if any) -->
      <div :if={@workflow.error} class="card bg-error/10 shadow-lg">
        <div class="card-body">
          <h2 class="card-title text-error">
            <.icon name="hero-exclamation-triangle" class="size-5" /> Error
          </h2>
          <pre class="text-xs overflow-auto max-h-48 bg-base-300 p-4 rounded-lg text-error"><code>{Jason.encode!(@workflow.error, pretty: true)}</code></pre>
        </div>
      </div>
      
    <!-- Step Executions -->
      <div class="card bg-base-200 shadow-lg">
        <div class="card-body">
          <h2 class="card-title">Step History</h2>

          <div :if={@steps == []} class="text-center py-8 text-base-content/60">
            No steps executed yet
          </div>

          <ul :if={@steps != []} class="timeline timeline-vertical">
            <li :for={{step, idx} <- Enum.with_index(@steps)}>
              <hr :if={idx > 0} class={step.status == :completed && "bg-success"} />
              <div class="timeline-start text-xs text-base-content/60">
                {format_time(step.started_at)}
              </div>
              <div class="timeline-middle">
                <.icon
                  name={step_icon(step.status)}
                  class={[
                    "size-5",
                    step.status == :completed && "text-success",
                    step.status == :failed && "text-error",
                    step.status == :running && "text-info animate-spin"
                  ]}
                />
              </div>
              <div class="timeline-end timeline-box">
                <div class="flex justify-between items-center">
                  <span class="font-semibold">{step.step_name}</span>
                  <span class={["badge badge-sm ml-2", status_badge(step.status)]}>
                    {step.status}
                  </span>
                </div>
                <div class="text-xs text-base-content/60 mt-1">
                  Type: {step.step_type} | Attempt: {step.attempt}
                  <span :if={step.duration_ms}> | Duration:  {step.duration_ms}ms</span>
                </div>
                <details :if={step.output} class="mt-2">
                  <summary class="text-xs cursor-pointer text-primary">View Output</summary>
                  <pre class="text-xs mt-1 overflow-auto max-h-32 bg-base-300 p-2 rounded"><code>{Jason.encode!(step.output, pretty: true)}</code></pre>
                </details>
                <details :if={step.error} class="mt-2">
                  <summary class="text-xs cursor-pointer text-error">View Error</summary>
                  <pre class="text-xs mt-1 overflow-auto max-h-32 bg-base-300 p-2 rounded text-error"><code>{Jason.encode!(step.error, pretty: true)}</code></pre>
                </details>
              </div>
              <hr :if={idx < length(@steps) - 1} class={step.status == :completed && "bg-success"} />
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end
end
