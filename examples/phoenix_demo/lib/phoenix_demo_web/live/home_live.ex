defmodule PhoenixDemoWeb.HomeLive do
  @moduledoc """
  Workflow hub: a card per demo workflow. Each card opens a modal with a
  simulated-input form that triggers the workflow via `Durable.start/2`
  (or `Durable.trigger_schedule/1` for the cron entry).
  """
  use PhoenixDemoWeb, :live_view

  import PhoenixDemoWeb.WorkflowForm

  alias PhoenixDemo.Workflows

  @workflows [
    %{
      key: "order_fulfillment",
      title: "Order Fulfillment",
      module: Workflows.OrderFulfillmentWorkflow,
      description:
        "End-to-end order: reserve inventory → call PaymentWorkflow → ship → confirm. Toggle the failure flag to watch saga compensation cascade.",
      pills: ["call_workflow", "saga", "compensate"],
      fields: [
        %{name: "order_id", label: "Order ID", type: "text", default: "ORD-1042"},
        %{name: "amount", label: "Amount ($)", type: "number", default: 99.99, required: true},
        %{
          name: "force_failure",
          label: "Force shipping failure (triggers saga rollback)",
          type: "checkbox",
          default: false
        }
      ]
    },
    %{
      key: "payment",
      title: "Payment",
      module: Workflows.PaymentWorkflow,
      description:
        "Standalone or child workflow. Authorize step has retry: max_attempts: 3, backoff: :exponential — random failures show as separate attempts.",
      pills: ["retry", "exponential backoff", "composition"],
      fields: [
        %{name: "amount", label: "Amount ($)", type: "number", default: 49.50, required: true},
        %{
          name: "force_failure",
          label: "Force authorization failure",
          type: "checkbox",
          default: false
        }
      ]
    },
    %{
      key: "expense_approval",
      title: "Expense Approval",
      module: Workflows.ExpenseApprovalWorkflow,
      description:
        "Collects an expense via wait_for_form, then routes to single (manager) or dual (manager + CFO via wait_for_all) approval based on amount.",
      pills: ["wait_for_form", "wait_for_all", "decision"],
      fields: [
        %{name: "employee", label: "Employee", type: "text", default: "Alice", required: true}
      ]
    },
    %{
      key: "content_moderation",
      title: "Content Moderation",
      module: Workflows.ContentModerationWorkflow,
      description:
        "Three parallel mock-AI scans aggregate to a max-score, then branch routes to auto-remove / human-review / auto-approve.",
      pills: ["parallel", "branch", "wait_for_choice"],
      fields: [
        %{name: "content_id", label: "Content ID", type: "text", default: "POST-9001"},
        %{
          name: "content_type",
          label: "Content type",
          type: "select",
          options: ["text", "image", "video"],
          default: "image"
        }
      ]
    },
    %{
      key: "payment_reconciliation",
      title: "Payment Reconciliation",
      module: Workflows.PaymentReconciliationWorkflow,
      description:
        "Submits to a (mock) processor and parks waiting for a webhook event. Send the event from /pending-events to resume.",
      pills: ["wait_for_event", "send_event"],
      fields: [
        %{name: "transaction_id", label: "Transaction ID", type: "text", default: "TXN-7700"}
      ]
    },
    %{
      key: "drip_email",
      title: "Drip Email Campaign",
      module: Workflows.DripEmailCampaignWorkflow,
      description:
        "Welcome → schedule_at(+30s) → day-2 → sleep(30s) → day-7. The status flips :running ↔ :waiting visibly across the run.",
      pills: ["sleep", "schedule_at", "multi-stage"],
      fields: [
        %{
          name: "customer_email",
          label: "Customer email",
          type: "text",
          default: "alice@example.com",
          required: true
        },
        %{name: "campaign", label: "Campaign", type: "text", default: "welcome"}
      ]
    },
    %{
      key: "hourly_metrics_cron",
      kind: :cron,
      schedule_name: "hourly_metrics",
      title: "Hourly Metrics (cron)",
      module: Workflows.HourlyMetricsCronWorkflow,
      description:
        "Auto-runs every minute via @schedule. Click Run now to fire one immediately, or visit /schedules to watch it tick.",
      pills: ["@schedule", "cron", "scheduled"],
      fields: []
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Durable Demo",
       active_nav: :home,
       workflows: @workflows,
       open_modal: nil
     )}
  end

  @impl true
  def handle_event("open_modal", %{"key" => key}, socket) do
    case Enum.find(@workflows, &(&1.key == key)) do
      nil -> {:noreply, socket}
      wf -> {:noreply, assign(socket, open_modal: wf)}
    end
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, open_modal: nil)}
  end

  def handle_event("run_workflow", params, socket) do
    case socket.assigns.open_modal do
      nil ->
        {:noreply, socket}

      %{kind: :cron, schedule_name: name} ->
        case Durable.trigger_schedule(name) do
          {:ok, workflow_id} ->
            {:noreply,
             socket
             |> assign(open_modal: nil)
             |> put_flash(:info, "Triggered scheduled run.")
             |> push_navigate(to: ~p"/executions/#{workflow_id}")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Trigger failed: #{inspect(reason)}")}
        end

      %{module: module, fields: fields} ->
        input = build_input(fields, params["fields"] || %{})

        case Durable.start(module, input) do
          {:ok, workflow_id} ->
            {:noreply,
             socket
             |> assign(open_modal: nil)
             |> put_flash(:info, "Workflow started.")
             |> push_navigate(to: ~p"/executions/#{workflow_id}")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Start failed: #{inspect(reason)}")}
        end
    end
  end

  defp build_input(fields, submitted) do
    Enum.reduce(fields, %{}, fn field, acc ->
      name = field[:name]
      raw = Map.get(submitted, name, field[:default])
      Map.put(acc, name, coerce(field[:type], raw))
    end)
  end

  defp coerce("number", v) when is_number(v), do: v
  defp coerce("number", v) when is_binary(v) do
    case Float.parse(v) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp coerce("checkbox", "true"), do: true
  defp coerce("checkbox", true), do: true
  defp coerce("checkbox", _), do: false

  defp coerce(_, v), do: v

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav={@active_nav}>
      <div class="mb-6">
        <h1 class="text-2xl font-bold">Workflow Showcase</h1>
        <p class="text-sm text-base-content/70 mt-1">
          Each card runs a workflow that demonstrates a specific Durable feature. Click <strong>Run demo</strong>
          to trigger one with simulated input. Crons fire automatically — open <.link navigate={~p"/schedules"} class="link link-primary">/schedules</.link>
          to watch them tick.
        </p>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4">
        <div
          :for={wf <- @workflows}
          class="card bg-base-100 border border-base-300 hover:border-accent transition-colors"
        >
          <div class="card-body p-5">
            <h2 class="card-title text-base flex items-center gap-2">
              <.icon :if={wf[:kind] == :cron} name="hero-clock" class="size-4 text-accent" />
              {wf.title}
            </h2>
            <p class="text-sm text-base-content/70 leading-snug">{wf.description}</p>
            <div class="flex flex-wrap gap-1 mt-2">
              <span :for={pill <- wf.pills} class="badge badge-sm badge-ghost font-mono text-[10px]">
                {pill}
              </span>
            </div>
            <div class="card-actions justify-end mt-3">
              <button
                phx-click="open_modal"
                phx-value-key={wf.key}
                class="btn btn-sm btn-primary"
              >
                {if wf[:kind] == :cron, do: "Run now", else: "Run demo"}
              </button>
            </div>
          </div>
        </div>
      </div>

      <div :if={@open_modal} class="modal modal-open">
        <div class="modal-box max-w-lg bg-base-200 border border-base-300">
          <button
            phx-click="close_modal"
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            aria-label="close"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>

          <h3 class="font-semibold text-base">{@open_modal.title}</h3>
          <p class="text-sm text-base-content/70 mt-1">{@open_modal.description}</p>

          <div class="divider my-3"></div>

          <%= if @open_modal.fields == [] do %>
            <form phx-submit="run_workflow" class="flex justify-end pt-2">
              <button type="submit" class="btn btn-primary btn-sm">
                {if @open_modal[:kind] == :cron, do: "Trigger scheduled run", else: "Run"}
              </button>
            </form>
          <% else %>
            <.dynamic_form
              id={"trigger-form-#{@open_modal.key}"}
              fields={@open_modal.fields}
              submit_event="run_workflow"
              submit_label="Run workflow"
            />
          <% end %>
        </div>
        <div class="modal-backdrop bg-base-300/70" phx-click="close_modal"></div>
      </div>
    </Layouts.app>
    """
  end
end
