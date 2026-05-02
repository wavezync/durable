defmodule PhoenixDemoWeb.PendingEventsLive do
  @moduledoc """
  Sends external events to workflows blocked on `wait_for_event`. For
  recognised event names (e.g. `webhook_received`) the page offers preset
  payload buttons; everything else gets a free-form payload editor.
  """
  use PhoenixDemoWeb, :live_view

  alias Durable.Wait
  alias Durable.Storage.Schemas.WorkflowExecution
  alias Durable.Config

  import Ecto.Query

  @presets %{
    "webhook_received" => [
      %{label: "Send: settled", payload: %{"status" => "settled", "amount" => 99.99}},
      %{label: "Send: failed", payload: %{"status" => "failed", "code" => "card_declined"}},
      %{label: "Send: timeout marker", payload: %{"status" => "timeout"}}
    ]
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PhoenixDemo.PubSub, "workflows")
      :timer.send_interval(2_000, self(), :refresh)
    end

    {:ok,
     assign(socket,
       page_title: "Pending Events",
       active_nav: :pending_events,
       pending: load_pending(),
       payloads: %{}
     )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, pending: load_pending())}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp load_pending do
    pending = Wait.list_pending_events(limit: 100)
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
  def handle_event("update_payload", %{"_id" => id, "payload" => payload}, socket) do
    {:noreply, assign(socket, payloads: Map.put(socket.assigns.payloads, id, payload))}
  end

  def handle_event("send_preset", %{"id" => id, "preset" => preset_idx}, socket) do
    pending = Enum.find(socket.assigns.pending, &(&1.id == id))

    with %{} = p <- pending,
         presets when is_list(presets) <- Map.get(@presets, p.event_name),
         idx when is_integer(idx) <- parse_int(preset_idx),
         %{payload: payload} <- Enum.at(presets, idx) do
      send_event(socket, p, payload)
    else
      _ -> {:noreply, put_flash(socket, :error, "Preset not found")}
    end
  end

  def handle_event("send_custom", %{"_id" => id}, socket) do
    pending = Enum.find(socket.assigns.pending, &(&1.id == id))

    with %{} = p <- pending,
         raw <- Map.get(socket.assigns.payloads, id, "{}"),
         {:ok, decoded} <- Jason.decode(raw) do
      send_event(socket, p, decoded)
    else
      {:error, %Jason.DecodeError{}} ->
        {:noreply, put_flash(socket, :error, "Payload is not valid JSON")}

      _ ->
        {:noreply, socket}
    end
  end

  defp send_event(socket, p, payload) do
    case Wait.send_event(p.workflow_id, p.event_name, payload) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Sent #{p.event_name} to #{String.slice(p.workflow_id, 0, 8)}")
         |> assign(pending: load_pending())}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  defp parse_int(s) when is_binary(s), do: String.to_integer(s)
  defp parse_int(n) when is_integer(n), do: n
  defp parse_int(_), do: nil

  defp short_module(nil), do: "-"
  defp short_module(mod), do: mod |> String.split(".") |> List.last()

  defp format_time(nil), do: "-"
  defp format_time(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  @impl true
  def render(assigns) do
    presets = @presets

    assigns = assign(assigns, presets: presets)

    ~H"""
    <Layouts.app flash={@flash} active_nav={@active_nav}>
      <div class="mb-4">
        <h1 class="text-2xl font-bold">Pending Events</h1>
        <p class="text-sm text-base-content/70">
          Workflows blocked on <code class="font-mono text-xs bg-base-200 px-1 rounded">wait_for_event</code>. Send a payload below to resume them.
        </p>
      </div>

      <div :if={@pending == []} class="text-center py-12 bg-base-100 border border-base-300 rounded-md">
        <.icon name="hero-bolt" class="size-12 mx-auto text-base-content/30" />
        <h3 class="mt-3 font-semibold">No workflows waiting on events</h3>
        <p class="text-sm text-base-content/60">Trigger Payment Reconciliation from the home page to populate this list.</p>
      </div>

      <div class="grid gap-4 md:grid-cols-2">
        <div :for={p <- @pending} class="card bg-base-100 border border-base-300">
          <div class="card-body p-4 gap-2">
            <div class="flex justify-between items-start">
              <div>
                <div class="font-mono text-sm font-semibold">{p.event_name}</div>
                <div class="text-xs text-base-content/60">
                  {short_module(p.workflow && p.workflow.workflow_module)} · step {p.step_name}
                </div>
              </div>
              <span class="badge badge-sm badge-ghost">{p.wait_type}</span>
            </div>

            <div class="flex flex-wrap gap-3 text-[11px] text-base-content/60 font-mono">
              <span>WF {String.slice(p.workflow_id, 0, 8)}</span>
              <span :if={p.timeout_at}>timeout {format_time(p.timeout_at)}</span>
            </div>

            <div :if={Map.has_key?(@presets, p.event_name)} class="flex flex-wrap gap-2 mt-2">
              <button
                :for={{preset, idx} <- Enum.with_index(Map.get(@presets, p.event_name))}
                phx-click="send_preset"
                phx-value-id={p.id}
                phx-value-preset={idx}
                class="btn btn-xs btn-primary"
              >
                {preset.label}
              </button>
            </div>

            <details class="text-xs mt-2">
              <summary class="cursor-pointer text-base-content/70">Custom payload</summary>
              <form phx-change="update_payload" phx-submit="send_custom" class="space-y-2 mt-2">
                <input type="hidden" name="_id" value={p.id} />
                <textarea
                  name="payload"
                  class="textarea textarea-bordered textarea-sm w-full font-mono"
                  rows="4"
                  placeholder={~s({"status": "settled"})}
                >{Map.get(@payloads, p.id, "{}")}</textarea>
                <div class="flex justify-end">
                  <button type="submit" class="btn btn-xs btn-ghost">Send custom</button>
                </div>
              </form>
            </details>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
