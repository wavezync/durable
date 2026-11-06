defmodule DurableDashboard.Live.KeysLive do
  @moduledoc """
  Every workflow key a run was started with, one row per workflow and key,
  most recently started first: its holder, how many runs used it, re-adds and
  dropped inputs in the last 24 hours, and the workflow's `reuse:`. Filters:
  key prefix, workflow and holder status, all in the URL. See `DESIGN.md`,
  "Keys". Data: `Durable.Query.list_keys/1`.
  """

  use Phoenix.LiveView

  import Ecto.Query

  alias Durable.PubSub, as: DurablePubSub
  alias Durable.Storage.Schemas.WorkflowExecution
  alias DurableDashboard.Components.Core
  alias DurableDashboard.Components.Workflow.KeyTab
  alias DurableDashboard.Format
  alias DurableDashboard.Layouts
  alias DurableDashboard.Path, as: DPath

  @per_page 25
  @refresh_ms 2_000
  @workflow_kinds [:workflow_started, :workflow_completed, :workflow_failed, :workflow_cancelled]
  @statuses ~w(pending running waiting compensating completed failed cancelled compensated compensation_failed)

  @impl true
  def mount(_params, session, socket) do
    config = session["config"]

    if connected?(socket) do
      if durable_config = Durable.Config.get_safe(config.durable) do
        DurablePubSub.subscribe(durable_config, DurablePubSub.workflows_topic(durable_config))
      end
    end

    {:ok,
     assign(socket,
       config: config,
       base_path: config.base_path,
       durable: config.durable,
       page_title: "Keys",
       refresh_pending?: false,
       status_open?: false
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {:noreply,
     socket
     |> assign(
       query: parse_query(params),
       current_path: URI.parse(uri).path,
       breadcrumbs: [%{label: "Keys"}]
     )
     |> load()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    query = %{
      socket.assigns.query
      | q: nilify(params["q"]),
        workflow: nilify(params["workflow"]),
        page: 1
    }

    {:noreply, push_patch(socket, to: keys_path(socket.assigns.base_path, query))}
  end

  def handle_event("toggle-status-menu", _params, socket),
    do: {:noreply, assign(socket, status_open?: not socket.assigns.status_open?)}

  def handle_event("close-status-menu", _params, socket),
    do: {:noreply, assign(socket, status_open?: false)}

  def handle_event("toggle-status", %{"status" => status}, socket) when status in @statuses do
    statuses = socket.assigns.query.statuses

    statuses =
      if status in statuses, do: List.delete(statuses, status), else: statuses ++ [status]

    query = %{socket.assigns.query | statuses: statuses, page: 1}
    {:noreply, push_patch(socket, to: keys_path(socket.assigns.base_path, query))}
  end

  def handle_event("page", %{"page" => page}, socket) do
    query = %{socket.assigns.query | page: max(parse_int(page), 1)}
    {:noreply, push_patch(socket, to: keys_path(socket.assigns.base_path, query))}
  end

  def handle_event("clear", _params, socket),
    do: {:noreply, push_patch(socket, to: DPath.keys(socket.assigns.base_path))}

  @impl true
  def handle_info({:durable_event, kind, _payload}, socket) when kind in @workflow_kinds do
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

  defp load(socket) do
    %{query: query, durable: durable} = socket.assigns
    config = Durable.Config.get(durable)
    workflows = keyed_workflows(config)

    filters =
      [
        durable: durable,
        key_prefix: query.q,
        # The combobox is free text; only a known name filters.
        workflow_name: if(query.workflow in workflows, do: query.workflow),
        holder_status: if(query.statuses != [], do: query.statuses)
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    rows =
      Durable.Query.list_keys(filters ++ [limit: @per_page, offset: (query.page - 1) * @per_page])

    assign(socket,
      rows: rows,
      total: Durable.Query.count_keys(filters),
      workflows: workflows,
      reuse: reuse_by_workflow(rows),
      filtered?: filters != [durable: durable],
      error: nil
    )
  rescue
    e -> assign(socket, rows: [], total: 0, workflows: [], reuse: %{}, filtered?: false, error: e)
  end

  defp keyed_workflows(config) do
    Durable.Repo.all(
      config,
      from(w in WorkflowExecution,
        where: not is_nil(w.key),
        distinct: true,
        order_by: w.workflow_name,
        select: w.workflow_name
      )
    )
  end

  defp reuse_by_workflow(rows) do
    rows
    |> Enum.uniq_by(&{&1.workflow_module, &1.workflow_name})
    |> Map.new(fn row ->
      {{row.workflow_module, row.workflow_name}, reuse(row.workflow_module, row.workflow_name)}
    end)
  end

  defp reuse(module, name) do
    case String.to_existing_atom(module).__workflow_definition__(name) do
      {:ok, definition} -> Map.get(definition.opts, :reuse, :after_close)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      base_path={@base_path}
      current_path={@current_path}
      breadcrumbs={@breadcrumbs}
      durable={@durable}
      inbox_count={@inbox_count}
    >
      <header class="flex flex-wrap items-end justify-between gap-3">
        <Core.heading level={1} subtitle={subtitle(@total, @filtered?)}>Keys</Core.heading>
      </header>

      <div class="mt-4 flex flex-wrap items-center gap-2">
        <form phx-change="filter" phx-submit="filter" class="flex flex-wrap items-center gap-2" role="search">
          <label class="relative">
            <span class="sr-only">Key starts with</span>
            <Core.icon name="search" class="pointer-events-none absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
            <input
              type="search"
              name="q"
              value={@query.q}
              placeholder="Key starts with…"
              phx-debounce="250"
              autocomplete="off"
              class="h-8 w-72 rounded-md border border-input bg-card pl-8 pr-2 font-mono text-[13px] text-foreground placeholder:font-sans placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
            />
          </label>
          <label>
            <span class="sr-only">Workflow</span>
            <input
              type="text"
              name="workflow"
              list="keys-workflows"
              value={@query.workflow}
              placeholder="Workflow"
              phx-debounce="250"
              autocomplete="off"
              data-tip="The workflows that started a run with a key"
              class="h-8 w-56 rounded-md border border-input bg-card px-2.5 text-[13px] text-foreground placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
            />
            <datalist id="keys-workflows">
              <option :for={name <- @workflows} value={name} />
            </datalist>
          </label>
        </form>

        <div class="relative" phx-click-away="close-status-menu" phx-window-keydown="close-status-menu" phx-key="Escape">
          <Core.button
            size="sm"
            phx-click="toggle-status-menu"
            aria-haspopup="true"
            aria-expanded={to_string(@status_open?)}
            class={@query.statuses != [] && "bg-accent"}
          >
            Holder status{if @query.statuses != [], do: " · #{length(@query.statuses)}"}
            <Core.icon name="chevron-down" class="size-3.5" />
          </Core.button>
          <div
            :if={@status_open?}
            role="menu"
            class="absolute right-0 z-20 mt-1 flex w-56 flex-col rounded-md border border-border bg-popover p-1 shadow-lg"
          >
            <button
              :for={status <- statuses()}
              type="button"
              role="menuitemcheckbox"
              aria-checked={to_string(status in @query.statuses)}
              phx-click="toggle-status"
              phx-value-status={status}
              class="flex items-center justify-between gap-2 rounded px-2 py-1.5 text-left hover:bg-accent focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
            >
              <Core.status_pill status={String.to_existing_atom(status)} tip={false} />
              <Core.icon :if={status in @query.statuses} name="check" class="size-4 text-foreground" />
            </button>
          </div>
        </div>

        <Core.button :if={@filtered?} size="sm" kind="ghost" phx-click="clear">Clear filters</Core.button>
      </div>

      <section class="mt-4 overflow-hidden rounded-[10px] border border-border bg-card">
        <Core.error_state
          :if={@error}
          title="Couldn't load keys"
          reason={Exception.message(@error)}
        />
        <Core.empty_state
          :if={!@error and @rows == [] and not @filtered?}
          icon="information-circle"
          title="No run was started with a key"
          description={~s|Start one with Durable.start(Workflow, input, key: "article:42") and it shows up here.|}
        />
        <Core.empty_state
          :if={!@error and @rows == [] and @filtered?}
          icon="search"
          title="No keys match these filters"
        />
        <div :if={@rows != []} class="thin-scroll overflow-x-auto">
          <table class="w-full table-fixed border-collapse text-[13px]">
            <colgroup>
              <col />
              <col class="w-[180px]" />
              <col class="w-[190px]" />
              <col class="w-[70px]" />
              <col class="w-[96px]" />
              <col class="w-[84px]" />
              <col class="w-[110px]" />
              <col class="w-[130px]" />
            </colgroup>
            <thead>
              <tr class="border-b border-border text-left text-xs text-muted-foreground">
                <th class="px-4 py-2.5 font-medium">Key</th>
                <th class="px-3 py-2.5 font-medium">Workflow</th>
                <th class="px-3 py-2.5 font-medium" data-tip="The run holding the key now">Holder</th>
                <th class="px-3 py-2.5 text-right font-medium" data-tip="Runs started with this key">Runs</th>
                <th class="px-3 py-2.5 text-right font-medium" data-tip="Starts that found the key taken · last 24h">Re-added</th>
                <th class="px-3 py-2.5 text-right font-medium" data-tip="Re-adds whose newer input was dropped · last 24h">Dropped</th>
                <th class="px-3 py-2.5 text-right font-medium" data-tip="The newest start or re-add with this key">Last added</th>
                <th class="px-4 py-2.5 font-medium" data-tip="When a finished run lets its key go">Reuse</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={k <- @rows} class="h-10 border-b border-border last:border-b-0 hover:bg-accent">
                <td class="truncate px-4 font-mono" data-tip-meta={k.key}>{k.key}</td>
                <td class="truncate px-3">
                  <.link navigate={DPath.workflow_detail(@base_path, k.workflow_name)} class="hover:underline">
                    {k.workflow_name}
                  </.link>
                </td>
                <td class="px-3">
                  <span :if={k.holder_id} class="flex items-center gap-2">
                    <KeyTab.run_link id={k.holder_id} base_path={@base_path} />
                    <Core.status_pill status={k.holder_status} />
                  </span>
                  <span :if={!k.holder_id} class="text-xs text-muted-foreground">No holder</span>
                </td>
                <td class="px-3 text-right font-mono">
                  <.link navigate={runs_path(@base_path, k)} class="text-primary hover:underline" data-tip="Open these runs">
                    {Format.int(k.runs)}
                  </.link>
                </td>
                <td class="px-3 text-right font-mono">{Format.int(k.readded)}</td>
                <td class={["px-3 text-right font-mono", k.dropped > 0 && "text-warning"]}>{Format.int(k.dropped)}</td>
                <td class="whitespace-nowrap px-3 text-right text-xs text-muted-foreground">
                  <Core.relative_time at={last_added(k)} />
                </td>
                <td class="px-4 font-mono text-xs text-subtle-foreground">
                  {case @reuse[{k.workflow_module, k.workflow_name}] do
                    nil -> "—"
                    reuse -> inspect(reuse)
                  end}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <div :if={@total > per_page()} class="flex items-center justify-between border-t border-border px-4 py-2.5 text-xs text-muted-foreground">
          <span class="font-mono">{range_label(@query.page, length(@rows), @total)}</span>
          <span class="flex gap-2">
            <Core.button size="sm" disabled={@query.page <= 1} phx-click="page" phx-value-page={@query.page - 1}>
              ← Newer
            </Core.button>
            <Core.button
              size="sm"
              disabled={@query.page * per_page() >= @total}
              phx-click="page"
              phx-value-page={@query.page + 1}
            >
              Older →
            </Core.button>
          </span>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp statuses, do: @statuses
  defp per_page, do: @per_page

  defp subtitle(total, filtered?),
    do: "#{Format.count(total, "key")}#{if filtered?, do: " match", else: ""} · newest first"

  defp last_added(%{last_readded_at: nil, last_started_at: at}), do: at

  defp last_added(%{last_readded_at: re, last_started_at: at}),
    do: if(DateTime.after?(re, at), do: re, else: at)

  defp range_label(page, count, total) do
    first = (page - 1) * @per_page + 1
    "#{first}–#{first + count - 1} of #{Format.int(total)}"
  end

  # The key's runs, on that workflow's Runs page. A key with spaces or quotes
  # is quoted, as the search grammar expects.
  defp runs_path(base, %{key: key, workflow_name: name}) do
    term =
      if String.match?(key, ~r/[\s"]/),
        do: ~s(key:"#{String.replace(key, "\"", "")}"),
        else: "key:" <> key

    DPath.workflow_executions(base, name) <> "?" <> URI.encode_query(%{"q" => term})
  end

  # ============================================================================
  # URL <-> query
  # ============================================================================

  defp parse_query(params) do
    %{
      page: max(parse_int(params["page"]), 1),
      q: nilify(params["q"]),
      workflow: nilify(params["workflow"]),
      statuses:
        (params["status"] || "")
        |> String.split(",", trim: true)
        |> Enum.filter(&(&1 in @statuses))
    }
  end

  defp keys_path(base, query) do
    params =
      [
        {"q", query.q},
        {"workflow", query.workflow},
        {"status", if(query.statuses != [], do: Enum.join(query.statuses, ","))},
        {"page", if(query.page > 1, do: to_string(query.page))}
      ]
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)

    if params == [],
      do: DPath.keys(base),
      else: DPath.keys(base) <> "?" <> URI.encode_query(params)
  end

  defp parse_int(nil), do: 1

  defp parse_int(value) do
    case Integer.parse(to_string(value)) do
      {n, _} -> n
      :error -> 1
    end
  end

  defp nilify(nil), do: nil
  defp nilify(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))
end
