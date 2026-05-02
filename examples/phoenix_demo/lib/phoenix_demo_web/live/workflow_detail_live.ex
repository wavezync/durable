defmodule PhoenixDemoWeb.WorkflowDetailLive do
  @moduledoc """
  Detailed view for a single workflow execution: status header, input,
  context, error, child workflows, and step timeline.
  """

  use PhoenixDemoWeb, :live_view

  alias Durable.Config
  alias Durable.Storage.Schemas.{StepExecution, WorkflowExecution}

  import Ecto.Query

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PhoenixDemo.PubSub, "workflows")
      :timer.send_interval(2_000, self(), :refresh)
    end

    case get_workflow(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Workflow not found")
         |> redirect(to: ~p"/executions")}

      workflow ->
        {:ok,
         assign(socket,
           page_title: "Workflow Details",
           active_nav: :executions,
           workflow: workflow,
           steps: get_steps(id),
           children: Durable.list_children(id)
         )}
    end
  end

  @impl true
  def handle_info(:refresh, socket), do: refresh(socket)
  def handle_info({:workflow_completed, _, _}, socket), do: refresh(socket)
  def handle_info({:workflow_rejected, _, _}, socket), do: refresh(socket)
  def handle_info(_, socket), do: {:noreply, socket}

  defp refresh(socket) do
    id = socket.assigns.workflow.id
    workflow = get_workflow(id)
    steps = get_steps(id)
    children = Durable.list_children(id)

    {:noreply, assign(socket, workflow: workflow, steps: steps, children: children)}
  end

  @impl true
  def handle_event("cancel_workflow", _params, socket) do
    case Durable.cancel(socket.assigns.workflow.id, "Cancelled from UI") do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Workflow cancelled (parent only — children continue).")
         |> assign(workflow: get_workflow(socket.assigns.workflow.id))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cancel failed: #{inspect(reason)}")}
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

  defp short_module(nil), do: "-"
  defp short_module(mod), do: mod |> to_string() |> String.split(".") |> List.last()

  defp format_time(nil), do: "-"
  defp format_time(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav={@active_nav}>
      <div class="flex justify-between items-start mb-4">
        <div>
          <h1 class="text-2xl font-bold">{@workflow.workflow_name}</h1>
          <code class="text-xs text-base-content/60 font-mono">{@workflow.id}</code>
        </div>
        <div class="flex gap-2">
          <.link navigate={~p"/executions"} class="btn btn-sm btn-ghost">
            <.icon name="hero-arrow-left" class="size-4" /> Executions
          </.link>
          <button
            :if={@workflow.status in [:running, :waiting, :pending]}
            phx-click="cancel_workflow"
            data-confirm="Cancel this workflow? Children will continue running."
            class="btn btn-sm btn-ghost text-error"
          >
            <.icon name="hero-x-circle" class="size-4" /> Cancel
          </button>
        </div>
      </div>

      <div class="space-y-4">
        <div class="card bg-base-100 border border-base-300">
          <div class="card-body p-4">
            <div class="flex justify-between items-center">
              <h2 class="card-title text-base">Status</h2>
              <span class={status_badge(@workflow.status)}>{@workflow.status}</span>
            </div>

            <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mt-3 text-sm">
              <div>
                <div class="text-xs text-base-content/60">Module</div>
                <div class="font-mono">{short_module(@workflow.workflow_module)}</div>
              </div>
              <div>
                <div class="text-xs text-base-content/60">Current step</div>
                <div>{@workflow.current_step || "-"}</div>
              </div>
              <div>
                <div class="text-xs text-base-content/60">Queue</div>
                <div>{@workflow.queue}</div>
              </div>
              <div>
                <div class="text-xs text-base-content/60">Priority</div>
                <div>{@workflow.priority}</div>
              </div>
            </div>

            <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mt-3 text-xs">
              <div><span class="text-base-content/60">Created:</span> {format_time(@workflow.inserted_at)}</div>
              <div><span class="text-base-content/60">Started:</span> {format_time(@workflow.started_at)}</div>
              <div><span class="text-base-content/60">Completed:</span> {format_time(@workflow.completed_at)}</div>
              <div :if={@workflow.scheduled_at}><span class="text-base-content/60">Scheduled:</span> {format_time(@workflow.scheduled_at)}</div>
            </div>
          </div>
        </div>

        <div :if={@children != []} class="card bg-base-100 border border-base-300">
          <div class="card-body p-4">
            <h2 class="card-title text-base">Child workflows</h2>
            <ul class="text-sm space-y-1">
              <li :for={c <- @children} class="flex items-center justify-between gap-2">
                <div class="flex items-center gap-2">
                  <span class={status_badge(c.status)}>{c.status}</span>
                  <span>{c.workflow_name}</span>
                  <code class="text-xs font-mono text-base-content/60">{String.slice(c.id, 0, 8)}</code>
                </div>
                <.link navigate={~p"/executions/#{c.id}"} class="btn btn-xs btn-ghost">View</.link>
              </li>
            </ul>
          </div>
        </div>

        <div class="grid md:grid-cols-2 gap-4">
          <div class="card bg-base-100 border border-base-300">
            <div class="card-body p-4">
              <h2 class="card-title text-base">Input</h2>
              <pre class="text-xs overflow-auto max-h-48 bg-base-200 p-3 rounded"><code>{Jason.encode!(@workflow.input || %{}, pretty: true)}</code></pre>
            </div>
          </div>

          <div class="card bg-base-100 border border-base-300">
            <div class="card-body p-4">
              <h2 class="card-title text-base">Context</h2>
              <pre class="text-xs overflow-auto max-h-48 bg-base-200 p-3 rounded"><code>{Jason.encode!(@workflow.context || %{}, pretty: true)}</code></pre>
            </div>
          </div>
        </div>

        <div :if={@workflow.error} class="card bg-error/10 border border-error/30">
          <div class="card-body p-4">
            <h2 class="card-title text-base text-error">
              <.icon name="hero-exclamation-triangle" class="size-4" /> Error
            </h2>
            <pre class="text-xs overflow-auto max-h-48 bg-base-200 p-3 rounded"><code>{Jason.encode!(@workflow.error, pretty: true)}</code></pre>
          </div>
        </div>

        <div class="card bg-base-100 border border-base-300">
          <div class="card-body p-4">
            <h2 class="card-title text-base">Step history</h2>

            <div :if={@steps == []} class="text-center py-8 text-base-content/60 text-sm">
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
                      step.status == :running && "text-info motion-safe:animate-spin"
                    ]}
                  />
                </div>
                <div class="timeline-end timeline-box bg-base-100 border border-base-300">
                  <div class="flex justify-between items-center gap-2">
                    <span class="font-mono text-sm">{step.step_name}</span>
                    <span class={["badge badge-sm", status_badge(step.status)]}>{step.status}</span>
                  </div>
                  <div class="text-xs text-base-content/60 mt-1">
                    Type: {step.step_type} · attempt {step.attempt}<span :if={step.duration_ms}> · {step.duration_ms}ms</span>
                  </div>
                  <details :if={step.output} class="mt-2">
                    <summary class="text-xs cursor-pointer text-base-content/70">Output</summary>
                    <pre class="text-xs mt-1 overflow-auto max-h-32 bg-base-200 p-2 rounded"><code>{Jason.encode!(step.output, pretty: true)}</code></pre>
                  </details>
                  <details :if={step.error} class="mt-2">
                    <summary class="text-xs cursor-pointer text-error">Error</summary>
                    <pre class="text-xs mt-1 overflow-auto max-h-32 bg-base-200 p-2 rounded text-error"><code>{Jason.encode!(step.error, pretty: true)}</code></pre>
                  </details>
                </div>
                <hr :if={idx < length(@steps) - 1} class={step.status == :completed && "bg-success"} />
              </li>
            </ul>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
