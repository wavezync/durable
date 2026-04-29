defmodule DurableDashboard.Live.DashboardLive do
  @moduledoc false

  use Phoenix.LiveView

  alias DurableDashboard.{GraphBuilder, Metrics, Serializer}
  alias Durable.Config
  alias Durable.PubSub, as: DurablePubSub
  alias Durable.Storage.Schemas.{ScheduledWorkflow, StepExecution, WorkflowExecution}

  import Ecto.Query

  require Logger

  # ============================================================================
  # Mount & Params
  # ============================================================================

  @impl true
  def mount(_params, session, socket) do
    config = session["config"]

    socket =
      assign(socket,
        config: config,
        current_view: "overview",
        view_params: %{},
        workflow_topic: nil
      )

    if connected?(socket) do
      subscribe_global(socket)
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {view, view_params} = parse_path(params["path"] || [])

    socket =
      socket
      |> assign(current_view: view, view_params: view_params)
      |> update_workflow_subscription(view, view_params)

    {:noreply, socket}
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    # `phx-update="ignore"` tells LiveView not to touch the children of this
    # element after the first render — critical because React owns the
    # contents and any morphdom patch would wipe it. The `data-config` is
    # only used at initial hook mount; we don't update it after that.
    ~H"""
    <div
      id="durable-dashboard"
      phx-hook="DurableDashboard"
      phx-update="ignore"
      data-config={Jason.encode!(%{
        base_path: @config.base_path,
        initial_view: @current_view,
        initial_params: @view_params
      })}
    >
      <div
        data-boot-sentinel
        class="flex items-center justify-center min-h-screen text-muted-foreground"
      >
        <div class="flex items-center gap-3">
          <div class="w-2 h-2 rounded-full bg-primary animate-pulse"></div>
          <span class="text-sm">Loading Durable Dashboard…</span>
        </div>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Client Events (React → LiveView)
  # ============================================================================

  @impl true
  def handle_event("list_workflows", payload, socket) do
    data = fetch_workflows(socket, payload)
    {:reply, data, socket}
  end

  def handle_event("get_workflow", %{"id" => id}, socket) do
    data = fetch_workflow_detail(socket, id)
    {:reply, data, socket}
  end

  def handle_event("get_step_logs", payload, socket) do
    %{"workflow_id" => wf_id, "step_name" => step_name} = payload
    durable = socket.assigns.config.durable

    case Durable.Query.get_step_logs(wf_id, step_name, durable: durable) do
      {:ok, logs} -> {:reply, %{logs: logs}, socket}
      {:error, _} -> {:reply, %{logs: []}, socket}
    end
  end

  def handle_event("cancel_workflow", %{"id" => id, "reason" => reason}, socket) do
    case Durable.cancel(id, reason) do
      :ok -> {:reply, %{ok: true}, socket}
      {:error, reason} -> {:reply, %{error: to_string(reason)}, socket}
    end
  end

  def handle_event("cancel_workflow", %{"id" => id}, socket) do
    case Durable.cancel(id) do
      :ok -> {:reply, %{ok: true}, socket}
      {:error, reason} -> {:reply, %{error: to_string(reason)}, socket}
    end
  end

  def handle_event("retry_workflow", %{"id" => id}, socket) do
    durable = socket.assigns.config.durable

    case retry_workflow(id, durable) do
      {:ok, new_id} -> {:reply, %{ok: true, workflow_id: new_id}, socket}
      {:error, reason} -> {:reply, %{error: to_string(reason)}, socket}
    end
  end

  def handle_event("provide_input", payload, socket) do
    %{"workflow_id" => wf_id, "input_name" => input_name, "data" => data} = payload

    case Durable.provide_input(wf_id, input_name, data) do
      :ok ->
        {:reply, %{ok: true}, socket}

      {:error, %Ecto.Changeset{} = cs} ->
        # Changesets don't implement String.Chars; surface the validation
        # errors as a JSON-friendly map for the React client.
        errors = Ecto.Changeset.traverse_errors(cs, fn {msg, _opts} -> msg end)
        {:reply, %{error: "validation failed: #{inspect(errors)}"}, socket}

      {:error, reason} ->
        {:reply, %{error: inspect(reason)}, socket}
    end
  end

  def handle_event("list_schedules", payload, socket) do
    data = fetch_schedules(socket, payload)
    {:reply, data, socket}
  end

  def handle_event("toggle_schedule", %{"id" => id, "enabled" => enabled}, socket) do
    case toggle_schedule(socket, id, enabled) do
      {:ok, _} -> {:reply, %{ok: true}, socket}
      {:error, reason} -> {:reply, %{error: to_string(reason)}, socket}
    end
  end

  def handle_event("trigger_schedule", %{"id" => id}, socket) do
    case trigger_schedule(socket, id) do
      {:ok, workflow_id} -> {:reply, %{ok: true, workflow_id: workflow_id}, socket}
      {:error, reason} -> {:reply, %{error: to_string(reason)}, socket}
    end
  end

  def handle_event("list_pending_inputs", payload, socket) do
    data = fetch_pending_inputs(socket, payload)
    {:reply, data, socket}
  end

  def handle_event("get_overview", _payload, socket) do
    data = fetch_overview(socket)
    {:reply, data, socket}
  end

  def handle_event("get_metrics", _payload, socket) do
    durable = socket.assigns.config.durable
    data = fetch_metrics(durable)
    {:reply, data, socket}
  end

  def handle_event("get_config", _payload, socket) do
    data = fetch_config(socket)
    {:reply, data, socket}
  end

  # Client-driven navigation: React updates its own view + pushState on the
  # browser URL. The server just tracks `current_view` / `view_params` so that
  # PubSub-triggered refreshes know which view is active. We intentionally
  # don't call `push_patch` — it doesn't round-trip cleanly through a
  # forwarded sub-router, and tries to match the full URL against the sub-
  # router's route table, which causes mis-routes and re-mounts.
  def handle_event("navigate", %{"view" => view} = payload, socket) do
    params = Map.get(payload, "params", %{})

    socket =
      socket
      |> assign(current_view: view, view_params: params)
      |> update_workflow_subscription(view, params)

    {:reply, %{ok: true}, socket}
  end

  # ============================================================================
  # PubSub event dispatch
  # ============================================================================

  @workflow_kinds [
    :workflow_started,
    :workflow_resumed,
    :workflow_waiting,
    :workflow_completed,
    :workflow_failed,
    :workflow_cancelled
  ]
  @step_kinds [:step_started, :step_completed, :step_failed, :step_waiting]
  @input_kinds [:input_requested, :input_provided]
  @schedule_kinds [:schedule_toggled, :schedule_triggered]
  @detail_kinds @workflow_kinds ++ @step_kinds ++ @input_kinds

  @impl true
  def handle_info({:durable_event, kind, _payload}, socket) do
    Logger.info(
      "[DurableDashboard] received :durable_event #{inspect(kind)} on view=#{socket.assigns.current_view}"
    )

    {:noreply, refresh_current_view(socket, kind)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Refresh the data for the currently-active view and push it to React.
  # Each view decides whether the event is relevant based on its kind, so we
  # only do the database work that the user is actually looking at.
  defp refresh_current_view(socket, kind) do
    case {socket.assigns.current_view, kind} do
      {"overview", k} when k in @workflow_kinds ->
        push_event(socket, "overview_data", fetch_overview(socket))

      {"workflows", k} when k in @workflow_kinds ->
        push_event(socket, "workflows_data", fetch_workflows(socket, %{}))

      {"workflow_detail", k} when k in @detail_kinds ->
        refresh_detail(socket)

      {"inputs", k} when k in @input_kinds ->
        push_event(socket, "inputs_data", fetch_pending_inputs(socket, %{}))

      {"schedules", k} when k in @schedule_kinds ->
        push_event(socket, "schedules_data", fetch_schedules(socket, %{}))

      _ ->
        socket
    end
  end

  defp refresh_detail(socket) do
    case socket.assigns.view_params["id"] do
      nil -> socket
      id -> push_event(socket, "workflow_detail", fetch_workflow_detail(socket, id))
    end
  end

  # ============================================================================
  # Data Fetching
  # ============================================================================

  defp fetch_overview(socket) do
    durable = socket.assigns.config.durable
    counts = dashboard_counts(durable)
    recent = fetch_recent_workflows(durable, 10)

    %{
      counts: counts,
      recent: Enum.map(recent, &Serializer.workflow/1)
    }
  end

  defp fetch_metrics(durable) do
    %{
      throughput: Metrics.throughput(durable, 60),
      breakdown: Metrics.status_breakdown(durable, 1440),
      percentiles: Metrics.duration_percentiles(durable, 1440),
      queues: Metrics.queue_depth(durable),
      top_failing: Metrics.top_failing(durable, 5)
    }
  end

  defp fetch_config(socket) do
    durable = socket.assigns.config.durable
    config = Config.get(durable)

    queues =
      if config do
        config.queues
        |> Enum.map(fn {name, opts} ->
          %{name: to_string(name), concurrency: Keyword.get(opts, :concurrency, 10)}
        end)
      else
        []
      end

    %{
      name: to_string(durable),
      prefix: if(config, do: config.prefix, else: "durable"),
      queue_enabled: if(config, do: config.queue_enabled, else: false),
      stale_lock_timeout: if(config, do: config.stale_lock_timeout, else: 300),
      heartbeat_interval: if(config, do: config.heartbeat_interval, else: 30_000),
      queues: queues
    }
  end

  defp fetch_workflows(socket, payload) do
    durable = socket.assigns.config.durable
    page = payload["page"] || 1
    per_page = payload["per_page"] || 20
    filters = build_filters(payload)

    opts = filters ++ [limit: per_page, offset: (page - 1) * per_page, durable: durable]
    {workflows, total} = list_executions_with_total(durable, opts)
    counts = dashboard_counts(durable)

    %{
      workflows: Enum.map(workflows, &Serializer.workflow/1),
      total: total,
      counts: counts,
      page: page,
      per_page: per_page
    }
  end

  defp fetch_workflow_detail(socket, id) do
    durable = socket.assigns.config.durable
    config = Config.get(durable)

    case Durable.Repo.get(config, WorkflowExecution, id) do
      nil ->
        %{error: "not_found"}

      execution ->
        steps = fetch_steps(config, id)
        pending = fetch_workflow_pending_inputs(config, id)
        graph = build_graph(execution, steps)

        %{
          workflow: Serializer.workflow(execution),
          steps: Enum.map(steps, &Serializer.step/1),
          pending_inputs: Enum.map(pending, &Serializer.pending_input/1),
          graph: Serializer.graph(graph)
        }
    end
  end

  defp fetch_schedules(socket, payload) do
    durable = socket.assigns.config.durable
    config = Config.get(durable)
    page = payload["page"] || 1
    per_page = payload["per_page"] || 20

    query =
      from(s in ScheduledWorkflow,
        order_by: [asc: s.name],
        limit: ^per_page,
        offset: ^((page - 1) * per_page)
      )

    total_query = from(s in ScheduledWorkflow, select: count(s.id))

    schedules = Durable.Repo.all(config, query)
    total = Durable.Repo.one(config, total_query)

    %{
      schedules: Enum.map(schedules, &Serializer.schedule/1),
      total: total
    }
  end

  defp fetch_pending_inputs(socket, payload) do
    durable = socket.assigns.config.durable
    config = Config.get(durable)
    page = payload["page"] || 1
    per_page = payload["per_page"] || 20

    alias Durable.Storage.Schemas.PendingInput

    query =
      from(p in PendingInput,
        where: p.status == :pending,
        order_by: [asc: p.inserted_at],
        limit: ^per_page,
        offset: ^((page - 1) * per_page),
        preload: [:workflow]
      )

    total_query = from(p in PendingInput, where: p.status == :pending, select: count(p.id))

    inputs = Durable.Repo.all(config, query)
    total = Durable.Repo.one(config, total_query)

    %{
      inputs: Enum.map(inputs, &Serializer.pending_input/1),
      total: total,
      page: page
    }
  end

  # ============================================================================
  # Internal Helpers
  # ============================================================================

  defp build_graph(execution, steps) do
    case safe_get_definition(execution) do
      {:ok, definition} ->
        graph = GraphBuilder.build(definition)
        GraphBuilder.overlay_status(graph, steps)

      :error ->
        # No definition available — fall back to a linear graph derived
        # from the recorded step executions. Used when the workflow module
        # isn't loaded in the dashboard's code path (rare, but possible
        # when dashboard and app are deployed separately).
        build_linear_graph(steps)
    end
  end

  defp safe_get_definition(%{workflow_module: module_str, workflow_name: name}) do
    module = Module.safe_concat([module_str])

    cond do
      function_exported?(module, :__workflow_definition__, 1) ->
        case module.__workflow_definition__(name) do
          {:error, :not_found} -> :error
          definition -> {:ok, definition}
        end

      function_exported?(module, :__default_workflow__, 0) ->
        case module.__default_workflow__() do
          {:error, :no_workflows} -> :error
          definition -> {:ok, definition}
        end

      true ->
        :error
    end
  rescue
    _ -> :error
  end

  defp build_linear_graph(steps) do
    # Each wait/resume pair produces two rows (:waiting + :completed) with
    # the same attempt, so naive Enum.uniq_by keeps the earlier :waiting
    # row and hides the resumed status. Group by step_name and take the
    # row with the latest inserted_at instead.
    deduped =
      steps
      |> Enum.group_by(& &1.step_name)
      |> Enum.map(fn {_name, rows} -> Enum.max_by(rows, & &1.inserted_at, DateTime) end)
      |> Enum.sort_by(& &1.inserted_at, DateTime)

    {nodes, edges, _} =
      Enum.reduce(deduped, {[], [], nil}, fn step, {nodes, edges, prev_id} ->
        id = step.step_name

        node = %{
          id: id,
          type: "step",
          data: %{
            label: id,
            step_type: step.step_type || "step",
            name: id,
            status: to_string(step.status),
            attempt: step.attempt,
            duration_ms: step.duration_ms
          }
        }

        edges =
          if prev_id do
            edge = %{
              id: "e-#{prev_id}-#{id}",
              source: prev_id,
              target: id,
              animated: step.status == :running,
              style:
                if(step.status in [:completed, :failed],
                  do: %{stroke: "#22c55e"},
                  else: %{}
                )
            }

            [edge | edges]
          else
            edges
          end

        {[node | nodes], edges, id}
      end)

    %{nodes: Enum.reverse(nodes), edges: Enum.reverse(edges)}
  end

  defp fetch_steps(config, workflow_id) do
    Durable.Repo.all(
      config,
      from(s in StepExecution,
        where: s.workflow_id == ^workflow_id,
        order_by: [asc: s.inserted_at]
      )
    )
  end

  defp fetch_workflow_pending_inputs(config, workflow_id) do
    alias Durable.Storage.Schemas.PendingInput

    Durable.Repo.all(
      config,
      from(p in PendingInput,
        where: p.workflow_id == ^workflow_id and p.status == :pending,
        order_by: [asc: p.inserted_at],
        preload: [:workflow]
      )
    )
  end

  defp fetch_recent_workflows(durable, limit) do
    config = Config.get(durable)

    Durable.Repo.all(
      config,
      from(w in WorkflowExecution,
        order_by: [desc: w.inserted_at],
        limit: ^limit
      )
    )
  end

  defp dashboard_counts(durable) do
    config = Config.get(durable)

    query =
      from(w in WorkflowExecution,
        group_by: w.status,
        select: {w.status, count(w.id)}
      )

    Durable.Repo.all(config, query)
    |> Map.new(fn {status, count} -> {to_string(status), count} end)
  end

  defp list_executions_with_total(durable, opts) do
    config = Config.get(durable)
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    base_query = from(w in WorkflowExecution)
    base_query = apply_query_filters(base_query, opts)

    list_query =
      from(w in base_query, order_by: [desc: w.inserted_at], limit: ^limit, offset: ^offset)

    total_query = from(w in base_query, select: count(w.id))

    workflows = Durable.Repo.all(config, list_query)
    total = Durable.Repo.one(config, total_query)

    {workflows, total}
  end

  defp apply_query_filters(query, opts) do
    Enum.reduce(opts, query, fn
      {:status, status}, q when is_binary(status) ->
        status_atom = String.to_existing_atom(status)
        from(w in q, where: w.status == ^status_atom)

      {:workflow_name, name}, q when is_binary(name) ->
        from(w in q, where: w.workflow_name == ^name)

      {:queue, queue}, q when is_binary(queue) ->
        from(w in q, where: w.queue == ^queue)

      {:search, search}, q when is_binary(search) and search != "" ->
        pattern = "%#{search}%"

        from(w in q,
          where:
            ilike(w.workflow_name, ^pattern) or
              ilike(w.workflow_module, ^pattern) or
              ilike(w.id, ^pattern)
        )

      _, q ->
        q
    end)
  end

  defp build_filters(payload) do
    []
    |> maybe_add_filter(payload, "status", :status)
    |> maybe_add_filter(payload, "workflow_name", :workflow_name)
    |> maybe_add_filter(payload, "queue", :queue)
    |> maybe_add_filter(payload, "search", :search)
  end

  defp maybe_add_filter(filters, payload, key, atom_key) do
    case Map.get(payload, key) do
      nil -> filters
      "" -> filters
      value -> Keyword.put(filters, atom_key, value)
    end
  end

  defp retry_workflow(id, durable) do
    config = Config.get(durable)

    case Durable.Repo.get(config, WorkflowExecution, id) do
      nil ->
        {:error, :not_found}

      execution ->
        module = Module.safe_concat([execution.workflow_module])
        Durable.start(module, execution.input, queue: execution.queue)
    end
  rescue
    _ -> {:error, :invalid_module}
  end

  defp toggle_schedule(socket, id, enabled) do
    config = Config.get(socket.assigns.config.durable)

    case Durable.Repo.get(config, ScheduledWorkflow, id) do
      nil ->
        {:error, :not_found}

      schedule ->
        schedule
        |> ScheduledWorkflow.enable_changeset(enabled)
        |> Durable.Repo.update(config)
    end
  end

  defp trigger_schedule(socket, id) do
    config = Config.get(socket.assigns.config.durable)

    case Durable.Repo.get(config, ScheduledWorkflow, id) do
      nil ->
        {:error, :not_found}

      schedule ->
        module = Module.safe_concat([schedule.workflow_module])
        Durable.start(module, schedule.input, queue: schedule.queue)
    end
  rescue
    _ -> {:error, :invalid_module}
  end

  # ============================================================================
  # Routing
  # ============================================================================

  defp parse_path([]), do: {"overview", %{}}
  defp parse_path(["workflows"]), do: {"workflows", %{}}
  defp parse_path(["workflows", id]), do: {"workflow_detail", %{"id" => id}}
  # Sub-tabs under a workflow (e.g. "/workflows/:id/logs") are client-owned.
  # The server only needs the id so its PubSub subscription targets the right
  # workflow — the client manages which tab is visible.
  defp parse_path(["workflows", id, _tab]), do: {"workflow_detail", %{"id" => id}}
  defp parse_path(["schedules"]), do: {"schedules", %{}}
  defp parse_path(["inputs"]), do: {"inputs", %{}}
  defp parse_path(["settings"]), do: {"settings", %{}}
  defp parse_path(_), do: {"overview", %{}}

  # ============================================================================
  # PubSub subscription management
  # ============================================================================

  defp subscribe_global(socket) do
    config = durable_config(socket)

    if config do
      Logger.debug("[DurableDashboard] subscribing to PubSub topics on #{inspect(config.pubsub)}")

      DurablePubSub.subscribe(config, DurablePubSub.workflows_topic(config))
      DurablePubSub.subscribe(config, DurablePubSub.inputs_topic(config))
      DurablePubSub.subscribe(config, DurablePubSub.schedules_topic(config))
    else
      Logger.warning("[DurableDashboard] durable config is nil; not subscribing to PubSub")
    end

    :ok
  end

  # Subscribe to a per-workflow topic when the detail view is active; drop the
  # subscription when navigating away. Avoids duplicate messages by comparing
  # against `:workflow_topic` stored in assigns.
  defp update_workflow_subscription(socket, "workflow_detail", %{"id" => id}) do
    config = durable_config(socket)
    new_topic = config && DurablePubSub.workflow_topic(config, id)
    current_topic = socket.assigns.workflow_topic

    cond do
      !connected?(socket) or !config ->
        socket

      current_topic == new_topic ->
        socket

      true ->
        if current_topic, do: DurablePubSub.unsubscribe(config, current_topic)
        DurablePubSub.subscribe(config, new_topic)
        assign(socket, workflow_topic: new_topic)
    end
  end

  defp update_workflow_subscription(socket, _view, _params) do
    config = durable_config(socket)
    current_topic = socket.assigns.workflow_topic

    if connected?(socket) && config && current_topic do
      DurablePubSub.unsubscribe(config, current_topic)
      assign(socket, workflow_topic: nil)
    else
      socket
    end
  end

  defp durable_config(socket) do
    Config.get_safe(socket.assigns.config.durable)
  end
end
