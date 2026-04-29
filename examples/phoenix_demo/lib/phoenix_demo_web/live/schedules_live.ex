defmodule PhoenixDemoWeb.SchedulesLive do
  @moduledoc """
  Lists registered scheduled workflows. Supports Run-now, Enable, and
  Disable actions per row.
  """
  use PhoenixDemoWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(5_000, self(), :refresh)
    end

    {:ok,
     assign(socket,
       page_title: "Schedules",
       active_nav: :schedules,
       schedules: Durable.list_schedules(limit: 100)
     )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, schedules: Durable.list_schedules(limit: 100))}
  end

  @impl true
  def handle_event("trigger", %{"name" => name}, socket) do
    case Durable.trigger_schedule(name) do
      {:ok, workflow_id} ->
        {:noreply,
         socket
         |> put_flash(:info, "Triggered: workflow #{String.slice(workflow_id, 0, 8)}")
         |> assign(schedules: Durable.list_schedules(limit: 100))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Trigger failed: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle", %{"name" => name, "enabled" => "true"}, socket) do
    case Durable.disable_schedule(name) do
      {:ok, _} -> {:noreply, assign(socket, schedules: Durable.list_schedules(limit: 100))}
      err -> {:noreply, put_flash(socket, :error, "Disable failed: #{inspect(err)}")}
    end
  end

  def handle_event("toggle", %{"name" => name}, socket) do
    case Durable.enable_schedule(name) do
      {:ok, _} -> {:noreply, assign(socket, schedules: Durable.list_schedules(limit: 100))}
      err -> {:noreply, put_flash(socket, :error, "Enable failed: #{inspect(err)}")}
    end
  end

  defp short_module(nil), do: "-"
  defp short_module(mod), do: mod |> to_string() |> String.split(".") |> List.last()

  defp format_time(nil), do: "—"
  defp format_time(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav={@active_nav}>
      <div class="mb-4">
        <h1 class="text-2xl font-bold">Schedules</h1>
        <p class="text-sm text-base-content/70">
          Cron-driven workflows registered via <code class="font-mono text-xs bg-base-200 px-1 rounded">@schedule</code>. The scheduler polls every 5 seconds, so the demo's <code class="font-mono">* * * * *</code> entry fires within a minute of boot.
        </p>
      </div>

      <div :if={@schedules == []} class="text-center py-12 bg-base-100 border border-base-300 rounded-md">
        <.icon name="hero-clock" class="size-12 mx-auto text-base-content/30" />
        <h3 class="mt-3 font-semibold">No schedules registered</h3>
        <p class="text-sm text-base-content/60">Confirm <code class="font-mono">scheduled_modules:</code> is set in application.ex.</p>
      </div>

      <div :if={@schedules != []} class="overflow-x-auto bg-base-100 border border-base-300 rounded-md">
        <table class="table table-sm">
          <thead>
            <tr class="text-xs uppercase tracking-wide text-base-content/60">
              <th>Name</th>
              <th>Module</th>
              <th>Cron</th>
              <th>Enabled</th>
              <th>Last run</th>
              <th>Next run</th>
              <th>Failures</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={s <- @schedules} class="hover">
              <td class="font-mono text-sm">{s.name}</td>
              <td class="text-xs">{short_module(s.workflow_module)}</td>
              <td class="font-mono text-xs">{s.cron_expression}</td>
              <td>
                <span class={if s.enabled, do: "badge badge-sm badge-success", else: "badge badge-sm badge-ghost"}>
                  {if s.enabled, do: "enabled", else: "disabled"}
                </span>
              </td>
              <td class="text-xs">{format_time(s.last_run_at)}</td>
              <td class="text-xs">{format_time(s.next_run_at)}</td>
              <td class="text-xs">{s.consecutive_failures || 0}</td>
              <td class="flex gap-1">
                <button phx-click="trigger" phx-value-name={s.name} class="btn btn-xs btn-primary">
                  Run now
                </button>
                <button
                  phx-click="toggle"
                  phx-value-name={s.name}
                  phx-value-enabled={to_string(s.enabled)}
                  class="btn btn-xs btn-ghost"
                >
                  {if s.enabled, do: "Disable", else: "Enable"}
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end
end
