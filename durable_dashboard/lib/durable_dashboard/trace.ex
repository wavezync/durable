defmodule DurableDashboard.Trace do
  @moduledoc """
  Builds the run page's trace waterfall from step executions.

  One row per step — the run's own steps plus those of its direct child runs
  (parallel branches, called workflows), indented one level. Each attempt is a
  bar positioned on the run's wall-clock window. The time between attempts is
  drawn as a gap: **backoff** after a failed attempt, **wait** after a
  suspension (sleep, event, input). Compensations sort last, in their own
  lane. See `DESIGN.md` §6 "Run page".

  Pure: `build/4` is the whole API.
  """

  @live_statuses [:pending, :running, :waiting, :compensating]

  @doc """
  Returns `%{rows: [row], ticks: [%{pct, label}], span_ms: integer, live?: boolean}`.

  `child_ids` are the ids of the run's direct child runs; their steps are
  included as depth-1 rows.
  """
  def build(run, steps, child_ids, now) do
    family = MapSet.new([run.id | child_ids])
    steps = Enum.filter(steps, &MapSet.member?(family, &1.workflow_id))
    live? = run.status in @live_statuses
    started = Enum.filter(steps, & &1.started_at)

    if started == [] do
      %{rows: rows(steps, run, nil), ticks: [], span_ms: 0, live?: live?}
    else
      start = started |> Enum.map(& &1.started_at) |> Enum.min(DateTime)

      finish =
        if live?,
          do: now,
          else: steps |> Enum.map(&last_moment/1) |> Enum.reject(&is_nil/1) |> Enum.max(DateTime)

      span_ms = max(DateTime.diff(finish, start, :millisecond), 1)
      window = %{start: start, span_ms: span_ms, now: now, live?: live?}

      %{rows: rows(steps, run, window), ticks: ticks(span_ms), span_ms: span_ms, live?: live?}
    end
  end

  defp rows(steps, run, window) do
    steps
    |> Enum.group_by(&{&1.workflow_id, &1.step_name})
    |> Enum.map(fn {{workflow_id, name}, execs} ->
      execs = Enum.sort_by(execs, & &1.inserted_at, DateTime)
      row(run, workflow_id, name, execs, window)
    end)
    |> Enum.sort_by(fn row ->
      {row.compensation?, row.first_at && DateTime.to_unix(row.first_at, :microsecond)}
    end)
  end

  defp row(run, workflow_id, name, execs, window) do
    latest = List.last(execs)
    attempts = Enum.reject(execs, &(&1.status == :waiting))

    %{
      key: hd(execs).id,
      ids: Enum.map(execs, & &1.id),
      name: display_name(name),
      raw_name: name,
      workflow_id: workflow_id,
      depth: if(workflow_id == run.id, do: 0, else: 1),
      compensation?: latest.is_compensation == true,
      step_type: latest.step_type,
      status: latest.status,
      attempts: length(attempts),
      duration_ms: attempts |> Enum.map(&(&1.duration_ms || 0)) |> Enum.sum(),
      child_workflow_id: Enum.find_value(execs, & &1.child_workflow_id),
      first_at: hd(execs).started_at || hd(execs).inserted_at,
      execs: execs,
      latest: latest,
      segments: if(window, do: segments(execs, window), else: [])
    }
  end

  # A bar per attempt plus the gap that follows it: backoff after a failure,
  # wait after a suspension (running on to `now` while the run is live).
  defp segments(execs, window) do
    execs
    |> Enum.filter(& &1.started_at)
    |> Enum.chunk_every(2, 1)
    |> Enum.flat_map(fn
      [exec, next] ->
        bar(exec, window) ++ gap(exec, end_at(exec, window), next.started_at, window)

      [exec] ->
        bar(exec, window) ++ trailing_gap(exec, window)
    end)
  end

  defp bar(%{status: :waiting}, _window), do: []

  defp bar(exec, window) do
    kind =
      case exec.status do
        :completed -> if(exec.is_compensation, do: :comp, else: :ok)
        :failed -> :fail
        :running -> :running
        _ -> :other
      end

    [
      segment(kind, exec.started_at, end_at(exec, window), window, %{
        title: "Attempt #{exec.attempt} · #{exec.status}",
        meta: exec.error && error_parts(exec.error).message
      })
    ]
  end

  @backoff %{title: "Backoff", note: "the pause before the next attempt"}
  @wait %{title: "Waiting", note: "suspended until a sleep, event or input resumes it"}

  defp gap(%{status: :failed}, from, to, window),
    do: [segment(:backoff, from, to, window, @backoff)]

  defp gap(%{status: :waiting}, from, to, window),
    do: [segment(:wait, from, to, window, @wait)]

  defp gap(_exec, _from, _to, _window), do: []

  defp trailing_gap(%{status: :waiting} = exec, %{live?: true} = window),
    do: [segment(:wait, end_at(exec, window), window.now, window, @wait)]

  defp trailing_gap(_exec, _window), do: []

  defp end_at(%{completed_at: %DateTime{} = at}, _window), do: at
  defp end_at(%{status: :running}, %{live?: true, now: now}), do: now
  defp end_at(exec, _window), do: exec.updated_at || exec.started_at

  # `title`, `tip` and `meta` feed the bar's tooltip: what it is, when it ran
  # relative to the run's start, and (for a failed attempt) its error.
  defp segment(kind, from, to, window, about) do
    offset = DateTime.diff(from, window.start, :millisecond)
    length = max(DateTime.diff(to, from, :millisecond), 0)
    span = "+#{format_ms(offset)} → +#{format_ms(offset + length)} · #{format_ms(length)}"

    %{
      kind: kind,
      left: pct(offset, window.span_ms),
      width: pct(length, window.span_ms),
      title: about.title,
      tip: Enum.join(List.wrap(about[:note]) ++ [span], "\n"),
      meta: about[:meta]
    }
  end

  defp pct(part, span), do: Float.round(min(max(part / span * 100, 0.0), 100.0), 2)

  defp last_moment(step), do: step.completed_at || step.updated_at || step.started_at

  # Parallel and branch steps are stored with a macro qualifier
  # (`parallel_ab12__left`); show the name the user wrote.
  @doc """
  What a step returned. A parallel child stores its result wrapped
  (`__output__` / `__context__` / `__result__`, all the same data) so the
  block can resume; show the data, not the envelope.
  """
  def returned(%{"__output__" => output}), do: output
  def returned(output), do: output

  @doc false
  def display_name(name) when is_binary(name) do
    case String.split(name, "__") do
      [_prefix, _clause, step] -> step
      [_prefix, step] -> step
      [block] -> Regex.replace(~r/^(parallel|branch)_\d+$/, block, "\\1")
      _ -> name
    end
  end

  def display_name(name), do: to_string(name)

  @nice_ms [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_000, 5_000, 10_000, 15_000, 30_000] ++
             [60_000, 120_000, 300_000, 600_000, 900_000, 1_800_000, 3_600_000] ++
             [7_200_000, 21_600_000, 43_200_000, 86_400_000]

  defp ticks(span_ms) do
    step = Enum.find(@nice_ms, List.last(@nice_ms), &(div(span_ms, &1) <= 5))

    0
    |> Stream.iterate(&(&1 + step))
    |> Enum.take_while(&(&1 <= span_ms))
    |> Enum.map(&%{pct: pct(&1, span_ms), label: format_ms(&1)})
  end

  @doc "Formats milliseconds as `850ms`, `1.2s`, `3m 05s`, `2h 10m`."
  def format_ms(nil), do: "—"
  def format_ms(ms) when ms < 1_000, do: "#{ms}ms"
  def format_ms(ms) when ms < 10_000, do: "#{:erlang.float_to_binary(ms / 1_000, decimals: 2)}s"
  def format_ms(ms) when ms < 60_000, do: "#{:erlang.float_to_binary(ms / 1_000, decimals: 1)}s"

  def format_ms(ms) when ms < 3_600_000,
    do: "#{div(ms, 60_000)}m #{String.pad_leading("#{div(rem(ms, 60_000), 1_000)}", 2, "0")}s"

  def format_ms(ms), do: "#{div(ms, 3_600_000)}h #{div(rem(ms, 3_600_000), 60_000)}m"

  @library_apps ~w(durable elixir stdlib kernel ecto ecto_sql postgrex db_connection phoenix
                   phoenix_live_view plug bandit cowboy jason telemetry)

  @doc """
  Splits a stored step error into `%{type, message, details, frames}`.

  Raised exceptions are stored as `type`/`message`/`stacktrace`; a step that
  returns `{:error, map}` stores whatever map it returned, so `type` may be
  nil, `message` falls back to `reason`, and any other fields are `details`.
  Frames from the host app are `app?: true`; library frames are dimmed.
  """
  def error_parts(nil), do: nil

  def error_parts(error) when is_map(error) do
    error = Map.new(error, fn {k, v} -> {to_string(k), v} end)

    frames =
      (error["stacktrace"] || "")
      |> to_string()
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.map(&frame/1)

    message = error["message"] || error["reason"]
    details = Map.drop(error, ["type", "message", "reason", "stacktrace"])

    %{
      type: error["type"] && to_string(error["type"]),
      message: if(message, do: to_string(message), else: Jason.encode!(details)),
      details: if(message && details != %{}, do: details),
      frames: frames
    }
  end

  def error_parts(error), do: %{type: nil, message: inspect(error), details: nil, frames: []}

  # "(my_app 0.1.0) lib/my_app/carrier.ex:48: MyApp.Carrier.ship/2" — the app
  # is optional; a line that isn't a frame is kept as it is.
  @frame ~r/^(?:\((?<app>[^\s)]+)[^)]*\)\s+)?(?<file>[^\s:]+):(?<line>\d+):\s+(?<function>.+)$/

  defp frame(text) do
    case Regex.named_captures(@frame, text) do
      %{"app" => app, "file" => file, "line" => line, "function" => function} ->
        %{
          text: text,
          app?: app not in @library_apps,
          app: if(app == "", do: nil, else: app),
          where: "#{file}:#{line}",
          function: readable(function)
        }

      nil ->
        %{text: text, app?: true, app: nil, where: nil, function: text}
    end
  end

  # The DSL compiles each step, decision, compensation, branch `on:` and
  # parallel `into:` to a generated function; name it the way it was written:
  # "MyApp.Orders.__step_body_charge__/1" → "Orders · step :charge".
  @generated ~r/(?:([\w.]+)\.)?__(step_body|decision_body|compensate_body|branch_condition|parallel_into)_(\w+?)__\/\d+/

  defp readable(function) do
    Regex.replace(@generated, function, fn _all, module, kind, name ->
      prefix = if module == "", do: "", else: "#{module |> String.split(".") |> List.last()} · "
      prefix <> written(kind, name)
    end)
  end

  defp written("step_body", name), do: "step :#{display_name(name)}"
  defp written("decision_body", name), do: "decision :#{name}"
  defp written("compensate_body", name), do: "compensation :#{name}"
  defp written("branch_condition", _id), do: "branch on:"
  defp written("parallel_into", _id), do: "parallel into:"
end
