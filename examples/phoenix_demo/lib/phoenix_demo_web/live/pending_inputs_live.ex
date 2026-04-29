defmodule PhoenixDemoWeb.PendingInputsLive do
  @moduledoc """
  Surfaces every workflow blocked on a pending input. Each card renders an
  inline form whose fields come from the wait spec (form / choice / text /
  approval) and submits via `Durable.Wait.provide_input/3`.
  """
  use PhoenixDemoWeb, :live_view

  alias Durable.Wait
  alias Durable.Storage.Schemas.WorkflowExecution
  alias Durable.Config

  import Ecto.Query

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PhoenixDemo.PubSub, "workflows")
      :timer.send_interval(2_000, self(), :refresh)
    end

    type_filter = normalize_type_filter(params["type"])

    {:ok,
     assign(socket,
       page_title: "Pending Inputs",
       active_nav: :pending_inputs,
       type_filter: type_filter,
       pending: load_pending(type_filter),
       reasons: %{}
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    type_filter = normalize_type_filter(params["type"])
    {:noreply, assign(socket, type_filter: type_filter, pending: load_pending(type_filter))}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, pending: load_pending(socket.assigns.type_filter))}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp normalize_type_filter(nil), do: :all
  defp normalize_type_filter(""), do: :all
  defp normalize_type_filter("all"), do: :all
  defp normalize_type_filter("approval"), do: :approval
  defp normalize_type_filter("single_choice"), do: :single_choice
  defp normalize_type_filter("free_text"), do: :free_text
  defp normalize_type_filter("form"), do: :form
  defp normalize_type_filter(_), do: :all

  defp load_pending(filter) do
    pending = Wait.list_pending_inputs(limit: 100)

    pending =
      case filter do
        :all -> pending
        type -> Enum.filter(pending, &(&1.input_type == type))
      end

    workflows = preload_workflows(Enum.map(pending, & &1.workflow_id))

    Enum.map(pending, fn p ->
      Map.put(p, :workflow, Map.get(workflows, p.workflow_id))
    end)
  end

  defp preload_workflows([]), do: %{}

  defp preload_workflows(ids) do
    config = Config.get(Durable)
    repo = config.repo

    from(w in WorkflowExecution, where: w.id in ^ids, select: {w.id, w})
    |> repo.all()
    |> Map.new()
  end

  @impl true
  def handle_event("submit_form", %{"_id" => id, "fields" => fields}, socket) do
    pending = Enum.find(socket.assigns.pending, &(&1.id == id))

    if pending do
      case Wait.provide_input(pending.workflow_id, pending.input_name, fields) do
        :ok ->
          {:noreply,
           socket
           |> put_flash(:info, "Input provided.")
           |> assign(pending: load_pending(socket.assigns.type_filter))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("submit_choice", %{"_id" => id, "fields" => %{"value" => value}}, socket) do
    do_provide(socket, id, value)
  end

  def handle_event("submit_text", %{"_id" => id, "fields" => %{"text" => text}}, socket) do
    do_provide(socket, id, text)
  end

  def handle_event("approve", %{"id" => id}, socket) do
    response = %{
      "approved" => true,
      "approved_by" => "demo-user",
      "approved_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    do_provide(socket, id, response)
  end

  def handle_event("reject", %{"_id" => id}, socket) do
    reason = Map.get(socket.assigns.reasons, id, "")

    response = %{
      "approved" => false,
      "reason" => reason,
      "rejected_by" => "demo-user",
      "rejected_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    do_provide(socket, id, response)
  end

  def handle_event("update_reason", %{"_id" => id, "reason" => reason}, socket) do
    {:noreply, assign(socket, reasons: Map.put(socket.assigns.reasons, id, reason))}
  end

  def handle_event("update_reason", _params, socket), do: {:noreply, socket}

  defp do_provide(socket, id, response) do
    pending = Enum.find(socket.assigns.pending, &(&1.id == id))

    if pending do
      case Wait.provide_input(pending.workflow_id, pending.input_name, response) do
        :ok ->
          {:noreply,
           socket
           |> put_flash(:info, "Response submitted.")
           |> assign(pending: load_pending(socket.assigns.type_filter))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  defp short_module(nil), do: "-"
  defp short_module(mod), do: mod |> String.split(".") |> List.last()

  defp format_time(nil), do: "-"
  defp format_time(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  defp type_label(:approval), do: "Approval"
  defp type_label(:single_choice), do: "Choice"
  defp type_label(:free_text), do: "Text"
  defp type_label(:form), do: "Form"
  defp type_label(other), do: to_string(other)

  defp normalize_fields(fields) when is_list(fields), do: fields
  defp normalize_fields(_), do: []

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav={@active_nav}>
      <div class="mb-4">
        <h1 class="text-2xl font-bold">Pending Inputs</h1>
        <p class="text-sm text-base-content/70">
          Workflows blocked on a human response. Submit one to resume the workflow.
        </p>
      </div>

      <div role="tablist" class="tabs tabs-bordered mb-4">
        <.link patch={~p"/pending-inputs"} role="tab" class={["tab", @type_filter == :all && "tab-active"]}>All</.link>
        <.link patch={~p"/pending-inputs?type=approval"} role="tab" class={["tab", @type_filter == :approval && "tab-active"]}>Approvals</.link>
        <.link patch={~p"/pending-inputs?type=form"} role="tab" class={["tab", @type_filter == :form && "tab-active"]}>Forms</.link>
        <.link patch={~p"/pending-inputs?type=single_choice"} role="tab" class={["tab", @type_filter == :single_choice && "tab-active"]}>Choices</.link>
        <.link patch={~p"/pending-inputs?type=free_text"} role="tab" class={["tab", @type_filter == :free_text && "tab-active"]}>Text</.link>
      </div>

      <div :if={@pending == []} class="text-center py-12 bg-base-100 border border-base-300 rounded-md">
        <.icon name="hero-inbox" class="size-12 mx-auto text-base-content/30" />
        <h3 class="mt-3 font-semibold">No pending inputs</h3>
        <p class="text-sm text-base-content/60">Trigger a workflow that waits for input to populate this list.</p>
      </div>

      <div class="grid gap-4 md:grid-cols-2">
        <div :for={p <- @pending} class="card bg-base-100 border border-base-300">
          <div class="card-body p-4 gap-2">
            <div class="flex justify-between items-start">
              <div>
                <div class="font-semibold text-sm">{p.input_name}</div>
                <div class="text-xs text-base-content/60">
                  {short_module(p.workflow && p.workflow.workflow_module)} · step {p.step_name}
                </div>
              </div>
              <span class="badge badge-sm badge-ghost">{type_label(p.input_type)}</span>
            </div>

            <p :if={p.prompt} class="text-sm">{p.prompt}</p>

            <div class="flex flex-wrap gap-3 text-[11px] text-base-content/60 font-mono">
              <span>WF {String.slice(p.workflow_id, 0, 8)}</span>
              <span :if={p.timeout_at}>timeout {format_time(p.timeout_at)}</span>
            </div>

            <details :if={p.metadata && p.metadata != %{}} class="text-xs">
              <summary class="cursor-pointer text-base-content/70">Metadata</summary>
              <pre class="mt-1 bg-base-200 p-2 rounded overflow-auto max-h-40"><code>{Jason.encode!(p.metadata, pretty: true)}</code></pre>
            </details>

            <div class="divider my-1"></div>

            <%= case p.input_type do %>
              <% :approval -> %>
                <form phx-change="update_reason" phx-submit="reject" class="space-y-2">
                  <input type="hidden" name="_id" value={p.id} />
                  <textarea
                    name="reason"
                    class="textarea textarea-bordered textarea-sm w-full"
                    placeholder="Optional rejection reason"
                    rows="2"
                  >{Map.get(@reasons, p.id, "")}</textarea>
                  <div class="flex gap-2 justify-end">
                    <button type="submit" class="btn btn-sm btn-ghost text-error">
                      <.icon name="hero-x-circle" class="size-4" /> Reject
                    </button>
                    <button
                      type="button"
                      phx-click="approve"
                      phx-value-id={p.id}
                      class="btn btn-sm btn-success"
                    >
                      <.icon name="hero-check-circle" class="size-4" /> Approve
                    </button>
                  </div>
                </form>

              <% :single_choice -> %>
                <form phx-submit="submit_choice" class="space-y-2">
                  <input type="hidden" name="_id" value={p.id} />
                  <div class="flex flex-col gap-1">
                    <label :for={choice <- normalize_fields(p.fields)} class="flex items-center gap-2 cursor-pointer">
                      <input
                        type="radio"
                        name="fields[value]"
                        value={choice_value(choice)}
                        class="radio radio-sm radio-primary"
                        required
                      />
                      <span class="text-sm">{choice_label(choice)}</span>
                    </label>
                  </div>
                  <div class="flex justify-end">
                    <button type="submit" class="btn btn-sm btn-primary">Submit</button>
                  </div>
                </form>

              <% :free_text -> %>
                <form phx-submit="submit_text" class="space-y-2">
                  <input type="hidden" name="_id" value={p.id} />
                  <textarea
                    name="fields[text]"
                    class="textarea textarea-bordered textarea-sm w-full"
                    rows="3"
                    required
                  ></textarea>
                  <div class="flex justify-end">
                    <button type="submit" class="btn btn-sm btn-primary">Submit</button>
                  </div>
                </form>

              <% :form -> %>
                <form phx-submit="submit_form" class="space-y-2">
                  <input type="hidden" name="_id" value={p.id} />
                  <.form_fields fields={normalize_fields(p.fields)} />
                  <div class="flex justify-end">
                    <button type="submit" class="btn btn-sm btn-primary">Submit</button>
                  </div>
                </form>

              <% _ -> %>
                <p class="text-xs text-base-content/60">Unsupported input type: {p.input_type}</p>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :fields, :list, required: true

  defp form_fields(assigns) do
    ~H"""
    <div :for={f <- @fields} class="form-control w-full">
      <label class="label flex flex-col items-start gap-1">
        <span class="label-text text-xs">
          {field_label(f)}
          <span :if={field_required?(f)} class="text-error">*</span>
        </span>
        <%= case field_type(f) do %>
          <% "select" -> %>
            <select name={"fields[#{field_name(f)}]"} class="select select-bordered select-sm w-full" required={field_required?(f)}>
              <option value="">— Select —</option>
              <option :for={opt <- field_options(f)} value={choice_value(opt)}>{choice_label(opt)}</option>
            </select>
          <% "number" -> %>
            <input
              type="number"
              name={"fields[#{field_name(f)}]"}
              class="input input-bordered input-sm w-full"
              required={field_required?(f)}
              step="any"
            />
          <% "textarea" -> %>
            <textarea name={"fields[#{field_name(f)}]"} class="textarea textarea-bordered textarea-sm w-full" rows="2" required={field_required?(f)}></textarea>
          <% _ -> %>
            <input
              type="text"
              name={"fields[#{field_name(f)}]"}
              class="input input-bordered input-sm w-full"
              required={field_required?(f)}
            />
        <% end %>
      </label>
    </div>
    """
  end

  defp field_name(f), do: get_str(f, "name")
  defp field_label(f), do: get_str(f, "label") || get_str(f, "name")
  defp field_type(f), do: get_str(f, "type") || "text"

  defp field_required?(f) do
    case get_str(f, "required") do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  defp field_options(f) do
    case get_str(f, "options") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp choice_value(%{"value" => v}), do: to_string(v)
  defp choice_value(%{value: v}), do: to_string(v)
  defp choice_value(s) when is_binary(s), do: s
  defp choice_value(s) when is_atom(s), do: Atom.to_string(s)

  defp choice_label(%{"label" => l}), do: l
  defp choice_label(%{label: l}), do: l
  defp choice_label(s) when is_binary(s), do: s
  defp choice_label(s) when is_atom(s), do: Atom.to_string(s)

  defp get_str(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp get_str(_, _), do: nil
end
