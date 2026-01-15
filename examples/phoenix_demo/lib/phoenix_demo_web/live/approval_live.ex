defmodule PhoenixDemoWeb.ApprovalLive do
  @moduledoc """
  LiveView for managing human-in-the-loop approvals.
  Shows pending approval requests and allows users to approve or reject them.
  """

  use PhoenixDemoWeb, :live_view

  alias Durable.Config
  alias Durable.Storage.Schemas.{PendingInput, WorkflowExecution}
  alias Durable.Wait

  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PhoenixDemo.PubSub, "workflows")
      :timer.send_interval(2000, self(), :refresh)
    end

    {:ok,
     assign(socket,
       page_title: "Pending Approvals",
       pending_approvals: list_pending_approvals(),
       selected: nil,
       reason: ""
     )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, pending_approvals: list_pending_approvals())}
  end

  def handle_info({:workflow_started, _id}, socket) do
    {:noreply, assign(socket, pending_approvals: list_pending_approvals())}
  end

  def handle_info({:workflow_completed, _id, _report}, socket) do
    {:noreply, assign(socket, pending_approvals: list_pending_approvals())}
  end

  def handle_info({:workflow_rejected, _id, _result}, socket) do
    {:noreply, assign(socket, pending_approvals: list_pending_approvals())}
  end

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    selected = Enum.find(socket.assigns.pending_approvals, &(&1.id == id))
    {:noreply, assign(socket, selected: selected, reason: "")}
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, selected: nil, reason: "")}
  end

  @impl true
  def handle_event("update_reason", %{"reason" => reason}, socket) do
    {:noreply, assign(socket, reason: reason)}
  end

  @impl true
  def handle_event("approve", %{"id" => id}, socket) do
    pending = Enum.find(socket.assigns.pending_approvals, &(&1.id == id))

    if pending do
      response = %{
        "approved" => true,
        "approved_by" => "manager",
        "approved_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      case Wait.provide_input(pending.workflow_id, pending.input_name, response) do
        :ok ->
          {:noreply,
           socket
           |> assign(
             pending_approvals: list_pending_approvals(),
             selected: nil,
             reason: ""
           )
           |> put_flash(:info, "Approval granted successfully!")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to approve: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("reject", %{"id" => id}, socket) do
    pending = Enum.find(socket.assigns.pending_approvals, &(&1.id == id))

    if pending do
      response = %{
        "approved" => false,
        "reason" => socket.assigns.reason || "Rejected by reviewer",
        "rejected_by" => "manager",
        "rejected_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      case Wait.provide_input(pending.workflow_id, pending.input_name, response) do
        :ok ->
          {:noreply,
           socket
           |> assign(
             pending_approvals: list_pending_approvals(),
             selected: nil,
             reason: ""
           )
           |> put_flash(:info, "Workflow rejected.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to reject: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  defp list_pending_approvals do
    config = Config.get(Durable)
    repo = config.repo

    repo.all(
      from(p in PendingInput,
        join: w in WorkflowExecution,
        on: p.workflow_id == w.id,
        where: p.status == :pending and p.input_type == :approval,
        order_by: [asc: p.inserted_at],
        preload: [:workflow],
        select_merge: %{workflow: w}
      )
    )
  end

  defp format_time(nil), do: "-"

  defp format_time(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Pending Approvals
      <:subtitle>Review and approve document processing requests</:subtitle>
      <:actions>
        <.button navigate={~p"/workflows"}>
          <.icon name="hero-arrow-left" class="size-4 mr-1" /> Back to Dashboard
        </.button>
      </:actions>
    </.header>

    <div class="mt-6">
      <div :if={@pending_approvals == []} class="text-center py-12">
        <.icon name="hero-inbox" class="size-16 mx-auto text-base-content/30" />
        <h3 class="mt-4 text-lg font-semibold">No pending approvals</h3>
        <p class="text-base-content/60">
          When workflows need approval, they'll appear here.
        </p>
        <.button navigate={~p"/workflows/new"} class="mt-4" variant="primary">
          Create a Workflow
        </.button>
      </div>

      <div :if={@pending_approvals != []} class="grid gap-4">
        <div
          :for={approval <- @pending_approvals}
          class="card bg-base-200 shadow-lg hover:shadow-xl transition-shadow"
        >
          <div class="card-body">
            <div class="flex justify-between items-start">
              <div>
                <h2 class="card-title">
                  <.icon name="hero-document-text" class="size-5" />
                  {approval.input_name}
                </h2>
                <p class="text-sm text-base-content/70 mt-1">
                  {approval.prompt}
                </p>
              </div>
              <span class="badge badge-warning">Pending</span>
            </div>

            <div class="divider my-2"></div>

            <div class="grid grid-cols-2 gap-4 text-sm">
              <div>
                <span class="text-base-content/60">Workflow ID:</span>
                <code class="ml-2 font-mono text-xs">
                  {String.slice(approval.workflow_id, 0, 8)}...
                </code>
              </div>
              <div>
                <span class="text-base-content/60">Step:</span>
                <span class="ml-2">{approval.step_name}</span>
              </div>
              <div>
                <span class="text-base-content/60">Created:</span>
                <span class="ml-2">{format_time(approval.inserted_at)}</span>
              </div>
              <div :if={approval.timeout_at}>
                <span class="text-base-content/60">Timeout:</span>
                <span class="ml-2">{format_time(approval.timeout_at)}</span>
              </div>
            </div>

            <div :if={approval.metadata} class="mt-4">
              <details class="collapse collapse-arrow bg-base-300">
                <summary class="collapse-title text-sm font-medium">
                  View Document Data
                </summary>
                <div class="collapse-content">
                  <pre class="text-xs overflow-auto max-h-48 mt-2"><code>{Jason.encode!(approval.metadata, pretty: true)}</code></pre>
                </div>
              </details>
            </div>

            <div class="card-actions justify-end mt-4">
              <button phx-click="select" phx-value-id={approval.id} class="btn btn-primary">
                <.icon name="hero-eye" class="size-4 mr-1" /> Review
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- Approval Modal -->
    <div :if={@selected} class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <button phx-click="close_modal" class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2">
          <.icon name="hero-x-mark" class="size-5" />
        </button>

        <h3 class="font-bold text-lg">Review Approval Request</h3>
        <p class="py-2 text-base-content/70">{@selected.prompt}</p>

        <div class="divider"></div>

        <div :if={@selected.metadata} class="mb-4">
          <h4 class="font-semibold mb-2">Document Information</h4>
          <div class="bg-base-300 rounded-lg p-4">
            <div :if={@selected.metadata["filename"]} class="mb-2">
              <span class="text-base-content/60">Filename:</span>
              <span class="ml-2 font-mono">{@selected.metadata["filename"]}</span>
            </div>
            <div :if={@selected.metadata["parsed_data"]}>
              <span class="text-base-content/60">Extracted Data:</span>
              <pre class="text-xs mt-2 overflow-auto max-h-64 bg-base-100 p-2 rounded"><code>{Jason.encode!(@selected.metadata["parsed_data"], pretty: true)}</code></pre>
            </div>
          </div>
        </div>

        <div class="form-control mb-4">
          <label class="label">
            <span class="label-text">Rejection Reason (optional)</span>
          </label>
          <textarea
            class="textarea textarea-bordered"
            placeholder="Enter reason if rejecting..."
            phx-change="update_reason"
            name="reason"
            value={@reason}
          ></textarea>
        </div>

        <div class="modal-action">
          <button phx-click="reject" phx-value-id={@selected.id} class="btn btn-error">
            <.icon name="hero-x-circle" class="size-5 mr-1" /> Reject
          </button>
          <button phx-click="approve" phx-value-id={@selected.id} class="btn btn-success">
            <.icon name="hero-check-circle" class="size-5 mr-1" /> Approve
          </button>
        </div>
      </div>
      <div class="modal-backdrop bg-base-300/50" phx-click="close_modal"></div>
    </div>
    """
  end
end
