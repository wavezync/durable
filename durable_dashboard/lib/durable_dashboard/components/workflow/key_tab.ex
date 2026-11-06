defmodule DurableDashboard.Components.Workflow.KeyTab do
  @moduledoc """
  The run page's **Key** view (`/executions/:id/key`): what happened to this
  run's workflow key. See `DESIGN.md`, "Key view".

    * **Added again** — every start that found this run holding the key
      (`Durable.Activity` kind `key_duplicate`, kept a week), with its
      outcome and whether its input differed. A dropped input opens in place
      to a field diff against this run's input, plus Copy input.
    * **Runs with this key** — the holder first, then newest first, each with
      one sentence on its part in the key's history.

  `load/2` gathers what the run page needs about the key (its header, facts,
  banner and blocked actions read it too), and `block/2` says why Retry or
  Rerun can't go ahead.
  """

  use Phoenix.LiveComponent

  import Ecto.Query

  alias Durable.Storage.Schemas.{ActivityEvent, WorkflowExecution}
  alias DurableDashboard.Components.Core
  alias DurableDashboard.Path, as: DPath

  @week 7 * 86_400
  @kinds ~w(key_duplicate key_handed_off key_released key_retaken)

  # ============================================================================
  # Data
  # ============================================================================

  @doc """
  What the page shows about `run`'s key, or nil for a run without one:
  `%{key, reuse, holder, runs, events, duplicates, dropped, took}`.
  """
  @spec load(Durable.Config.t(), WorkflowExecution.t()) :: map() | nil
  def load(_config, %WorkflowExecution{key: nil}), do: nil

  def load(config, %WorkflowExecution{} = run) do
    runs =
      Durable.Repo.all(
        config,
        from(w in WorkflowExecution,
          where:
            w.workflow_module == ^run.workflow_module and w.workflow_name == ^run.workflow_name and
              w.key == ^run.key,
          order_by: [desc: w.holds_key, desc: w.inserted_at],
          limit: 50,
          select: map(w, [:id, :status, :holds_key, :inserted_at, :current_step])
        )
      )

    since = DateTime.add(DateTime.utc_now(), -@week, :second)

    events =
      Durable.Repo.all(
        config,
        from(a in ActivityEvent,
          where:
            a.workflow_id in ^Enum.map(runs, & &1.id) and a.kind in @kinds and a.at >= ^since,
          order_by: [desc: a.at],
          limit: 500
        )
      )

    duplicates = Enum.filter(events, &(&1.kind == "key_duplicate" and &1.workflow_id == run.id))

    %{
      key: run.key,
      reuse: reuse(run),
      holder: Enum.find(runs, & &1.holds_key),
      runs: runs,
      events: events,
      duplicates: duplicates,
      dropped: Enum.filter(duplicates, &dropped?/1),
      took:
        Enum.find(
          events,
          &(&1.workflow_id == run.id and &1.kind in ~w(key_handed_off key_retaken))
        )
    }
  end

  defp reuse(run) do
    module = String.to_existing_atom(run.workflow_module)

    case module.__workflow_definition__(run.workflow_name) do
      {:ok, definition} -> Map.get(definition.opts, :reuse, :after_close)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc "A duplicate whose newer input was dropped: the caller got this run back."
  def dropped?(%{details: d}), do: d["outcome"] == "use_existing" and d["input_changed"] == true

  @doc """
  Whether `action` (`:retry` or `:rerun`) can go ahead for `run` given its
  key: `:ok`, `{:take, holder}` (it will take the key from `holder`, or a
  free key when nil), or `{:blocked, reason, holder}`.
  """
  def block(_action, _run, nil), do: :ok

  def block(:retry, %{holds_key: true}, _info), do: :ok

  def block(:retry, _run, %{holder: nil}), do: {:take, nil}

  def block(:retry, _run, %{holder: holder} = info) do
    cond do
      holder.status in WorkflowExecution.open_statuses() -> {:blocked, :open, holder}
      reusable?(holder, info) -> {:take, holder}
      true -> {:blocked, :kept, holder}
    end
  end

  def block(:rerun, _run, %{holder: nil}), do: :ok

  def block(:rerun, _run, %{holder: holder} = info) do
    cond do
      holder.status in WorkflowExecution.open_statuses() -> {:blocked, :open, holder}
      reusable?(holder, info) -> :ok
      true -> {:blocked, :kept, holder}
    end
  end

  defp reusable?(_holder, %{reuse: nil}), do: false

  defp reusable?(holder, %{reuse: reuse}),
    do: holder.status in WorkflowExecution.reusable_statuses(reuse)

  # ============================================================================
  # Shared pieces
  # ============================================================================

  attr :action, :atom, required: true
  attr :block, :any, required: true
  attr :run_id, :string, required: true
  attr :info, :map, required: true
  attr :base_path, :string, required: true

  @doc "One muted line under the actions: why Retry or Rerun is off, and what would unblock it."
  def blocked_line(%{block: {:blocked, _, _}} = assigns) do
    {:blocked, why, holder} = assigns.block
    assigns = assign(assigns, why: why, holder: holder, self?: holder.id == assigns.run_id)

    ~H"""
    <p class="w-full text-xs text-muted-foreground">
      <%= cond do %>
        <% @action == :retry and @why == :open -> %>
          Retry needs <span class="font-mono">{@info.key}</span> back.
          <.run_link id={@holder.id} base_path={@base_path} />
          holds it and {still(@holder.status)}: cancel it or wait for it to finish.
        <% @action == :retry -> %>
          Retry needs <span class="font-mono">{@info.key}</span> back.
          <.run_link id={@holder.id} base_path={@base_path} />
          holds it, and the workflow's <span class="font-mono">reuse: {inspect(@info.reuse)}</span>
          keeps a {status_word(@holder.status)} run's key. Release its key first.
        <% @why == :open -> %>
          Rerun would be refused: <.run_link id={@holder.id} base_path={@base_path} />
          holds <span class="font-mono">{@info.key}</span> and {still(@holder.status)}.
        <% @self? -> %>
          Rerun would be refused: this run holds <span class="font-mono">{@info.key}</span>
          and the workflow's reuse is <span class="font-mono">{inspect(@info.reuse)}</span>.
          Release the key first.
        <% true -> %>
          Rerun would be refused: <.run_link id={@holder.id} base_path={@base_path} />
          holds <span class="font-mono">{@info.key}</span>
          and the workflow's reuse is <span class="font-mono">{inspect(@info.reuse)}</span>.
          Release its key first.
      <% end %>
    </p>
    """
  end

  def blocked_line(assigns), do: ~H""

  attr :id, :string, required: true
  attr :base_path, :string, required: true

  @doc "A short run id linking to that run's Key view."
  def run_link(assigns) do
    ~H"""
    <.link
      navigate={DPath.execution_tab(@base_path, @id, "key")}
      class="font-mono text-primary hover:underline"
      data-tip-meta={@id}
    >{short(@id)}</.link>
    """
  end

  defp still(:pending), do: "hasn't started yet"
  defp still(:waiting), do: "is waiting"
  defp still(:compensating), do: "is rolling back"
  defp still(_running), do: "is still running"

  defp status_word(:compensation_failed), do: "rollback-failed"
  defp status_word(status), do: to_string(status)

  # ============================================================================
  # The view
  # ============================================================================

  @impl true
  def mount(socket), do: {:ok, assign(socket, open: nil)}

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    {:noreply, assign(socket, open: if(socket.assigns.open == id, do: nil, else: id))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="grid gap-4 px-3.5 pb-3.5 lg:grid-cols-[minmax(0,1.25fr)_minmax(0,1fr)]">
      <section class="min-w-0 overflow-hidden rounded-[10px] border border-border">
        <header class="flex flex-wrap items-baseline justify-between gap-2 border-b border-border px-3.5 py-2.5">
          <h3 class="text-sm font-semibold">Added again</h3>
          <span class="text-xs text-muted-foreground">
            Starts that found this run holding <span class="font-mono">{@info.key}</span> · last 7 days
          </span>
        </header>
        <Core.empty_state
          :if={@info.duplicates == []}
          icon="information-circle"
          title={"Nobody added #{@info.key} again."}
          class="py-8"
        />
        <table :if={@info.duplicates != []} class="w-full table-fixed text-[13px]">
          <colgroup><col class="w-[150px]" /><col /><col class="w-[170px]" /><col class="w-[90px]" /></colgroup>
          <thead>
            <tr class="border-b border-border text-left text-xs font-medium text-muted-foreground">
              <th class="px-3.5 py-2 font-medium">When</th>
              <th class="px-3 py-2 font-medium">Outcome</th>
              <th class="px-3 py-2 font-medium">Input</th>
              <th class="px-3 py-2 font-medium">Node</th>
            </tr>
          </thead>
          <tbody>
            <%= for dup <- @info.duplicates do %>
              <tr
                class={[
                  "h-10 border-b border-border last:border-b-0",
                  changed?(dup) && "cursor-pointer hover:bg-accent",
                  @open == dup.id && "bg-accent"
                ]}
                phx-click={changed?(dup) && "toggle"}
                phx-value-id={dup.id}
                phx-target={@myself}
                aria-expanded={changed?(dup) && to_string(@open == dup.id)}
              >
                <td class="px-3.5 font-mono text-xs"><Core.local_time at={dup.at} format="datetime" /></td>
                <td class="truncate px-3">{outcome(dup)}</td>
                <td class="px-3"><.input_cell dup={dup} /></td>
                <td class="truncate px-3 font-mono text-xs text-muted-foreground" data-tip-meta={dup.node_id}>
                  {short_node(dup.node_id)}
                </td>
              </tr>
              <tr :if={@open == dup.id} class="border-b border-border bg-muted">
                <td colspan="4" class="px-3.5 py-3">
                  <.dropped_input dup={dup} input={@workflow.input} />
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </section>

      <section class="min-w-0 overflow-hidden rounded-[10px] border border-border">
        <header class="flex flex-wrap items-baseline justify-between gap-2 border-b border-border px-3.5 py-2.5">
          <h3 class="text-sm font-semibold">Runs with this key</h3>
          <span :if={@info.reuse} class="font-mono text-xs text-muted-foreground" data-tip={reuse_tip(@info.reuse)}>
            reuse: {inspect(@info.reuse)}
          </span>
        </header>
        <ol>
          <li
            :for={run <- @info.runs}
            class={[
              "flex items-center justify-between gap-3 border-b border-border px-3.5 py-2.5 last:border-b-0",
              run.id == @workflow.id && "bg-accent/60"
            ]}
          >
            <div class="flex min-w-0 flex-col gap-0.5">
              <span class="flex items-center gap-2">
                <.run_link id={run.id} base_path={@base_path} />
                <span :if={run.id == @workflow.id} class="text-xs text-muted-foreground">this run</span>
              </span>
              <span class="text-xs text-muted-foreground">
                <.history run={run} info={@info} base_path={@base_path} />
              </span>
            </div>
            <Core.status_pill status={run.status} />
          </li>
        </ol>
      </section>
    </div>
    """
  end

  defp changed?(%{details: d}), do: d["input_changed"] == true

  defp outcome(%{details: %{"outcome" => "error"}}), do: "Returned {:error, {:key_taken, …}}"
  defp outcome(_dup), do: "Returned this run"

  attr :dup, :map, required: true

  defp input_cell(%{dup: %{details: %{"input_changed" => true}}} = assigns) do
    ~H"""
    <span
      :if={dropped?(@dup)}
      data-tip="The caller got this run back, so its newer input wasn't run · click to compare"
    >
      <Core.badge kind="warning">Newer input dropped</Core.badge>
    </span>
    <span :if={!dropped?(@dup)} data-tip="The caller got the error · click to compare">
      <Core.badge kind="muted">Different input</Core.badge>
    </span>
    """
  end

  defp input_cell(assigns), do: ~H|<span class="text-xs text-muted-foreground">Same input</span>|

  attr :dup, :map, required: true
  attr :input, :map, required: true

  defp dropped_input(%{dup: %{details: %{"input" => new}}} = assigns) do
    assigns = assign(assigns, new: new, changes: diff(assigns.input || %{}, new))

    ~H"""
    <div class="flex flex-col gap-2.5">
      <dl class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-4 gap-y-1 font-mono text-xs">
        <%= for {path, old, new} <- @changes do %>
          <dt class="text-muted-foreground">{path}</dt>
          <dd class="min-w-0 break-all">
            <del :if={old != :none} class="text-destructive">{show(old)}</del>
            <span :if={old != :none and new != :none} class="text-muted-foreground"> → </span>
            <ins :if={new != :none} class="text-success no-underline">{show(new)}</ins>
          </dd>
        <% end %>
      </dl>
      <span class="group/copy inline-flex items-center gap-1.5 self-start text-xs text-subtle-foreground">
        <Core.copy_button text={Jason.encode!(@new, pretty: true)} label="Copy input" class="opacity-100" />
        Copy input
      </span>
    </div>
    """
  end

  defp dropped_input(assigns) do
    ~H"""
    <p class="text-xs text-muted-foreground">
      The newer input was over 16 KB, so it wasn't kept.
    </p>
    """
  end

  # Field-by-field changes between two inputs, by dotted path. `:none` marks
  # a field only one side has.
  @doc false
  def diff(old, new), do: compare(flatten(old), flatten(new))

  defp compare(old, new) do
    (Map.keys(old) ++ Map.keys(new))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      a = Map.get(old, path, :none)
      b = Map.get(new, path, :none)
      if a == b, do: [], else: [{path, a, b}]
    end)
  end

  defp flatten(map, prefix \\ nil) when is_map(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      path = if prefix, do: "#{prefix}.#{k}", else: to_string(k)

      if is_map(v) and v != %{},
        do: Map.merge(acc, flatten(v, path)),
        else: Map.put(acc, path, v)
    end)
  end

  defp show(value), do: Jason.encode!(value)

  attr :run, :map, required: true
  attr :info, :map, required: true
  attr :base_path, :string, required: true

  # The run's part in the key's history, in one sentence.
  defp history(%{run: %{holds_key: true}} = assigns) do
    assigns = assign(assigns, took: took(assigns.info, assigns.run.id))

    ~H"""
    Holds the key<span :if={@took}>
      · took it from <.run_link id={@took.details["from"]} base_path={@base_path} />
      <Core.relative_time at={@took.at} /></span>
    """
  end

  defp history(assigns) do
    %{run: run, info: info} = assigns

    assigns =
      assign(assigns,
        released:
          Enum.find(info.events, &(&1.kind == "key_released" and &1.workflow_id == run.id)),
        moved:
          Enum.find(
            info.events,
            &(&1.kind in ~w(key_handed_off key_retaken) and &1.details["from"] == run.id)
          )
      )

    ~H"""
    <%= cond do %>
      <% @released -> %>
        Released{if by = @released.details["by"], do: " by #{by}"} · <Core.relative_time at={@released.at} />
      <% @moved -> %>
        {moved_reason(@run)}, so the key moved to <.run_link id={@moved.workflow_id} base_path={@base_path} />
      <% true -> %>
        Doesn't hold the key
    <% end %>
    """
  end

  defp took(info, id),
    do:
      Enum.find(
        info.events,
        &(&1.workflow_id == id and &1.kind in ~w(key_handed_off key_retaken))
      )

  defp moved_reason(%{status: :failed, current_step: step}) when is_binary(step),
    do: "Failed at #{step}"

  defp moved_reason(%{status: status}), do: String.capitalize(status_word(status))

  defp reuse_tip(:after_close), do: "A finished run lets its key go to the next start"

  defp reuse_tip(:after_failure),
    do: "A completed run keeps its key · a failed or cancelled one lets it go"

  defp reuse_tip(:never), do: "A run keeps its key until it's released or pruned"
  defp reuse_tip(_), do: nil

  defp short(nil), do: "—"
  defp short(id), do: String.slice(id, 0, 8)

  defp short_node(nil), do: "—"
  defp short_node(node), do: node |> String.split("@") |> List.last() |> String.slice(0, 24)
end
