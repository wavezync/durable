defmodule DurableDashboard.Live.SettingsLive do
  @moduledoc """
  How this instance is configured, and whether its database schema is
  current. Values come from the `{Durable, ...}` child spec, so this page
  shows and explains them rather than editing them. The one action is
  pruning now (`:admin`).
  """

  use Phoenix.LiveView

  alias Durable.Migration.Migrator
  alias DurableDashboard.Access
  alias DurableDashboard.Components.Charts
  alias DurableDashboard.Components.Core
  alias DurableDashboard.Format
  alias DurableDashboard.Layouts
  alias DurableDashboard.Path, as: DPath

  @prune_groups [
    {:completed, "completed", [:completed]},
    {:failed, "failed, rolled back", [:failed, :compensated, :compensation_failed]},
    {:cancelled, "cancelled", [:cancelled]}
  ]

  @log_defaults [
    enabled: true,
    levels: [:debug, :info, :warning, :error],
    io_capture: true,
    max_log_entries: 1_000,
    max_message_length: 10_000
  ]

  @impl true
  def mount(_params, session, socket) do
    config = session["config"]

    {:ok,
     socket
     |> assign(
       config: config,
       base_path: config.base_path,
       durable: config.durable,
       page_title: "Settings",
       breadcrumbs: [%{label: "Settings"}],
       pruned: nil,
       action_error: nil
     )
     |> load()}
  end

  @impl true
  def handle_params(_params, uri, socket),
    do: {:noreply, assign(socket, current_path: URI.parse(uri).path)}

  @impl true
  def handle_event("prune", _params, socket) do
    durable = socket.assigns.durable

    case Access.perform(socket, :admin, :prune, [], fn ->
           {:ok, Durable.prune(durable: durable)}
         end) do
      {:ok, deleted} ->
        {:noreply, socket |> assign(pruned: deleted, action_error: nil) |> load()}

      {:error, :forbidden} ->
        {:noreply, assign(socket, action_error: "Pruning needs admin access.")}
    end
  end

  defp load(socket) do
    case Durable.Config.get_safe(socket.assigns.durable) do
      nil ->
        assign(socket, instance: nil)

      config ->
        applied = Migrator.migrated_versions(config.repo, prefix: config.prefix)

        assign(socket,
          instance: config,
          migrations:
            for(
              {version, module} <- Migrator.all_migrations(),
              do: {version, migration_name(module), version in applied}
            ),
          counts: Durable.Query.count_by_status(durable: socket.assigns.durable),
          log_capture:
            Keyword.merge(@log_defaults, Application.get_env(:durable, :log_capture, []))
        )
    end
  end

  # V20261016000000AddOperatorControls -> "add_operator_controls"
  defp migration_name(module) do
    module
    |> Module.split()
    |> List.last()
    |> String.replace(~r/^V\d+/, "")
    |> Macro.underscore()
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(%{instance: nil} = assigns) do
    ~H"""
    <Layouts.app base_path={@base_path} current_path={@current_path} breadcrumbs={@breadcrumbs} durable={@durable} inbox_count={@inbox_count}>
      <Core.error_state
        title="Durable isn't running here"
        description="The Durable instance for this dashboard isn't started in this BEAM. Add {Durable, repo: YourApp.Repo} to your supervision tree."
        reason={"name: " <> inspect(@durable)}
      />
    </Layouts.app>
    """
  end

  def render(assigns) do
    pending = for {v, name, false} <- assigns.migrations, do: {v, name}

    assigns =
      assign(assigns,
        pending: pending,
        applied: for({v, name, true} <- assigns.migrations, do: {v, name}),
        prune_groups: @prune_groups,
        knobs: knobs(assigns.instance),
        can_prune?: Access.allowed?(assigns.access, :admin)
      )

    ~H"""
    <Layouts.app base_path={@base_path} current_path={@current_path} breadcrumbs={@breadcrumbs} durable={@durable} inbox_count={@inbox_count}>
      <Core.heading
        level={1}
        subtitle="How this instance is configured. Values come from your {Durable, …} child spec — change them in code."
      >
        Settings
      </Core.heading>

      <div class="mt-5 flex flex-wrap gap-4">
        <Charts.panel title="Schema" sub={"#{@instance.prefix}.schema_migrations vs. the migrations this library ships"} class="flex-[3_1_520px]">
          <div :if={@pending != []} class="mx-4 mb-4 rounded-md border border-warning/40 bg-warning/10 p-4" role="alert">
            <p class="text-[13px] font-semibold text-warning">{length(@pending)} pending</p>
            <p class="mt-1 text-[13px]">
              <span :for={{v, name} <- @pending} class="mr-2 font-mono text-xs">v{v} {name}</span>
              {if length(@pending) == 1, do: "is", else: "are"} not applied. Durable can't start or save runs on this schema until it runs — every node logged the same error at boot.
            </p>
            <pre class="mt-3 rounded-md bg-card px-3 py-2.5 font-mono text-xs leading-5">mix durable.gen.upgrade<span class="block text-muted-foreground"># writes a migration calling Durable.Migration.up(to: {@pending |> List.last() |> elem(0)})</span>mix ecto.migrate</pre>
          </div>
          <p :if={@pending == []} class="px-4 pb-3 text-[13px]">
            <Core.status_dot status={:completed} class="mr-1.5" /> Up to date at v{Durable.Migration.current_version()}.
          </p>
          <ul class="border-t border-border">
            <li :for={{v, name} <- @applied} class="flex gap-3 border-b border-border px-4 py-2 text-xs last:border-b-0">
              <span class="font-mono text-subtle-foreground">v{v}</span>
              <span class="font-mono">{name}</span>
            </li>
          </ul>
        </Charts.panel>

        <Charts.panel title="Instance" class="flex-[2_1_340px]">
          <dl class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-6 gap-y-2 px-4 pb-4 text-[13px]">
            <dt class="text-muted-foreground" data-tip="The instance name · pass it as durable: when an app runs more than one">
              Durable
            </dt>
            <dd class="font-mono text-xs leading-5">{inspect(@instance.name)}</dd>
            <dt class="text-muted-foreground" data-tip="Where Durable's tables live · the :prefix option">
              Postgres schema
            </dt>
            <dd class="font-mono text-xs leading-5">{@instance.prefix}</dd>
            <dt class="text-muted-foreground" data-tip="Your Ecto repo · Durable runs its queries through it">Repo</dt>
            <dd class="font-mono text-xs leading-5">{inspect(@instance.repo)}</dd>
            <dt class="text-muted-foreground" data-tip="Where Durable broadcasts run changes · this dashboard listens on it">
              PubSub
            </dt>
            <dd class="font-mono text-xs leading-5">{if @instance.pubsub, do: inspect(@instance.pubsub), else: "none"}</dd>
            <dt class="text-muted-foreground" data-tip="The id this node stamps on the runs it holds">This node</dt>
            <dd class="text-xs leading-5">
              <span class="font-mono">{@instance.node_id}</span>
              · {if @instance.queue_enabled, do: "claims work", else: "doesn't claim work"}
            </dd>
            <dt class="text-muted-foreground">Versions</dt>
            <dd class="font-mono text-xs leading-5">
              durable {version(:durable)} · dashboard {version(:durable_dashboard)} · Elixir {System.version()} · OTP {System.otp_release()}
            </dd>
          </dl>
        </Charts.panel>
      </div>

      <div class="mt-4 flex flex-wrap gap-4">
        <Charts.panel title="Access" sub="who may change things from this dashboard" class="flex-[1_1_420px]">
          <p class="px-4 pb-3 text-[13px]">
            You: <span class="font-medium">{@user || "anonymous"}</span> ·
            <span data-tip={access_levels()[@access]}>
              <Core.badge kind="primary">{@access |> to_string() |> String.capitalize()}</Core.badge>
            </span>
          </p>
          <dl class="border-t border-border text-[13px]">
            <div :for={{level, text} <- access_levels()} class={["flex gap-4 border-b border-border px-4 py-2.5", level == @access && "bg-secondary/60"]}>
              <dt class="w-20 shrink-0 font-medium">{level |> to_string() |> String.capitalize()}</dt>
              <dd class="text-xs leading-5 text-subtle-foreground">{text}</dd>
            </div>
          </dl>
          <pre class="thin-scroll mx-4 mt-3 overflow-x-auto rounded-md bg-secondary px-3.5 py-3 font-mono text-xs leading-5">use DurableDashboard.Router,
      mount: "/durable",
      resolver: MyAppWeb.DurableResolver</pre>
          <p class="px-4 pb-4 pt-2.5 text-xs text-muted-foreground">
            Every action emits <span class="font-mono">[:durable_dashboard, :action]</span> with the user, the action, the run ids and the result — attach a handler to keep an audit trail.
          </p>
        </Charts.panel>

        <Charts.panel title="Queues on this node" sub="concurrency is per node; cluster totals and pausing live on Queues & nodes" class="flex-[1_1_420px]">
          <:action>
            <.link navigate={DPath.queues(@base_path)} class="text-xs font-medium text-primary hover:underline">Queues & nodes →</.link>
          </:action>
          <p :if={!@instance.queue_enabled} class="px-4 pb-3 text-xs text-warning">
            queue_enabled: false — this node starts runs and serves the dashboard but doesn't claim work.
          </p>
          <table class="w-full border-collapse">
            <thead>
              <tr class="border-y border-border text-xs text-muted-foreground">
                <th class="px-4 py-2 text-left font-medium">Queue</th>
                <th class="px-4 py-2 text-right font-medium" data-tip="Runs this node works on at once from the queue">
                  Concurrency
                </th>
                <th class="px-4 py-2 text-right font-medium" data-tip="How often an idle queue looks for work">
                  Poll interval
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{name, opts} <- Enum.sort(@instance.queues)} class="h-10 border-b border-border last:border-b-0">
                <td class="px-4 font-mono">{name}</td>
                <td class="px-4 text-right font-mono">{Keyword.get(opts, :concurrency, 10)}</td>
                <td class="px-4 text-right font-mono">{Format.duration(Keyword.get(opts, :poll_interval, 1_000))}</td>
              </tr>
            </tbody>
          </table>
        </Charts.panel>
      </div>

      <Charts.panel title="Timing & recovery" sub="what each knob means for your runs" class="mt-4">
        <dl class="border-t border-border">
          <div :for={{key, value, text} <- @knobs} class="grid gap-x-6 gap-y-0.5 border-b border-border px-4 py-2.5 last:border-b-0 sm:grid-cols-[200px_90px_minmax(0,1fr)]">
            <dt class="font-mono text-xs leading-5">{key}</dt>
            <dd class="font-mono text-xs leading-5">{value}</dd>
            <dd class="text-xs leading-5 text-subtle-foreground">{text}</dd>
          </div>
        </dl>
      </Charts.panel>

      <div class="mt-4 flex flex-wrap gap-4">
        <Charts.panel
          title="Retention"
          sub={if @instance.prune, do: "pruned hourly in batches of 5,000", else: "not configured — runs are kept forever"}
          class="flex-[3_1_520px]"
        >
          <:action>
            <Core.button
              :if={@instance.prune && @can_prune?}
              size="sm"
              phx-click="prune"
              data-tip="Delete runs past their retention now, rather than at the next hourly sweep"
            >
              Prune now
            </Core.button>
          </:action>
          <p :if={@pruned} class="mx-4 mb-3 rounded-md bg-success/10 px-3 py-2 text-xs text-success" role="status">
            Deleted {Format.count(@pruned |> Map.values() |> Enum.sum(), "run")}.
          </p>
          <p :if={@action_error} class="px-4 pb-3 text-xs text-destructive" role="alert">{@action_error}</p>
          <table class="w-full border-collapse">
            <thead>
              <tr class="border-y border-border text-xs text-muted-foreground">
                <th class="px-4 py-2 text-left font-medium">Runs that are</th>
                <th class="px-4 py-2 text-left font-medium" data-tip="How long after finishing a run is deleted">Kept for</th>
                <th class="px-4 py-2 text-right font-medium" data-tip="Runs in those states right now">Rows now</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{group, label, statuses} <- @prune_groups} class="h-10 border-b border-border">
                <td class="px-4">{label}</td>
                <td class="px-4 font-mono text-xs">{kept_for(@instance.prune, group)}</td>
                <td class="px-4 text-right font-mono">{Format.int(rows(@counts, statuses))}</td>
              </tr>
              <tr class="h-10">
                <td class="px-4">pending, running, waiting</td>
                <td class="px-4 text-xs text-muted-foreground">never pruned</td>
                <td class="px-4 text-right font-mono">{Format.int(rows(@counts, [:pending, :running, :waiting]))}</td>
              </tr>
            </tbody>
          </table>
          <p class="border-t border-border px-4 py-2.5 text-xs text-muted-foreground">
            Steps, inputs and events are deleted with their run.
            Configure with <span class="font-mono">prune: [completed: :timer.hours(24 * 14), failed: :timer.hours(24 * 30)]</span>.
          </p>
        </Charts.panel>

        <Charts.panel title="Log capture" sub="Logger and IO output inside steps, stored on the step" class="flex-[2_1_340px]">
          <dl class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-6 gap-y-2 px-4 pb-4 text-[13px]">
            <dt class="text-muted-foreground">Capture</dt>
            <dd class="text-xs leading-5">{if @log_capture[:enabled], do: "on", else: "off"}</dd>
            <dt class="text-muted-foreground" data-tip="Log lines below these levels aren't stored">Levels kept</dt>
            <dd class="font-mono text-xs leading-5">{Enum.join(@log_capture[:levels], ", ")}</dd>
            <dt class="text-muted-foreground" data-tip="Whether IO.puts and IO.inspect inside a step are kept as log lines">
              IO.puts capture
            </dt>
            <dd class="text-xs leading-5">{if @log_capture[:io_capture], do: "on", else: "off"}</dd>
            <dt class="text-muted-foreground">Per step</dt>
            <dd class="text-xs leading-5">
              up to {Format.int(@log_capture[:max_log_entries])} lines of {Format.int(@log_capture[:max_message_length])} chars
            </dd>
            <dt class="text-muted-foreground" data-tip="The Logger level for Durable's own queries · false turns them off">
              Ecto query logs
            </dt>
            <dd class="font-mono text-xs leading-5">{inspect(@instance.log_level)}</dd>
          </dl>
          <p class="border-t border-border px-4 py-2.5 text-xs text-muted-foreground">
            Set with <span class="font-mono">config :durable, log_capture: [...]</span>.
          </p>
        </Charts.panel>
      </div>

      <Charts.panel title="Effective configuration" sub={"the child spec as Durable resolved it on #{@instance.node_id}, defaults filled in"} class="mt-4">
        <:action>
          <Core.copy_button text={effective_config(@instance)} label="Copy configuration" />
        </:action>
        <pre class="thin-scroll mx-4 mb-4 overflow-x-auto rounded-md bg-secondary px-3.5 py-3 font-mono text-xs leading-5">{effective_config(@instance)}</pre>
      </Charts.panel>
    </Layouts.app>
    """
  end

  defp access_levels do
    [
      viewer: "Sees everything, changes nothing. The default when no resolver is configured.",
      operator:
        "Retry, rerun and cancel runs · answer inputs · send events · pause and resume queues · run a schedule now.",
      admin:
        "Everything above, plus bulk actions over 100 runs, enabling and disabling schedules, and pruning now."
    ]
  end

  defp knobs(config) do
    [
      {"queue_enabled", inspect(config.queue_enabled),
       "Whether this node claims work. Set false on web-only nodes that should only start runs and serve the dashboard."},
      {"heartbeat_interval", Format.duration(config.heartbeat_interval),
       "A busy worker proves it's alive this often, keeping its lock on the run."},
      {"stale_lock_timeout", Format.duration(config.stale_lock_timeout * 1_000),
       "After this long without a heartbeat, another node takes the run over and resumes it from its last finished step."},
      {"scheduler_interval", Format.duration(config.scheduler_interval),
       "How often due cron schedules are checked — a schedule can fire up to this late."},
      {"sleep_waker_interval", Format.duration(config.sleep_waker_interval),
       "Sleeping runs wake within about this long of their time."},
      {"sleep_waker_batch_size", Format.int(config.sleep_waker_batch_size),
       "How many sleeping runs one sweep wakes; more wait for the next sweep."}
    ]
  end

  defp kept_for(nil, _group), do: "forever"

  defp kept_for(prune, group) do
    case prune[group] do
      nil -> "forever"
      ms -> Format.duration(ms)
    end
  end

  defp rows(counts, statuses), do: statuses |> Enum.map(&Map.get(counts, &1, 0)) |> Enum.sum()

  defp version(app) do
    case Application.spec(app, :vsn) do
      nil -> "?"
      vsn -> to_string(vsn)
    end
  end

  defp effective_config(config) do
    opts =
      config
      |> Map.from_struct()
      |> Map.drop([:node_id, :owns_pubsub?])
      |> Enum.sort()

    body = opts |> inspect(pretty: true, limit: :infinity) |> String.slice(1..-2//1)
    "{Durable, " <> body <> "}"
  end
end
