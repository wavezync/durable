Code.require_file("../audit4_support_test.exs", __DIR__)

defmodule Audit4Dash.Chaos do
  @moduledoc """
  One workflow whose first step does whatever its input's `"mode"` names:
  every shape of failure, cancel, snooze and wait a host app's step can
  produce, each carrying a string a browser would run if it weren't escaped.
  """
  use Durable
  use Durable.Wait

  @xss ~s|<script>alert("x")</script><img src=x onerror=alert(1)>'"&|
  def xss, do: @xss

  def result("err_type_int"), do: {:error, %{type: 5, message: 7}}
  def result("err_string"), do: {:error, @xss}
  def result("err_atom"), do: {:error, :boom}
  def result("err_tuple"), do: {:error, {:http, 500, @xss}}
  def result("err_nil"), do: {:error, nil}
  def result("err_struct"), do: {:error, %ArgumentError{message: @xss}}
  def result("err_empty"), do: {:error, %{}}
  def result("err_details"), do: {:error, %{message: @xss, code: 503, body: %{@xss => [1, @xss]}}}
  def result("raise"), do: raise(@xss)
  def result("throw"), do: throw({:x, @xss})
  def result("exit"), do: exit({:shutdown, @xss})
  def result("ok_not_a_map"), do: {:ok, [1, @xss]}
  def result("bad_return"), do: :whatever

  def result("ok_nested"),
    do: {:ok, %{@xss => @xss, t: {1, 2}, d: ~D[2026-01-01], a: :atom, f: 1.0e308, n: nil}}

  def result("cancel_map"), do: {:cancel, %{"why" => @xss}}
  def result("cancel_xss"), do: {:cancel, @xss}
  def result("snooze_map"), do: {:snooze, 60_000, %{"why" => @xss}}
  def result("snooze_xss"), do: {:snooze, 60_000, @xss}

  def result("form_odd") do
    wait_for_form("f",
      prompt: @xss,
      fields: [
        %{name: @xss, type: :number, label: @xss},
        %{type: :weird},
        %{name: :b, type: :boolean, required: true},
        %{name: :s, type: :select, options: [1, :a, @xss]}
      ]
    )
  end

  def result("form_nofields"), do: wait_for_form("f", [])

  def result("choice_maps"),
    do:
      wait_for_choice("c",
        choices: [%{value: :express, label: @xss}, %{value: 5}, %{label: "no value"}]
      )

  def result("choice_none"), do: wait_for_choice("c", [])

  def result("multi") do
    wait_for_input("m",
      type: :multi_choice,
      fields: [%{value: "a", label: "A"}],
      metadata: %{@xss => %{deep: [1, @xss]}},
      timeout: 1000,
      timeout_value: {:t, 1}
    )
  end

  def result("text"), do: wait_for_text("t", prompt: String.duplicate(@xss, 200))

  def result("approval") do
    wait_for_approval(@xss,
      prompt: nil,
      metadata: %{amount: 1.5, list: [1], nested: %{a: @xss}},
      timeout: 1000,
      timeout_value: :auto
    )
  end

  def result("event"), do: wait_for_event(@xss, timeout: 1000, timeout_value: %{@xss => 1})
  def result("any"), do: wait_for_any([@xss, "b"])
  def result("all"), do: wait_for_all(["a", "b"], timeout: 5)
  def result("sleep"), do: sleep(3_600_000)
  def result(_mode), do: {:ok, %{}}

  def modes do
    ~w(err_type_int err_string err_atom err_tuple err_nil err_struct err_empty err_details
       raise throw exit ok_not_a_map bad_return ok_nested cancel_map cancel_xss snooze_map
       snooze_xss form_odd form_nofields choice_maps choice_none multi text approval event
       any all sleep)
  end

  workflow "audit4_chaos" do
    step :go, fn data ->
      case Audit4Dash.Chaos.result(data["mode"]) do
        {tag, _} = result when tag in [:ok, :error, :cancel] -> result
        {:snooze, _, _} = result -> result
        :whatever -> :whatever
        _answer -> {:ok, data}
      end
    end

    step :after, fn data -> {:ok, data} end
  end
end

defmodule Audit4Dash.Lanes do
  @moduledoc "A named parallel block where one lane fails while the others are still going."
  use Durable
  use Durable.Wait

  workflow "audit4_lanes" do
    step :prepare, fn data -> {:ok, data} end

    parallel :lookups do
      step :credit, fn _data -> raise "credit bureau down" end

      lane :sanctions do
        step :query, fn data ->
          _ = wait_for_event("sanctions_result")
          {:ok, data}
        end

        step :file, fn data -> {:ok, data} end
      end

      step :device, fn data -> {:ok, data} end
    end

    step :decide, fn data -> {:ok, data} end
  end
end

defmodule DurableDashboard.Live.Audit4SmokeTest do
  @moduledoc """
  Hardening: every page, and every view of every run, mounts — connected, not
  just the static render — against runs in every state, with hostile values in
  every column a host app or its users can write, and never emits one of
  those values unescaped. The shapes that do crash a page today are pinned in
  `audit4_known_bugs_test.exs` and left out here.
  """
  use DurableDashboard.LiveCase

  import Ecto.Query

  alias Audit4Dash.Chaos
  alias Durable.Storage.Schemas.{PendingInput, StepExecution, WorkflowExecution}

  @endpoint Audit4Dash.Endpoint

  @views ~w(trace graph logs context family key summary flow io nonsense)
  @panes ~w(error input output attempts logs nonsense)

  setup_all do
    start_supervised!(Audit4Dash.Endpoint)
    :ok
  end

  defp repo, do: DurableDashboard.TestRepo

  # nil when `path` mounts and renders clean, else what went wrong.
  defp problem(conn, path) do
    case live(conn, path) do
      {:ok, view, html} ->
        connected = render(view)

        cond do
          html =~ "<script>alert" or connected =~ "<script>alert" -> :unescaped_script
          html =~ "<img src=x" or connected =~ "<img src=x" -> :unescaped_tag
          true -> nil
        end

      other ->
        {:not_live, other}
    end
  rescue
    e -> Exception.format_banner(:error, e, __STACKTRACE__) |> String.slice(0, 300)
  catch
    kind, reason -> {kind, reason}
  end

  defp problems(conn, paths) do
    for path <- paths, problem = problem(conn, dash(path)), do: {path, problem}
  end

  defp run_paths(id) do
    steps = repo().all(from(s in StepExecution, where: s.workflow_id == ^id, select: s.id))

    ["/executions/#{id}"] ++
      for(view <- @views, do: "/executions/#{id}/#{view}") ++
      for sid <- Enum.take(steps, 4), pane <- @panes, view <- ~w(trace graph) do
        "/executions/#{id}/#{view}?step=#{sid}&pane=#{pane}"
      end
  end

  defp insert_run(attrs) do
    defaults = %{workflow_module: "Elixir.Audit4Dash.Gone", workflow_name: "gone_workflow"}
    repo().insert!(struct(WorkflowExecution, Map.merge(defaults, Map.new(attrs)))).id
  end

  defp insert_step(run_id, attrs) do
    defaults = %{workflow_id: run_id, step_name: "step"}
    repo().insert!(struct(StepExecution, Map.merge(defaults, Map.new(attrs)))).id
  end

  @list_pages ~w(/ /workflows /executions /inputs /inputs?tab=events /inputs?tab=sleep /keys
                 /queues /schedules /telemetry /settings)

  test "runs made by real workflows, in every outcome a step can produce", %{conn: conn} do
    ids = for mode <- Chaos.modes(), do: Fixtures.run!(Chaos, %{"mode" => mode})
    lanes = Fixtures.run_family!(Audit4Dash.Lanes)
    seeded = Map.values(Fixtures.seed!())

    statuses = ids |> Enum.map(&Fixtures.get_run!(&1).status) |> Enum.uniq() |> Enum.sort()
    assert statuses == [:cancelled, :completed, :failed, :pending, :waiting]

    children =
      repo().all(
        from(w in WorkflowExecution, where: w.parent_workflow_id == ^lanes, select: w.id)
      )

    assert children != []

    paths =
      Enum.flat_map(ids ++ [lanes] ++ children ++ seeded, &run_paths/1) ++
        @list_pages ++
        ~w(/workflows/audit4_chaos /workflows/audit4_chaos/runs /workflows/audit4_lanes
           /executions?parent=#{lanes} /executions?status=failed,cancelled,waiting,pending)

    assert problems(conn, paths) == []
  end

  test "rows no workflow could have written: every status, odd timestamps, a module that's gone",
       %{conn: conn} do
    xss = Chaos.xss()
    now = DateTime.utc_now()
    earlier = DateTime.add(now, -60, :second)

    by_status =
      for status <- Ecto.Enum.values(WorkflowExecution, :status) do
        id =
          insert_run(
            status: status,
            workflow_name: "gone_#{status}",
            input: %{"x" => xss, xss => [1, 2.5, nil, true, %{"deep" => xss}]},
            context: %{"__engine" => xss, "k" => %{xss => xss}},
            error: %{"message" => xss, "type" => xss, "stacktrace" => xss, "odd" => [1]},
            current_step: xss,
            # Finished before it started.
            started_at: now,
            completed_at: earlier,
            scheduled_at: earlier,
            deadline_at: earlier,
            key: "#{xss}:#{status}",
            holds_key: true,
            tags: [xss, "a:b"],
            trigger: :schedule,
            trigger_ref: xss,
            locked_by: xss,
            queue: xss
          )

        insert_step(id,
          step_name: xss,
          status: :failed,
          error: %{"message" => xss, "stacktrace" => 5},
          started_at: now,
          completed_at: earlier,
          duration_ms: -5,
          logs: [%{"message" => xss, "level" => xss, "timestamp" => "never"}, %{}],
          input: %{"a" => xss},
          output: %{"__value__" => xss}
        )

        insert_step(id, step_name: "parallel_1__x", status: :running, completed_at: now)
        insert_step(id, step_name: "y", status: :completed, logs: nil, attempt: -1)

        insert_step(id,
          step_name: "undo",
          status: :snoozed,
          is_compensation: true,
          compensation_for: "no_such_step",
          error: %{"reason" => 1}
        )

        id
      end

    no_steps = insert_run(status: :running)
    no_error = insert_run(status: :failed, error: nil)
    timed_out = insert_run(status: :failed, error: %{"type" => "timeout"}, deadline_at: earlier)

    many = insert_run(status: :completed, started_at: earlier, completed_at: now)

    repo().insert_all(
      StepExecution,
      for i <- 1..300 do
        %{
          id: Ecto.UUID.generate(),
          workflow_id: many,
          step_name: "step_#{i}",
          status: :completed,
          started_at: earlier,
          completed_at: now,
          duration_ms: i,
          logs: [%{"message" => "line #{i}", "level" => "info"}],
          inserted_at: now,
          updated_at: now
        }
      end
    )

    root = insert_run(status: :waiting)

    family =
      Enum.reduce(1..6, [root], fn _depth, [parent | _] = acc ->
        child =
          insert_run(
            status: :running,
            parent_workflow_id: parent,
            root_workflow_id: root,
            trigger: :parent
          )

        [child | acc]
      end)

    # A real definition under a module name that isn't a workflow, and one that isn't a module.
    not_a_workflow = Fixtures.run!(Fixtures.Payments, %{"decline" => true})
    not_a_module = Fixtures.run!(Fixtures.Payments)

    repo().update_all(from(w in WorkflowExecution, where: w.id == ^not_a_workflow),
      set: [workflow_module: "Elixir.Enum", workflow_name: xss]
    )

    repo().update_all(from(w in WorkflowExecution, where: w.id == ^not_a_module),
      set: [workflow_module: "not a module", workflow_name: ""]
    )

    for type <- Ecto.Enum.values(PendingInput, :input_type) do
      run = insert_run(status: :waiting, current_step: "ask")

      repo().insert!(%PendingInput{
        workflow_id: run,
        input_name: xss,
        step_name: "ask",
        input_type: type,
        prompt: xss,
        fields: nil,
        schema: %{"x" => xss},
        metadata: %{xss => xss},
        timeout_at: earlier,
        timeout_value: %{"__value__" => xss}
      })
    end

    runs =
      by_status ++ [no_steps, no_error, timed_out, many, not_a_workflow, not_a_module] ++ family

    paths =
      Enum.flat_map(runs, &run_paths/1) ++
        @list_pages ++
        ~w(/workflows/gone_workflow /workflows/gone_failed /workflows/gone_workflow/runs
           /executions?parent=#{root} /keys?status=failed,compensating) ++
        ["/workflows/" <> URI.encode_www_form(xss), "/schedules/" <> URI.encode_www_form(xss)]

    assert problems(conn, paths) == []
  end

  test "garbage in the URL falls back to a page, never a crash", %{conn: conn} do
    ids = Fixtures.seed!()
    Fixtures.schedule!("card_sweep")
    run = ids.family
    unknown = Ecto.UUID.generate()
    xss = URI.encode_www_form(Chaos.xss())

    paths =
      ~w(/inputs?tab=bogus /inputs?id=nope /inputs?id=#{unknown}
         /executions?page=-1 /executions?page=abc /executions?page=1e9 /executions?page=0
         /executions?page=5000 /executions?page=368934881474191032
         /executions?status=bogus,failed /executions?range=bogus /executions?from=x&to=y
         /executions?from=9999-99-99T99:99 /executions?from=2026-01-01T00:00&to=2020-01-01T00:00
         /executions?parent=nope /executions?parent=#{unknown} /executions?workflow=nope
         /executions?q=%25 /executions?q=_ /executions?q=%5C /executions?q=%00 /executions?q=id:
         /executions?q=input.:x /executions?q=input.a.b.c:x /executions?q=tag:%00
         /executions?q=key:%25 /executions?q=step:%27%3B+drop /executions?q=schedule:%00
         /executions?workflow=%00 /executions?q=input.%00:1 /executions?q=id:zzzz
         /executions?q=---- /executions?q=%22 /executions?q=a:%22
         /keys?page=-1 /keys?page=abc /keys?q=%25 /keys?q=%00 /keys?status=bogus
         /keys?workflow=%00 /workflows?range=bogus /?range=%00
         /workflows/nope /workflows/%25 /workflows/process_payment?range=zzz
         /schedules/nope /schedules/%00 /schedules/%25
         /executions/nope /executions/%00 /executions/#{unknown} /executions/#{unknown}/graph
         /executions/#{String.upcase(run)} /executions/#{String.replace(run, "-", "")}
         /executions/#{String.duplicate("a", 5000)} /executions/#{run}?step=nope&pane=nope
         /executions/#{run}?step=%00 /executions/#{run}/%00) ++
        [
          "/executions?q=" <> URI.encode_www_form(String.duplicate(~s(error:"a b" tag:x ), 3000)),
          "/executions?q=" <> String.duplicate("x", 200_000),
          "/executions?q=" <> xss,
          "/executions?parent=" <> xss,
          "/keys?q=" <> xss,
          "/executions/" <> xss
        ]

    assert problems(conn, paths) == []

    # Bytes that aren't UTF-8 are the web server's to refuse: 400, not 500.
    assert_raise Plug.Conn.InvalidQueryError, fn -> get(conn, dash("/executions?q=%ff")) end
  end

  test "LIKE wildcards in a search are text, not patterns", %{conn: conn} do
    Fixtures.run!(Fixtures.Payments, %{"decline" => true})

    matching = fn q ->
      {:ok, _view, html} = live(conn, dash("/executions?q=" <> URI.encode_www_form(q)))
      [_, count] = Regex.run(~r/([\d,]+) matching/, html)
      count
    end

    assert matching.("error:card") == "1"
    assert matching.("error:CARD") == "1"
    assert matching.("error:%") == "0"
    assert matching.("error:c_rd") == "0"
    assert matching.("%") == "0"
    assert matching.("key:%") == "0"

    {:ok, view, _html} = live(conn, dash())
    palette = with_target(view, "#command-palette")
    render_hook(palette, "palette:open", %{})

    for q <- ["%", "\\", "%%%%", "'; drop table durable.workflow_executions; --"] do
      html = view |> element("#command-palette form") |> render_change(%{value: q})
      assert html =~ "No matches for", "the palette found something for #{inspect(q)}"
    end
  end

  @messages [
    :garbage,
    nil,
    "text",
    %{},
    {:durable_event},
    {:durable_event, 1, 2, 3},
    {:durable_event, :no_such_kind, nil},
    {:durable_event, :workflow_started, %{}},
    {:durable_event, :workflow_failed, %{id: "nope", workflow_id: nil, workflow_name: 5}},
    {:durable_event, :workflow_completed, %{id: "00000000-0000-0000-0000-000000000000"}},
    {:durable_event, :step_failed, %{}},
    {:durable_event, :input_requested, nil},
    {:durable_event, :input_provided, 5},
    {:durable_event, :schedule_toggled, nil},
    :refresh,
    :tick,
    :clock_tick,
    {:DOWN, :ref, :process, :pid, :reason}
  ]

  test "messages a page didn't ask for, out of order and in bursts, leave it standing",
       %{conn: conn} do
    ids = Fixtures.seed!()
    Fixtures.schedule!("card_sweep")

    # Queues and Telemetry are left out: see audit4_known_bugs_test.exs.
    pages =
      ~w(/ /workflows /executions /inputs /inputs?tab=events /keys /schedules
         /schedules/card_sweep /settings /workflows/process_payment
         /workflows/process_payment/runs /executions/#{ids.failed}
         /executions/#{ids.family}/graph /executions/#{ids.waiting_input}/logs /executions/nope)

    for page <- pages do
      {:ok, view, _html} = live(conn, dash(page))
      for _burst <- 1..3, message <- @messages, do: send(view.pid, message)
      assert render(view) =~ "</", "#{page} didn't survive"
    end
  end

  test "an action on a run that changed since the page rendered says so and changes nothing",
       %{conn: conn} do
    ids = Fixtures.seed!()
    count = fn -> repo().aggregate(WorkflowExecution, :count) end

    refused = fn id, event ->
      {:ok, view, _html} = live(conn, dash("/executions/#{id}"))
      before = {Fixtures.get_run!(id).status, count.()}
      render_click(view, event, %{})
      assert {Fixtures.get_run!(id).status, count.()} == before
      view |> element("header [role=alert]") |> render()
    end

    for id <- [ids.completed, ids.compensated, ids.failed] do
      assert refused.(id, "cancel") =~ "already finished"
    end

    assert refused.(ids.completed, "retry") =~ "Only a failed run"
    assert refused.(ids.compensated, "retry") =~ "rolled back"
    assert refused.(ids.waiting_input, "retry") =~ "Only a failed run"
    assert refused.(ids.waiting_input, "rerun") =~ "Only finished runs"
    assert refused.(ids.completed, "rollback") =~ "already finished"
    assert refused.(ids.compensated, "rollback") =~ "already finished"
    assert refused.(ids.completed, "release-key") =~ "hold a key"

    # The page is open on a waiting run; it's cancelled from elsewhere, then
    # this page's stale buttons are pressed.
    {:ok, view, _html} = live(conn, dash("/executions/#{ids.waiting_event}"))
    :ok = Durable.cancel(ids.waiting_event)
    render_click(view, "cancel", %{})
    assert view |> element("header [role=alert]") |> render() =~ "already finished"
    render_click(view, "rollback", %{})
    assert Fixtures.get_run!(ids.waiting_event).status == :cancelled

    # Rolled back twice.
    held = Fixtures.run!(Fixtures.Holds)
    {:ok, view, _html} = live(conn, dash("/executions/#{held}"))
    render_click(view, "rollback", %{})
    assert Fixtures.get_run!(held).status == :pending
    render_click(view, "rollback", %{})
    assert Durable.Testing.drain(Fixtures.get_run!(held)).status == :compensated

    undone =
      from(s in StepExecution, where: s.workflow_id == ^held and s.is_compensation == true)

    assert repo().aggregate(undone, :count) == 1
    render_click(view, "rollback", %{})
    assert Fixtures.get_run!(held).status == :compensated
    assert repo().aggregate(undone, :count) == 1

    # An input answered twice, and one whose run was cancelled.
    pending = from(p in PendingInput, where: p.status == :pending)
    request = repo().one!(pending).id
    {:ok, view, _html} = live(conn, dash("/inputs"))
    render_submit(view, "decide", %{"decision" => "approve", "request" => request})
    assert repo().aggregate(pending, :count) == 0
    html = render_submit(view, "decide", %{"decision" => "approve", "request" => request})
    assert html =~ "That request changed"

    waiting = Fixtures.run!(Fixtures.Approvals)
    {:ok, view, _html} = live(conn, dash("/inputs"))
    request = repo().one!(from(p in PendingInput, where: p.workflow_id == ^waiting)).id
    :ok = Durable.cancel(waiting)
    html = render_submit(view, "decide", %{"decision" => "approve", "request" => request})
    assert html =~ "That request changed"
    assert Fixtures.get_run!(waiting).status == :cancelled
  end
end
