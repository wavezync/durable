defmodule DurableDashboard.Live.SettingsLive do
  @moduledoc """
  Read-only settings view. Shows the running Durable instance's configuration
  — queues, timeouts, prefix, pubsub. No write actions yet; mutating settings
  via the dashboard is a separate (and more dangerous) feature.
  """

  use Phoenix.LiveView

  alias DurableDashboard.Components.Core
  alias DurableDashboard.Layouts

  @impl true
  def mount(_params, session, socket) do
    config = session["config"]

    {:ok,
     assign(socket,
       config: config,
       base_path: config.base_path,
       durable: config.durable,
       page_title: "Settings"
     )}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply,
     assign(socket,
       current_path: URI.parse(uri).path,
       breadcrumbs: [%{label: "Settings"}],
       instance: load_instance(socket.assigns.durable)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      base_path={@base_path}
      current_path={@current_path}
      breadcrumbs={@breadcrumbs}
    >
      <Core.heading level={1} subtitle="Read-only view of the Durable instance configuration">
        Settings
      </Core.heading>

      <%= if @instance.found? do %>
        <div class="mt-6 grid grid-cols-1 lg:grid-cols-2 gap-4">
          <Core.card>
            <:title>Instance</:title>
            <dl class="grid grid-cols-2 gap-x-6 gap-y-3 text-[13px]">
              <.row label="Name">
                <Core.code>{@instance.name}</Core.code>
              </.row>
              <.row label="Schema prefix">
                <Core.code>{@instance.prefix}</Core.code>
              </.row>
              <.row label="Queue processing">
                <Core.badge kind={if @instance.queue_enabled, do: "success", else: "muted"}>
                  {if @instance.queue_enabled, do: "enabled", else: "disabled"}
                </Core.badge>
              </.row>
              <.row label="PubSub">
                <%= if @instance.pubsub do %>
                  <Core.code>{@instance.pubsub}</Core.code>
                <% else %>
                  <span class="text-muted-foreground">disabled</span>
                <% end %>
              </.row>
            </dl>
          </Core.card>

          <Core.card>
            <:title>Resilience</:title>
            <dl class="grid grid-cols-2 gap-x-6 gap-y-3 text-[13px]">
              <.row label="Stale lock timeout">
                <span class="text-numeric">{format_seconds(@instance.stale_lock_timeout)}</span>
              </.row>
              <.row label="Heartbeat interval">
                <span class="text-numeric">{format_ms(@instance.heartbeat_interval)}</span>
              </.row>
              <.row label="Scheduler interval">
                <span class="text-numeric">{format_ms(@instance.scheduler_interval)}</span>
              </.row>
            </dl>
          </Core.card>

          <Core.card class="lg:col-span-2" padding="none">
            <:title>Queues</:title>
            <%= if @instance.queues == [] do %>
              <Core.empty_state
                icon="queue"
                title="No queues configured"
                description="Pass `queues: %{name: [...]}` when starting Durable to configure one."
              />
            <% else %>
              <table class="w-full text-[13px]">
                <thead>
                  <tr class="border-b border-border text-[11px] uppercase tracking-wider text-muted-foreground">
                    <th class="text-left font-medium px-4 h-10">Name</th>
                    <th class="text-right font-medium px-4 h-10">Concurrency</th>
                    <th class="text-right font-medium px-4 h-10">Poll interval</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={q <- @instance.queues} class="border-b border-border/60 last:border-b-0">
                    <td class="px-4 h-10">
                      <Core.code>{q.name}</Core.code>
                    </td>
                    <td class="px-4 h-10 text-right text-numeric">{q.concurrency}</td>
                    <td class="px-4 h-10 text-right text-numeric">{format_ms(q.poll_interval)}</td>
                  </tr>
                </tbody>
              </table>
            <% end %>
          </Core.card>
        </div>
      <% else %>
        <Core.error_state
          title="Instance not running"
          description="The Durable instance for this dashboard isn't started in the current BEAM. Add `{Durable, repo: YourApp.Repo}` to your supervision tree."
          reason={"name: " <> inspect(@durable)}
        />
      <% end %>
    </Layouts.app>
    """
  end

  # ============================================================================
  # Layout helpers (private)
  # ============================================================================

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp row(assigns) do
    ~H"""
    <div class="flex flex-col gap-0.5">
      <dt class="text-[10px] uppercase tracking-wider text-muted-foreground">{@label}</dt>
      <dd>{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  # ============================================================================
  # Data
  # ============================================================================

  defp load_instance(durable_name) do
    case Durable.Config.get_safe(durable_name) do
      nil ->
        %{found?: false, name: to_string(durable_name)}

      config ->
        %{
          found?: true,
          name: to_string(durable_name),
          prefix: config.prefix,
          queue_enabled: config.queue_enabled,
          stale_lock_timeout: config.stale_lock_timeout,
          heartbeat_interval: config.heartbeat_interval,
          scheduler_interval: config.scheduler_interval,
          pubsub: config.pubsub && to_string(config.pubsub),
          queues: format_queues(config.queues)
        }
    end
  end

  defp format_queues(queues) when is_map(queues) do
    queues
    |> Enum.map(fn {name, opts} ->
      %{
        name: to_string(name),
        concurrency: Keyword.get(opts, :concurrency, 10),
        poll_interval: Keyword.get(opts, :poll_interval, 1000)
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp format_queues(_), do: []

  # ============================================================================
  # Formatting
  # ============================================================================

  defp format_seconds(s) when is_integer(s) and s < 60, do: "#{s}s"
  defp format_seconds(s) when is_integer(s) and s < 3600, do: "#{div(s, 60)}m"
  defp format_seconds(s) when is_integer(s), do: "#{div(s, 3600)}h"
  defp format_seconds(_), do: "—"

  defp format_ms(ms) when is_integer(ms) and ms < 1000, do: "#{ms}ms"
  defp format_ms(ms) when is_integer(ms) and ms < 60_000, do: "#{div(ms, 1000)}s"
  defp format_ms(ms) when is_integer(ms), do: "#{div(ms, 60_000)}m"
  defp format_ms(_), do: "—"
end
