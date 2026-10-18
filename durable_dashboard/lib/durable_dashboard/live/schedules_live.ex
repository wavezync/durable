defmodule DurableDashboard.Live.SchedulesLive do
  @moduledoc """
  Cron schedules, as a list (`/schedules`) and one at a time
  (`/schedules/:name`).

  The list says, per schedule: on or off, its cadence in words, its last
  runs as status marks, when it fires next and when it last did. A
  schedule's page adds why it's failing (if it is), its recent runs as a
  duration strip and a table, the next times it fires, and its input.

  Turning a schedule on or off needs `:admin`; running it now needs
  `:operator`. Updates live from the schedules and workflows PubSub topics.
  """

  use Phoenix.LiveView

  alias Durable.PubSub, as: DurablePubSub
  alias DurableDashboard.Access
  alias DurableDashboard.Components.Charts
  alias DurableDashboard.Components.Core
  alias DurableDashboard.Components.Schedule
  alias DurableDashboard.Format
  alias DurableDashboard.Layouts
  alias DurableDashboard.Path, as: DPath

  @refresh_ms 1_500
  @tick_ms 10_000
  @run_kinds [:workflow_started, :workflow_completed, :workflow_failed, :workflow_cancelled]

  @impl true
  def mount(_params, session, socket) do
    config = session["config"]

    if connected?(socket) do
      if durable_config = Durable.Config.get_safe(config.durable) do
        DurablePubSub.subscribe(durable_config, DurablePubSub.schedules_topic(durable_config))
        DurablePubSub.subscribe(durable_config, DurablePubSub.workflows_topic(durable_config))
      end

      # Keeps "in 42s" honest between events.
      :timer.send_interval(@tick_ms, :refresh)
    end

    {:ok,
     assign(socket,
       config: config,
       base_path: config.base_path,
       durable: config.durable,
       refresh_pending?: false,
       action_error: nil
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {:noreply,
     socket
     |> assign(current_path: URI.parse(uri).path, name: params["name"], action_error: nil)
     |> load()}
  end

  @impl true
  def handle_info({:durable_event, kind, _payload}, socket)
      when kind in @run_kinds or kind in [:schedule_toggled, :schedule_triggered] do
    if socket.assigns.refresh_pending? do
      {:noreply, socket}
    else
      Process.send_after(self(), :refresh, @refresh_ms)
      {:noreply, assign(socket, refresh_pending?: true)}
    end
  end

  def handle_info(:refresh, socket),
    do: {:noreply, socket |> assign(refresh_pending?: false) |> load()}

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ============================================================================
  # Actions
  # ============================================================================

  @impl true
  def handle_event("run-now", %{"name" => name}, socket) do
    durable = socket.assigns.durable

    result =
      Access.perform(socket, :operator, :trigger_schedule, [name], fn ->
        Durable.trigger_schedule(name, durable: durable)
      end)

    case result do
      {:ok, run_id} ->
        {:noreply, push_navigate(socket, to: DPath.execution(socket.assigns.base_path, run_id))}

      {:error, reason} ->
        {:noreply, assign(socket, action_error: describe_error(reason))}
    end
  end

  def handle_event("toggle", %{"name" => name}, socket) do
    durable = socket.assigns.durable
    enabled? = Enum.any?(socket.assigns.schedules, &(&1.name == name and &1.enabled))
    action = if enabled?, do: :disable_schedule, else: :enable_schedule

    result =
      Access.perform(socket, :admin, action, [name], fn ->
        apply(Durable, action, [name, [durable: durable]])
      end)

    case result do
      {:ok, _schedule} -> {:noreply, socket |> assign(action_error: nil) |> load()}
      {:error, reason} -> {:noreply, assign(socket, action_error: describe_error(reason))}
    end
  end

  defp describe_error(:forbidden), do: "You don't have permission to do that."
  defp describe_error(:not_found), do: "That schedule no longer exists."
  defp describe_error(%Ecto.Changeset{}), do: "The schedule couldn't be saved."
  defp describe_error(other), do: "That didn't work: #{inspect(other)}"

  # ============================================================================
  # Data
  # ============================================================================

  defp load(socket) do
    durable = socket.assigns.durable

    if Durable.Config.get_safe(durable) do
      load_view(socket, Durable.list_schedules(durable: durable, limit: 500))
    else
      assign(socket,
        schedules: [],
        runs: %{},
        schedule: nil,
        page_title: "Schedules",
        breadcrumbs: [%{label: "Schedules"}]
      )
    end
  end

  defp load_view(%{assigns: %{name: nil}} = socket, schedules) do
    # ponytail: the last 300 scheduled runs across all schedules; a busy
    # minutely schedule can crowd out rare ones' marks. Per-schedule queries if so.
    runs =
      [durable: socket.assigns.durable, trigger: :schedule, limit: 300]
      |> Durable.Query.list_executions()
      |> Enum.group_by(& &1.trigger_ref)

    assign(socket,
      schedules: schedules,
      runs: runs,
      schedule: nil,
      page_title: "Schedules",
      breadcrumbs: [%{label: "Schedules"}]
    )
  end

  defp load_view(%{assigns: %{name: name}} = socket, schedules) do
    schedule = Enum.find(schedules, &(&1.name == name))

    runs =
      if schedule,
        do:
          Durable.Query.list_executions(
            durable: socket.assigns.durable,
            trigger: :schedule,
            trigger_ref: name,
            limit: 40
          ),
        else: []

    assign(socket,
      schedules: schedules,
      schedule: schedule,
      runs: runs,
      upcoming: if(schedule, do: Durable.Scheduler.API.upcoming_runs(schedule, 6), else: []),
      page_title: name,
      breadcrumbs: [
        %{label: "Schedules", href: DPath.schedules(socket.assigns.base_path)},
        %{label: name}
      ]
    )
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        can_operate?: Access.allowed?(assigns.access, :operator),
        can_toggle?: Access.allowed?(assigns.access, :admin),
        now: DateTime.utc_now()
      )

    ~H"""
    <Layouts.app
      base_path={@base_path}
      current_path={@current_path}
      breadcrumbs={@breadcrumbs}
      durable={@durable}
      inbox_count={@inbox_count}
    >
      <.index :if={is_nil(@name)} {assigns} />
      <.show :if={@name && @schedule} {assigns} />
      <Core.empty_state
        :if={@name && is_nil(@schedule)}
        icon="calendar"
        title={"No schedule named #{@name}"}
        description="It may have been deleted or renamed."
        class="mt-6"
      />
    </Layouts.app>
    """
  end

  # ---- List -------------------------------------------------------------------

  defp index(assigns) do
    assigns = assign(assigns, on: Enum.count(assigns.schedules, & &1.enabled))

    ~H"""
    <Core.heading
      level={1}
      subtitle={"#{Format.count(length(@schedules), "schedule")} · #{@on} on · times in each schedule’s own time zone"}
    >
      Schedules
    </Core.heading>

    <p :if={@action_error} class="mt-3 text-xs text-destructive" role="alert">{@action_error}</p>

    <section class="mt-5 overflow-hidden rounded-[10px] border border-border bg-card">
      <Core.empty_state
        :if={@schedules == []}
        icon="calendar"
        title="No schedules"
        description={~s(Add @schedule cron: "0 9 * * *" above a workflow, or call Durable.schedule/3.)}
      />
      <div :if={@schedules != []} class="thin-scroll overflow-x-auto">
        <table class="w-full border-collapse">
          <thead>
            <tr class="border-b border-border text-xs text-muted-foreground">
              <th class="w-14 py-2.5 pl-4 text-left font-medium"><span data-tip="Turn a schedule on or off">On</span></th>
              <th :for={{label, tip} <- list_columns()} class="px-4 py-2.5 text-left font-medium">
                <span data-tip={tip}>{label}</span>
              </th>
              <th :if={@can_operate?} class="px-4 py-2.5"><span class="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={s <- @schedules} class="border-b border-border last:border-b-0 hover:bg-accent">
              <td class="py-3 pl-4 align-top"><Schedule.switch schedule={s} disabled={!@can_toggle?} /></td>
              <td class="px-4 py-3 align-top">
                <.link
                  navigate={DPath.schedule(@base_path, s.name)}
                  class={["font-mono text-[13px] font-medium hover:underline", !s.enabled && "text-subtle-foreground"]}
                  data-tip="Open its runs, next fires and input"
                >
                  {s.name}
                </.link>
                <Schedule.cadence schedule={s} class="mt-0.5 block" />
                <.failure_note schedule={s} />
              </td>
              <td class="px-4 py-3 align-top">
                <.link
                  navigate={DPath.workflow_detail(@base_path, s.workflow_name)}
                  class="text-[13px] hover:underline"
                  data-tip="The workflow it starts · open its structure and stats"
                >
                  {s.workflow_name}
                </.link>
              </td>
              <td class="px-4 py-3 align-top">
                <Schedule.recent_runs runs={Map.get(@runs, s.name, [])} base_path={@base_path} />
              </td>
              <td class="whitespace-nowrap px-4 py-3 align-top text-[13px]"><.next_run schedule={s} /></td>
              <td class="whitespace-nowrap px-4 py-3 align-top text-xs text-muted-foreground">
                <.last_run schedule={s} runs={Map.get(@runs, s.name, [])} />
              </td>
              <td :if={@can_operate?} class="px-4 py-2.5 text-right align-top">
                <Core.button size="sm" phx-click="run-now" phx-value-name={s.name} data-tip={run_now_tip()}>
                  Run now
                </Core.button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  attr :schedule, :map, required: true

  defp failure_note(assigns) do
    ~H"""
    <span
      :if={@schedule.consecutive_failures > 0}
      class="mt-1 block text-xs text-destructive"
      data-tip-title="Last error"
      data-tip={@schedule.last_error}
    >
      {if @schedule.auto_disabled_at,
        do: "Turned off after #{Format.count(@schedule.consecutive_failures, "failed start")} in a row",
        else: "Failed to start #{Format.count(@schedule.consecutive_failures, "time")} in a row"}
    </span>
    """
  end

  attr :schedule, :map, required: true

  defp next_run(%{schedule: %{auto_disabled_at: at}} = assigns) when not is_nil(at),
    do: ~H"""
    <span class="text-destructive" data-tip="It kept failing to start its workflow, so it was turned off">Turned off</span>
    """

  defp next_run(%{schedule: %{enabled: false}} = assigns),
    do: ~H"""
    <span class="text-muted-foreground" data-tip="Turned off · no runs until it's back on">Off</span>
    """

  defp next_run(%{schedule: %{next_run_at: nil}} = assigns),
    do: ~H"""
    <span class="text-muted-foreground">—</span>
    """

  defp next_run(assigns) do
    if DateTime.compare(assigns.schedule.next_run_at, DateTime.utc_now()) == :gt do
      ~H"""
      <Core.relative_time at={@schedule.next_run_at} />
      """
    else
      ~H"""
      <span data-tip="Its time has come · the scheduler fires it on its next poll">due now</span>
      """
    end
  end

  attr :schedule, :map, required: true
  attr :runs, :list, required: true

  # When it last started a run — by the clock or by "Run now", whichever is newer.
  defp last_run(assigns) do
    newest = [
      assigns.schedule.last_run_at | Enum.map(Enum.take(assigns.runs, 1), & &1.inserted_at)
    ]

    assigns =
      assign(assigns, at: newest |> Enum.reject(&is_nil/1) |> Enum.max(DateTime, fn -> nil end))

    ~H"""
    <Core.relative_time :if={@at} at={@at} />
    <span :if={!@at} class="text-muted-foreground">never</span>
    """
  end

  # ---- One schedule -----------------------------------------------------------

  defp show(assigns) do
    s = assigns.schedule
    finished = Enum.filter(assigns.runs, & &1.completed_at)

    assigns =
      assign(assigns,
        s: s,
        failed:
          Enum.count(assigns.runs, &(&1.status in [:failed, :compensated, :compensation_failed])),
        durations: Enum.map(finished, &duration_ms(&1, assigns.now)),
        runs_path:
          DPath.executions(assigns.base_path) <> "?" <> URI.encode_query(q: "schedule:#{s.name}")
      )

    ~H"""
    <header class="flex flex-wrap items-start justify-between gap-3">
      <div class="min-w-0">
        <div class="flex items-center gap-3">
          <h1 class="truncate font-mono text-xl font-semibold">{@s.name}</h1>
          <Schedule.state schedule={@s} />
        </div>
        <Schedule.cadence schedule={@s} class="mt-1 block text-[13px]" />
      </div>
      <div class="flex flex-wrap items-center gap-2">
        <span class="mr-1 flex items-center gap-2 text-[13px] text-subtle-foreground">
          <Schedule.switch schedule={@s} disabled={!@can_toggle?} size="lg" />
          {if @s.enabled, do: "On", else: "Off"}
        </span>
        <Core.button :if={@can_operate?} phx-click="run-now" phx-value-name={@s.name} data-tip={run_now_tip()}>
          Run now
        </Core.button>
        <Core.button navigate={@runs_path} data-tip="Every run it started, in the Runs list">All its runs</Core.button>
      </div>
    </header>

    <p :if={@action_error} class="mt-3 text-xs text-destructive" role="alert">{@action_error}</p>

    <div
      :if={@s.consecutive_failures > 0}
      role="alert"
      class={[
        "mt-4 flex items-start gap-3 rounded-[10px] border px-3.5 py-3",
        if(@s.auto_disabled_at,
          do: "border-destructive/35 bg-destructive/10",
          else: "border-warning/40 bg-warning/10"
        )
      ]}
    >
      <Core.status_dot status={if @s.auto_disabled_at, do: :failed, else: :waiting} class="mt-1.5" />
      <div class="min-w-0 flex-1">
        <p :if={@s.auto_disabled_at}>
          Turned off after failing to start its workflow {Format.count(@s.consecutive_failures, "time")} in a row.
          Fix the cause, then turn it back on.
        </p>
        <p :if={!@s.auto_disabled_at}>
          Failed to start its workflow the last {Format.count(@s.consecutive_failures, "time")} — it turns itself off after 5.
        </p>
        <p :if={@s.last_error} class="mt-1 break-words font-mono text-xs text-destructive">
          {@s.last_error}
          <span :if={@s.last_error_at} class="text-muted-foreground">· <Core.relative_time at={@s.last_error_at} /></span>
        </p>
      </div>
    </div>

    <dl class="mt-4 grid grid-cols-[repeat(auto-fit,minmax(150px,1fr))] gap-px overflow-hidden rounded-[10px] border border-border bg-border">
      <.fact label="Workflow" tip="The workflow it starts">
        <.link navigate={DPath.workflow_detail(@base_path, @s.workflow_name)} class="hover:underline">
          {@s.workflow_name}
        </.link>
      </.fact>
      <.fact label="Next run" tip="When it fires next"><.next_run schedule={@s} /></.fact>
      <.fact label="Last run" tip="When it last started a run · by the clock or Run now">
        <.last_run schedule={@s} runs={@runs} />
      </.fact>
      <.fact
        label={if length(@runs) == 1, do: "Its run", else: "Last #{length(@runs)} runs"}
        tip="Failed counts failed, rolled back and compensation-failed runs · ok is the rest"
      >
        {length(@runs) - @failed} ok<span :if={@failed > 0} class="text-destructive"> · {@failed} failed</span>
      </.fact>
      <.fact label="Took, p50 · p95" tip="Half, and 95%, of its finished runs took less">
        {Format.ms(percentile(@durations, 0.5))} · {Format.ms(percentile(@durations, 0.95))}
      </.fact>
      <.fact label="Queue" tip="The queue its runs go through">{@s.queue}</.fact>
    </dl>

    <div class="mt-4 flex flex-wrap items-start gap-4">
      <Charts.panel title="Recent runs" sub="newest on the right · height is how long each took" class="flex-[2_1_560px]">
        <:action>
          <.link navigate={@runs_path} class="text-xs font-medium text-primary hover:underline">All its runs →</.link>
        </:action>
        <p :if={@runs == []} class="px-4 pb-5 pt-1 text-xs text-muted-foreground">It hasn't started a run yet.</p>
        <.run_strip :if={@runs != []} runs={@runs} now={@now} base_path={@base_path} />
        <table :if={@runs != []} class="mt-3 w-full border-collapse">
          <thead>
            <tr class="border-y border-border text-xs text-muted-foreground">
              <th class="px-4 py-2 text-left font-medium">Run</th>
              <th class="px-4 py-2 text-left font-medium">Status</th>
              <th class="px-4 py-2 text-left font-medium">Started</th>
              <th class="px-4 py-2 text-right font-medium">Took</th>
              <th class="px-4 py-2 text-left font-medium">Where it is</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={run <- Enum.take(@runs, 15)} class="h-10 border-b border-border last:border-b-0 hover:bg-accent">
              <td class="px-4">
                <.link navigate={DPath.execution(@base_path, run.id)} class="font-mono text-xs text-primary hover:underline">
                  {String.slice(run.id, 0, 8)}
                </.link>
              </td>
              <td class="px-4"><Core.status_pill status={run.status} /></td>
              <td class="px-4 text-xs text-muted-foreground"><Core.relative_time at={run.inserted_at} /></td>
              <td class="px-4 text-right font-mono text-xs">{Format.ms(duration_ms(run, @now))}</td>
              <td
                class="max-w-[280px] truncate px-4 text-xs"
                data-tip-title={run.current_step}
                data-tip={error_line(run)}
              >
                <span class="font-mono">{run.current_step || "—"}</span>
                <span :if={error_line(run)} class="text-destructive"> — {error_line(run)}</span>
              </td>
            </tr>
          </tbody>
        </table>
      </Charts.panel>

      <div class="flex flex-[1_1_300px] flex-col gap-4">
        <Charts.panel title="Next fires" sub={if @s.enabled, do: "in your local time", else: "when it would fire if it were on"}>
          <ol class={["pb-1", !@s.enabled && "opacity-60"]}>
            <li :for={at <- @upcoming} class="flex items-baseline justify-between gap-3 border-t border-border px-4 py-2">
              <Core.local_time at={at} format="datetime" class="font-mono text-xs" />
              <span class="text-xs text-muted-foreground"><Core.relative_time at={at} /></span>
            </li>
          </ol>
          <p :if={@upcoming == []} class="px-4 pb-4 text-xs text-muted-foreground">
            Couldn't work out its next times from {@s.cron_expression} in {@s.timezone}.
          </p>
        </Charts.panel>

        <Charts.panel title="Input" sub="what each run starts with">
          <div class="px-4 pb-4"><Core.json value={@s.input || %{}} /></div>
        </Charts.panel>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :tip, :string, required: true
  slot :inner_block, required: true

  defp fact(assigns) do
    ~H"""
    <div class="flex min-w-0 flex-col gap-0.5 bg-card px-4 py-3">
      <dt class="text-xs text-muted-foreground"><span data-tip={@tip}>{@label}</span></dt>
      <dd class="truncate font-mono text-[13px]">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  attr :runs, :list, required: true
  attr :now, :any, required: true
  attr :base_path, :string, required: true

  # One bar per run, oldest left; height is duration against the longest.
  defp run_strip(assigns) do
    bars = Enum.reverse(assigns.runs)
    top = bars |> Enum.map(&(duration_ms(&1, assigns.now) || 0)) |> Enum.max(fn -> 0 end)
    assigns = assign(assigns, bars: bars, top: top)

    ~H"""
    <div class="flex h-24 items-end gap-[3px] px-4" role="img" aria-label="Recent runs by duration">
      <.link
        :for={run <- @bars}
        navigate={DPath.execution(@base_path, run.id)}
        class="group flex h-full min-w-[6px] max-w-[22px] flex-1 items-end"
        data-tip-title={"Run #{String.slice(run.id, 0, 8)}"}
        data-tip={"#{run.status} · took #{Format.ms(duration_ms(run, @now))}"}
        data-tip-meta={"started #{Calendar.strftime(run.inserted_at, "%Y-%m-%d %H:%M:%S")} UTC"}
      >
        <span
          class={["w-full rounded-t-[3px] group-hover:opacity-80", bar_class(run.status)]}
          style={"height: #{bar_height(duration_ms(run, @now), @top)}%"}
        >
        </span>
      </.link>
    </div>
    <div class="flex justify-between px-4 pt-1.5 text-[11px] text-muted-foreground">
      <Core.relative_time at={List.first(@bars).inserted_at} />
      <span data-tip="The longest run · the other bars are scaled to it">tallest {Format.ms(@top)}</span>
      <Core.relative_time at={List.last(@bars).inserted_at} />
    </div>
    """
  end

  defp bar_class(:completed), do: "bg-chart-ok"
  defp bar_class(status) when status in [:failed, :compensation_failed], do: "bg-chart-fail"
  defp bar_class(:compensated), do: "bg-comp"
  defp bar_class(:running), do: "bg-primary animate-pulse"
  defp bar_class(:waiting), do: "bg-warning"
  defp bar_class(_status), do: "bg-off"

  defp bar_height(nil, _top), do: 6
  defp bar_height(_ms, 0), do: 6
  defp bar_height(ms, top), do: max(6, round(ms / top * 100))

  # ============================================================================
  # Helpers
  # ============================================================================

  defp list_columns do
    [
      {"Schedule", "Its name, and when it fires"},
      {"Workflow", "The workflow it starts"},
      {"Recent runs", "Its last runs, oldest first · hover one for details"},
      {"Next run", "When it fires next"},
      {"Last run", "When it last started a run · by the clock or Run now"}
    ]
  end

  defp run_now_tip, do: "Start a run now, with its input · its cadence doesn't change"

  defp duration_ms(%{started_at: nil}, _now), do: nil

  defp duration_ms(%{started_at: s, completed_at: nil}, now),
    do: DateTime.diff(now, s, :millisecond)

  defp duration_ms(%{started_at: s, completed_at: c}, _now), do: DateTime.diff(c, s, :millisecond)

  defp percentile([], _p), do: nil

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, min(length(sorted) - 1, floor(p * length(sorted))))
  end

  defp error_line(%{error: %{"message" => message}}) when is_binary(message), do: message
  defp error_line(%{error: %{"reason" => reason}}) when is_binary(reason), do: reason
  defp error_line(_run), do: nil
end
