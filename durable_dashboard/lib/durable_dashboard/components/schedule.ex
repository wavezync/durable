defmodule DurableDashboard.Components.Schedule do
  @moduledoc """
  Pieces shared by the schedules list and a schedule's own page — see
  `DESIGN.md` §6 "Schedules".

    * `switch/1` — on/off, `phx-click="toggle"` with the schedule's name
    * `state/1` — On / Off / Turned off (after repeated failures)
    * `cadence/1` — the cron in words when it can, the expression always
    * `recent_runs/1` — the last runs as status marks, oldest first, each a link
  """

  use Phoenix.Component

  alias DurableDashboard.Components.Core
  alias DurableDashboard.Cron
  alias DurableDashboard.Path, as: DPath

  attr :schedule, :map, required: true
  attr :disabled, :boolean, default: false
  attr :size, :string, default: "md", values: ~w(md lg)

  def switch(assigns) do
    ~H"""
    <button
      type="button"
      role="switch"
      aria-checked={to_string(@schedule.enabled)}
      aria-label={"Turn #{@schedule.name} #{if @schedule.enabled, do: "off", else: "on"}"}
      data-tip-title={if @schedule.enabled, do: "Turn off", else: "Turn on"}
      data-tip={switch_tip(@schedule, @disabled)}
      disabled={@disabled}
      phx-click="toggle"
      phx-value-name={@schedule.name}
      class={[
        "relative inline-flex shrink-0 items-center rounded-full transition-colors",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
        "disabled:cursor-not-allowed disabled:opacity-50",
        if(@size == "lg", do: "h-6 w-11", else: "h-5 w-9"),
        if(@schedule.enabled, do: "bg-primary", else: "bg-muted-foreground/35")
      ]}
    >
      <span class={[
        "inline-block rounded-full bg-white shadow-sm transition-transform",
        if(@size == "lg", do: "size-5", else: "size-4"),
        thumb_offset(@schedule.enabled, @size)
      ]}>
      </span>
    </button>
    """
  end

  defp thumb_offset(true, "lg"), do: "translate-x-[22px]"
  defp thumb_offset(true, _size), do: "translate-x-[18px]"
  defp thumb_offset(false, _size), do: "translate-x-0.5"

  attr :schedule, :map, required: true

  def state(assigns) do
    ~H"""
    <Core.status_pill
      status={state_status(@schedule)}
      label={state_label(@schedule)}
      tip={state_tip(@schedule)}
    />
    """
  end

  defp state_status(%{auto_disabled_at: at}) when not is_nil(at), do: :failed
  defp state_status(%{enabled: true}), do: :completed
  defp state_status(_schedule), do: :idle

  defp state_tip(%{auto_disabled_at: at}) when not is_nil(at),
    do:
      "It kept failing to start its workflow, so it was turned off · fix the cause, then turn it back on"

  defp state_tip(%{enabled: true}), do: "Starts its workflow on its cadence"
  defp state_tip(_schedule), do: "Turned off · it won't start runs until it's turned on"

  defp switch_tip(_schedule, true), do: "Turning schedules on and off needs admin access"

  defp switch_tip(%{enabled: true}, _disabled),
    do: "It stops starting runs · runs already going carry on"

  defp switch_tip(_schedule, _disabled), do: "It starts runs again from its next fire time"

  @doc "On / Off / Turned off, as words for places a pill doesn't fit."
  def state_label(%{auto_disabled_at: at}) when not is_nil(at), do: "Turned off after failures"
  def state_label(%{enabled: true}), do: "On"
  def state_label(_schedule), do: "Off"

  attr :schedule, :map, required: true
  attr :class, :any, default: nil

  def cadence(assigns) do
    assigns = assign(assigns, words: Cron.describe(assigns.schedule.cron_expression))

    ~H"""
    <span
      class={["text-xs text-muted-foreground", @class]}
      data-tip-title={@words || "Cron schedule"}
      data-tip={"minute · hour · day of month · month · day of week\nin #{@schedule.timezone}"}
      data-tip-meta={@schedule.cron_expression}
    >
      <span :if={@words} class="text-subtle-foreground">{@words}</span>
      <code class="ml-1 rounded-[4px] bg-secondary px-1.5 py-px font-mono text-[11px]">{@schedule.cron_expression}</code>
      <span :if={@schedule.timezone not in ["UTC", "Etc/UTC"]}> · {@schedule.timezone}</span>
    </span>
    """
  end

  attr :runs, :list,
    required: true,
    doc: "newest first, as `Durable.Query.list_executions/1` returns them"

  attr :base_path, :string, required: true
  attr :limit, :integer, default: 12

  def recent_runs(assigns) do
    assigns = assign(assigns, shown: assigns.runs |> Enum.take(assigns.limit) |> Enum.reverse())

    ~H"""
    <span :if={@shown == []} class="text-xs text-muted-foreground">no runs yet</span>
    <span :if={@shown != []} class="inline-flex items-center gap-[5px]">
      <.link
        :for={run <- @shown}
        navigate={DPath.execution(@base_path, run.id)}
        class="inline-flex size-3.5 items-center justify-center rounded-sm hover:bg-accent"
        data-tip-title={"Run #{String.slice(run.id, 0, 8)}"}
        data-tip={Core.status_help(run.status) || to_string(run.status)}
        data-tip-meta={"#{run.status} · started #{Calendar.strftime(run.inserted_at, "%Y-%m-%d %H:%M:%S")} UTC"}
      >
        <Core.status_dot status={run.status} />
      </.link>
    </span>
    """
  end
end
