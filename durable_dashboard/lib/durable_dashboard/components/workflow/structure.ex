defmodule DurableDashboard.Components.Workflow.Structure do
  @moduledoc """
  A workflow's definition drawn as a flow, with the range's traffic through
  it — see `DESIGN.md` §6 "Structure map".

  Left to right: Start (runs started), one card per top-level step, End
  (how runs finished). The arrow into a card carries how many runs reached
  it; the card's bar is that count against runs started, with the share
  that gave up there in the failure color, so drop-off reads like a funnel.
  Parallel blocks list their steps, branches list their paths with the
  share of runs that took each. A compensation sits under the step it
  undoes. The slowest step and the one most runs gave up at are flagged.

  `build/3` is pure; `map/1` renders it.
  """

  use Phoenix.Component

  alias DurableDashboard.Components.Core
  alias DurableDashboard.Format
  alias DurableDashboard.Path, as: DPath
  alias DurableDashboard.Trace

  @hot_failure_share 0.05
  @slow_floor_ms 10

  @doc """
  `definition` from `__workflow_definition__/1`, `steps` from
  `Durable.Stats.step_performance/1`, `started` the runs started in the range.
  """
  def build(definition, steps, started) do
    stats = Map.new(steps, &{&1.step, &1})
    by_name = Map.new(definition.steps, &{&1.name, &1})

    nodes =
      definition.steps
      |> Enum.reject(&nested?/1)
      |> Enum.with_index(1)
      |> Enum.map(fn {step, index} -> step_node(step, index, stats, by_name) end)

    attached = for %{compensation: %{name: name}} <- nodes, do: name

    loose =
      definition.compensations
      |> Map.keys()
      |> Enum.map(&Atom.to_string/1)
      |> Enum.reject(&(&1 in attached))
      |> Enum.map(&compensation(&1, stats))

    peak = Enum.max([started | Enum.map(nodes, & &1.runs)])

    %{
      nodes: flag(nodes),
      loose_compensations: loose,
      started: started,
      peak: peak
    }
  end

  defp nested?(%{opts: opts}),
    do: Map.has_key?(opts, :parallel_id) or Map.has_key?(opts, :branch_id)

  defp step_node(%{type: :parallel} = step, index, stats, _by_name) do
    children =
      for name <- step.opts[:steps] || [] do
        name = Atom.to_string(name)
        leaf(name, stats[name])
      end

    %{
      base(step, index)
      | type: :parallel,
        label: "parallel",
        note:
          "#{length(children)} at once · #{humanize(step.opts[:error_strategy] || :fail_fast)}",
        runs: children |> Enum.map(& &1.runs) |> Enum.max(fn -> 0 end),
        failed_runs: children |> Enum.map(& &1.failed_runs) |> Enum.sum(),
        p95_ms:
          children |> Enum.map(& &1.p95_ms) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end),
        children: children
    }
    |> finish()
  end

  defp step_node(%{type: :branch} = step, index, stats, _by_name) do
    clauses =
      (step.opts[:clauses] || %{})
      |> Enum.sort_by(fn {{_value, position}, _names} -> position end)
      |> Enum.map(fn {{value, _position}, names} ->
        leaves = Enum.map(names, &leaf(Atom.to_string(&1), stats[Atom.to_string(&1)]))

        %{
          label: clause_label(value),
          steps: leaves,
          runs: leaves |> List.first(%{runs: 0}) |> Map.fetch!(:runs),
          failed_runs: leaves |> Enum.map(& &1.failed_runs) |> Enum.sum()
        }
      end)

    %{
      base(step, index)
      | type: :branch,
        label: "branch",
        note: "#{length(clauses)} paths",
        runs: clauses |> Enum.map(& &1.runs) |> Enum.sum(),
        failed_runs: clauses |> Enum.map(& &1.failed_runs) |> Enum.sum(),
        clauses: clauses
    }
    |> finish()
  end

  defp step_node(step, index, stats, by_name) do
    name = Atom.to_string(step.name)
    s = stats[name]

    %{
      base(step, index)
      | type: step.type,
        note: note(step),
        runs: (s && s.runs) || 0,
        failed_runs: (s && s.failed_runs) || 0,
        p95_ms: s && s.p95_ms,
        retried: s && s.runs > 0 && s.retried_runs / s.runs,
        compensation: compensation_for(step, stats, by_name)
    }
    |> finish()
  end

  defp base(step, index) do
    %{
      key: Atom.to_string(step.name),
      label: Trace.display_name(Atom.to_string(step.name)),
      index: index,
      type: :step,
      note: nil,
      runs: 0,
      failed_runs: 0,
      failed_share: 0.0,
      p95_ms: nil,
      retried: nil,
      children: [],
      clauses: [],
      compensation: nil,
      flags: []
    }
  end

  defp finish(node) do
    share = if node.runs > 0, do: min(node.failed_runs / node.runs, 1.0), else: 0.0
    %{node | failed_share: share}
  end

  defp leaf(name, nil),
    do: %{key: name, label: Trace.display_name(name), runs: 0, failed_runs: 0, p95_ms: nil}

  defp leaf(name, s),
    do: %{
      key: name,
      label: Trace.display_name(name),
      runs: s.runs,
      failed_runs: s.failed_runs,
      p95_ms: s.p95_ms
    }

  defp compensation_for(%{opts: %{compensate: comp}}, stats, _by_name) when not is_nil(comp),
    do: compensation(Atom.to_string(comp), stats)

  defp compensation_for(_step, _stats, _by_name), do: nil

  # Compensation attempts are recorded as `compensate_<name>`.
  defp compensation(name, stats) do
    s = stats["compensate_" <> name] || stats[name]
    %{name: name, runs: (s && s.runs) || 0, failed_runs: (s && s.failed_runs) || 0}
  end

  defp note(%{type: :decision, opts: opts}) do
    case opts[:branches] do
      [_ | _] = targets ->
        "may jump to " <> Enum.map_join(targets, ", ", &Trace.display_name(Atom.to_string(&1)))

      _ ->
        "decision"
    end
  end

  defp note(%{opts: %{retry: %{max_attempts: n} = retry}}),
    do: "up to #{n} attempts · #{retry[:backoff] || :exponential} backoff"

  defp note(_step), do: nil

  defp clause_label(:_), do: "otherwise"
  defp clause_label(value) when is_atom(value), do: Atom.to_string(value)
  defp clause_label(value) when is_binary(value), do: value
  defp clause_label(value), do: inspect(value)

  defp humanize(atom), do: atom |> Atom.to_string() |> String.replace("_", " ")

  # Flag the step that dominates run time (at least half the summed p95s, and
  # long enough to matter) and the one most runs gave up at. Ties for "slowest"
  # between 1 ms steps are noise, so they aren't flagged.
  defp flag(nodes) do
    ran = Enum.filter(nodes, &(&1.runs > 0))
    timed = Enum.filter(ran, & &1.p95_ms)
    total = timed |> Enum.map(& &1.p95_ms) |> Enum.sum()
    candidate = Enum.max_by(timed, & &1.p95_ms, fn -> nil end)

    slowest =
      if length(timed) > 1 and candidate.p95_ms >= @slow_floor_ms and
           candidate.p95_ms * 2 >= total,
         do: candidate

    worst =
      ran |> Enum.filter(&(&1.failed_runs > 0)) |> Enum.max_by(& &1.failed_runs, fn -> nil end)

    Enum.map(nodes, fn node ->
      flags =
        [
          worst && worst.key == node.key && :most_failures,
          slowest && slowest.key == node.key && :slowest
        ]
        |> Enum.filter(& &1)

      %{node | flags: flags}
    end)
  end

  # ============================================================================
  # Render
  # ============================================================================

  attr :structure, :map, required: true
  attr :finished, :map, required: true, doc: "`Stats.overview/1`'s `finished` counts"
  attr :base_path, :string, required: true
  attr :workflow, :string, required: true

  def map(assigns) do
    nodes = assigns.structure.nodes

    # Cards share the panel's width and only scroll once they hit their minimum.
    columns =
      Enum.map_join(nodes, " ", fn node ->
        "40px minmax(#{if node.type in [:parallel, :branch], do: 236, else: 168}px, 1fr)"
      end)

    assigns =
      assign(assigns,
        comps?: Enum.any?(nodes, & &1.compensation),
        columns: "grid-template-columns: max-content #{columns} 40px max-content"
      )

    ~H"""
    <div class="thin-scroll overflow-x-auto px-4 pb-4 pt-1">
      <div
        class={["grid grid-flow-col items-start", if(@comps?, do: "grid-rows-[auto_auto]", else: "grid-rows-1")]}
        style={@columns}
      >
        <.terminal
          label="Start"
          value={@structure.started}
          note="runs started"
          glyph="start"
          tip="Runs started in the window"
        />
        <div :if={@comps?}></div>

        <%= for node <- @structure.nodes do %>
          <.arrow runs={node.runs} into={node.label} />
          <div :if={@comps?}></div>
          <.card node={node} peak={@structure.peak} base_path={@base_path} workflow={@workflow} />
          <div :if={@comps?}><.comp_card :if={node.compensation} comp={node.compensation} /></div>
        <% end %>

        <.arrow runs={@finished[:completed] || 0} into="the end" />
        <div :if={@comps?}></div>
        <.terminal
          label="Completed"
          value={@finished[:completed] || 0}
          note={ending(@finished)}
          glyph="end"
          tip="Runs that finished every step · the rest failed, were rolled back or cancelled"
        />
        <div :if={@comps?}></div>
      </div>

      <p :if={@structure.loose_compensations != []} class="mt-3 text-xs text-muted-foreground">
        Also defined, not attached to a step:
        <span :for={c <- @structure.loose_compensations} class="ml-1.5 font-mono text-comp">↺ {c.name}</span>
      </p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :note, :string, required: true
  attr :glyph, :string, required: true
  attr :tip, :string, required: true

  defp terminal(assigns) do
    ~H"""
    <div class="flex max-w-[132px] flex-col gap-0.5 pt-2.5" data-tip-title={@label} data-tip={@tip}>
      <span class="flex items-center gap-1.5 text-xs font-medium text-subtle-foreground">
        <Core.status_dot :if={@glyph == "end"} status={:completed} />
        {@label}
      </span>
      <span class="font-mono text-xl font-medium tracking-tight">{Format.int(@value)}</span>
      <span class="text-xs leading-4 text-muted-foreground">{@note}</span>
    </div>
    """
  end

  attr :runs, :integer, required: true
  attr :into, :string, required: true

  defp arrow(assigns) do
    ~H"""
    <div
      class="flex flex-col items-center gap-0.5 pt-[11px]"
      data-tip-title={"Into #{@into}"}
      data-tip={"#{Format.int(@runs)} runs got this far"}
    >
      <span class="font-mono text-[11px] text-subtle-foreground">{Format.int(@runs)}</span>
      <svg viewBox="0 0 28 8" class="h-2 w-7 text-muted-foreground/60" aria-hidden="true">
        <path d="M0 4h24M20 1l4 3-4 3" fill="none" stroke="currentColor" stroke-width="1.25" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
    </div>
    """
  end

  attr :node, :map, required: true
  attr :peak, :integer, required: true
  attr :base_path, :string, required: true
  attr :workflow, :string, required: true

  defp card(assigns) do
    assigns = assign(assigns, hot?: assigns.node.failed_share > @hot_failure_share)

    ~H"""
    <article class={[
      "flex min-w-0 flex-col rounded-[10px] border bg-card px-3 pb-3 pt-2.5",
      if(@hot?, do: "border-destructive/55", else: "border-input")
    ]}>
      <header
        class="flex min-w-0 items-center gap-1.5"
        data-tip-title={@node.label}
        data-tip={kind_help(@node.type, @node.index)}
        data-tip-meta={@node.key}
      >
        <.kind type={@node.type} />
        <span class={[
          "truncate text-[13px] font-medium",
          if(@node.type in [:parallel, :branch], do: "text-subtle-foreground", else: "font-mono")
        ]}>
          {@node.label}
        </span>
      </header>
      <p :if={@node.note} class="mt-0.5 text-xs text-muted-foreground">{@node.note}</p>
      <p :if={@node.flags != []} class="mt-1.5 flex flex-wrap gap-1">
        <span
          :if={:most_failures in @node.flags}
          data-tip={"More runs give up at this step than at any other · #{Format.pct(@node.failed_share)} of those that reach it"}
        >
          <Core.badge kind="destructive">Most give up here</Core.badge>
        </span>
        <span
          :if={:slowest in @node.flags}
          data-tip={"Its p95 (#{Format.ms(@node.p95_ms)}) is over half of all the steps' p95s added up"}
        >
          <Core.badge kind="warning">Slowest</Core.badge>
        </span>
      </p>

      <.children :if={@node.children != []} children={@node.children} />
      <.clauses :if={@node.clauses != []} clauses={@node.clauses} total={@node.runs} />

      <div :if={@node.runs > 0} class="mt-2.5 flex flex-col gap-0.5 text-xs">
        <p class="flex flex-wrap items-baseline gap-x-3">
          <span class="whitespace-nowrap" data-tip="Runs that reached this step in the window">
            <span class="font-mono text-[13px] font-medium">{Format.int(@node.runs)}</span>
            <span class="text-muted-foreground">reached</span>
          </span>
          <span
            :if={@node.p95_ms}
            class="whitespace-nowrap text-muted-foreground"
            data-tip="95% of the attempts at it took less"
          >
            p95 <span class="font-mono text-foreground">{Format.ms(@node.p95_ms)}</span>
          </span>
        </p>
        <p class="flex flex-wrap items-baseline gap-x-3">
          <.link
            :if={@node.failed_runs > 0}
            navigate={failed_runs_path(@base_path, @workflow, @node.key)}
            class={["whitespace-nowrap hover:underline", if(@hot?, do: "text-destructive", else: "text-subtle-foreground")]}
            data-tip-title={"#{Format.int(@node.failed_runs)} gave up here"}
            data-tip={"Ran out of attempts at this step · #{Format.pct(@node.failed_share)} of the runs that reached it\nOpen those runs"}
          >
            <span class="font-mono">{Format.int(@node.failed_runs)}</span> gave up · {Format.pct(@node.failed_share)}
          </.link>
          <span :if={@node.failed_runs == 0} class="text-muted-foreground">none gave up</span>
          <span
            :if={@node.retried && @node.retried > 0}
            class="whitespace-nowrap text-muted-foreground"
            data-tip="Runs that needed more than one attempt at it"
          >
            <span class="font-mono text-warning">{Format.pct(@node.retried)}</span> retried
          </span>
        </p>
      </div>
      <p :if={@node.runs == 0} class="mt-2.5 text-xs text-muted-foreground">No runs reached it.</p>

      <.traffic runs={@node.runs} failed={@node.failed_runs} peak={@peak} />
    </article>
    """
  end

  attr :children, :list, required: true

  defp children(assigns) do
    assigns =
      assign(assigns,
        top: assigns.children |> Enum.map(&(&1.p95_ms || 0)) |> Enum.max(fn -> 0 end)
      )

    ~H"""
    <ul class="mt-2 flex flex-col gap-1.5 border-l border-input pl-2.5">
      <li
        :for={c <- @children}
        class="flex flex-col gap-0.5"
        data-tip-title={c.label}
        data-tip={"p95 #{Format.ms(c.p95_ms)} · #{Format.int(c.failed_runs)} gave up\nThe bar: its p95 against the slowest step in the block"}
        data-tip-meta={c.key}
      >
        <span class="flex items-baseline gap-2 text-xs">
          <span class="truncate font-mono">{c.label}</span>
          <span :if={c.failed_runs > 0} class="font-mono text-destructive">{c.failed_runs} gave up</span>
          <span class="ml-auto shrink-0 font-mono text-subtle-foreground">{Format.ms(c.p95_ms)}</span>
        </span>
        <span class="h-1 rounded-full bg-secondary">
          <span class="block h-1 rounded-full bg-subtle-foreground/45" style={"width: #{pct(c.p95_ms || 0, @top)}%"}></span>
        </span>
      </li>
    </ul>
    """
  end

  attr :clauses, :list, required: true
  attr :total, :integer, required: true

  defp clauses(assigns) do
    ~H"""
    <ul class="mt-2 flex flex-col gap-1.5">
      <li
        :for={c <- @clauses}
        class="grid grid-cols-[64px_minmax(0,1fr)_auto] items-center gap-2 text-xs"
        data-tip-title={if c.label == "otherwise", do: "Otherwise", else: "When it's #{c.label}"}
        data-tip={"#{Format.int(c.runs)} of #{Format.int(@total)} runs took this path"}
        data-tip-meta={Enum.map_join(c.steps, " → ", & &1.label)}
      >
        <span class="truncate rounded-[5px] bg-secondary px-1.5 py-0.5 text-center font-mono text-[11px]">{c.label}</span>
        <span class="flex min-w-0 flex-col gap-0.5">
          <span class="truncate font-mono text-subtle-foreground">
            {Enum.map_join(c.steps, " → ", & &1.label)}
          </span>
          <span class="h-1 rounded-full bg-secondary">
            <span class="block h-1 rounded-full bg-chart-ok" style={"width: #{pct(c.runs, @total)}%"}></span>
          </span>
        </span>
        <span class="font-mono text-subtle-foreground">{Format.pct(if @total > 0, do: c.runs / @total, else: 0)}</span>
      </li>
    </ul>
    """
  end

  attr :runs, :integer, required: true
  attr :failed, :integer, required: true
  attr :peak, :integer, required: true

  defp traffic(assigns) do
    ~H"""
    <div
      class="mt-3 flex h-1.5 overflow-hidden rounded-full bg-secondary"
      data-tip-title="Traffic"
      data-tip={"Green reached it, red gave up · the width is against the busiest step (#{Format.int(@peak)} runs)"}
    >
      <div class="flex h-full gap-px" style={"width: #{pct(@runs, @peak)}%"}>
        <span class="h-full flex-1 bg-chart-ok"></span>
        <span :if={@failed > 0} class="h-full bg-chart-fail" style={"width: #{pct(@failed, @runs)}%"}></span>
      </div>
    </div>
    """
  end

  attr :comp, :map, required: true

  defp comp_card(assigns) do
    ~H"""
    <div class="flex flex-col items-start">
      <span class="ml-5 h-4 border-l border-dashed border-comp/70" aria-hidden="true"></span>
      <div
        class="w-full rounded-[10px] border border-comp/45 bg-comp/5 px-3.5 py-2.5"
        data-tip-title={"Compensation #{@comp.name}"}
        data-tip={"Undoes the step above when a later step fails · ran #{Format.int(@comp.runs)}×, #{Format.int(@comp.failed_runs)} failed"}
      >
        <span class="flex items-center gap-1.5 font-mono text-[13px] font-medium text-comp">
          <span aria-hidden="true">↺</span>{@comp.name}
        </span>
        <span class="text-xs text-muted-foreground">
          runs if a later step fails · ran {Format.int(@comp.runs)}×<span :if={@comp.failed_runs > 0} class="text-destructive">, {@comp.failed_runs} failed</span>
        </span>
      </div>
    </div>
    """
  end

  attr :type, :atom, required: true

  defp kind(assigns) do
    ~H"""
    <svg viewBox="0 0 12 12" class="size-3 shrink-0 text-muted-foreground" aria-label={kind_label(@type)} role="img">
      <%= case @type do %>
        <% :decision -> %>
          <path d="M6 1.5 10.5 6 6 10.5 1.5 6Z" fill="none" stroke="currentColor" stroke-width="1.2" />
        <% :parallel -> %>
          <path d="M1.5 6h2.5M4 6 8 2.5M4 6h6.5M4 6l4 3.5" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" />
        <% :branch -> %>
          <path d="M1.5 6h3M4.5 6 8 3h2.5M4.5 6 8 9h2.5" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round" />
        <% _ -> %>
          <circle cx="6" cy="6" r="3.5" fill="none" stroke="currentColor" stroke-width="1.2" />
      <% end %>
    </svg>
    """
  end

  defp kind_help(:decision, index),
    do: "Step #{index} · a decision: what it returns picks the next step"

  defp kind_help(:parallel, index),
    do: "Step #{index} · a parallel block: its steps run at once, and it waits for them all"

  defp kind_help(:branch, index),
    do: "Step #{index} · a branch: one of its paths runs, picked by a value"

  defp kind_help(_type, index), do: "Step #{index}"

  defp kind_label(:decision), do: "decision"
  defp kind_label(:parallel), do: "parallel"
  defp kind_label(:branch), do: "branch"
  defp kind_label(_type), do: "step"

  defp ending(finished) do
    failed = Enum.sum(for k <- [:failed, :compensation_failed], do: finished[k] || 0)

    [
      failed > 0 && "#{Format.int(failed)} failed",
      (finished[:compensated] || 0) > 0 && "#{Format.int(finished[:compensated])} rolled back",
      (finished[:cancelled] || 0) > 0 && "#{Format.int(finished[:cancelled])} cancelled"
    ]
    |> Enum.filter(& &1)
    |> case do
      [] -> "none failed"
      parts -> Enum.join(parts, " · ")
    end
  end

  defp failed_runs_path(base_path, workflow, step) do
    DPath.workflow_executions(base_path, workflow) <>
      "?" <> URI.encode_query(status: "failed,compensated,compensation_failed", q: "step:#{step}")
  end

  defp pct(_value, top) when top in [0, nil], do: 0
  defp pct(value, top), do: Float.round(min(value / top * 100, 100.0), 2)
end
