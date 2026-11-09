defmodule Durable.Integration.OpenTelemetryTest do
  @moduledoc """
  The optional add-on against the real SDK, with real kills: an attempt's span
  has to come out right whoever ends it.
  """
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log

  require Record

  alias Durable.Queue.StaleJobRecovery

  require Logger

  Record.defrecordp(
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  defmodule Passes do
    use Durable
    use Durable.Context
    alias Durable.IntegrationProbe, as: Probe
    require Logger

    workflow "otel_passes" do
      step(:first, fn d ->
        Probe.put(
          :first_logger,
          Map.take(Map.new(Logger.metadata()), [:otel_trace_id, :otel_span_id])
        )

        Logger.info("from the first step")

        Probe.put(
          :task_span,
          Task.await(Task.async(bind(fn -> :otel_tracer.current_span_ctx() end)))
        )

        {:ok, d}
      end)

      step(:second, fn d ->
        Probe.put(:second_logger, Map.take(Map.new(Logger.metadata()), [:otel_span_id]))
        {:ok, d}
      end)
    end
  end

  defmodule FailsOnce do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "otel_fails_once" do
      step(:work, [retry: [max_attempts: 2, backoff: :constant, base: 1]], fn d ->
        if Probe.note(:body) == 1, do: {:error, "declined"}, else: {:ok, d}
      end)
    end
  end

  defmodule KilledOnce do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "otel_killed_once" do
      step(:work, [retry: [max_attempts: 2, backoff: :constant, base: 1]], fn d ->
        if Probe.note(:body) == 1 do
          Process.sleep(30)
          Process.exit(self(), :kill)
        end

        {:ok, d}
      end)
    end
  end

  defmodule Held do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "otel_held" do
      step(:work, fn d ->
        Probe.note(:body)
        Probe.wait_for(:release)
        {:ok, d}
      end)
    end
  end

  defmodule Branches do
    use Durable

    workflow "otel_branches" do
      parallel do
        step(:branch, fn d -> {:ok, d} end)
      end
    end
  end

  defmodule Compensated do
    use Durable

    workflow "otel_compensated" do
      step(:book, [compensate: :unbook], fn d -> {:ok, d} end)
      step(:charge, fn _d -> {:fail, "declined"} end)
      compensate(:unbook, fn d -> {:ok, d} end)
    end
  end

  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    assert :ok = Durable.OpenTelemetry.setup()
    on_exit(fn -> :telemetry.detach("durable-opentelemetry") end)
    :ok
  end

  defp exported(count) do
    for _ <- 1..count do
      receive do
        {:span, record} -> record
      after
        3_000 -> flunk("expected #{count} spans")
      end
    end
  end

  defp no_more_spans do
    refute_receive {:span, _}, 200
  end

  defp hex_trace(record), do: Base.encode16(<<span(record, :trace_id)::128>>, case: :lower)
  defp hex_span(record), do: Base.encode16(<<span(record, :span_id)::64>>, case: :lower)
  defp bare(id), do: String.replace(id, "-", "")
  defp row_span(row), do: row.id |> bare() |> String.slice(16, 16)

  defp rows(id) do
    IntegrationRepo.all(
      from(s in StepExecution, where: s.workflow_id == ^id, order_by: s.inserted_at)
    )
  end

  defp attribute(record, name) do
    record |> span(:attributes) |> :otel_attributes.map() |> Map.fetch!(name)
  end

  defp status_code(record) do
    case span(record, :status) do
      :undefined -> :unset
      {:status, code, _message} -> code
    end
  end

  test "a passing attempt is one span with the run's and the row's ids" do
    start_durable!(%{default: 1})

    {:ok, id} = Durable.start(Passes, %{})
    await_status(id, :completed)

    [first, second] = exported(2)
    no_more_spans()
    [first_row, second_row] = rows(id)

    assert span(first, :name) == "otel_passes.first"
    assert hex_trace(first) == bare(id)
    assert hex_trace(second) == bare(id)
    assert hex_span(first) == row_span(first_row)
    assert hex_span(second) == row_span(second_row)
    assert span(first, :parent_span_id) == :undefined

    assert attribute(first, "durable.step") == "first"
    assert attribute(first, "durable.attempt") == 1
    assert attribute(first, "durable.result") == "ok"
    assert status_code(first) == :unset

    assert [line] = first_row.logs
    assert line["trace_id"] == hex_trace(first)
    assert line["span_id"] == hex_span(first)

    # Logger lines in the step get the ids, and the next step gets its own.
    assert Probe.fetch(:first_logger) == %{
             otel_trace_id: bare(id),
             otel_span_id: hex_span(first)
           }

    assert Probe.fetch(:second_logger) == %{otel_span_id: hex_span(second)}

    # A bound Task is inside the same span.
    assert :otel_span.span_id(Probe.fetch(:task_span)) == span(first, :span_id)
  end

  test "each retry is its own span in the same trace, and an error is marked" do
    start_durable!(%{default: 1})

    {:ok, id} = Durable.start(FailsOnce, %{})
    await_status(id, :completed)

    [failed, passed] = exported(2)

    assert hex_trace(failed) == hex_trace(passed)
    assert hex_span(failed) != hex_span(passed)
    assert status_code(failed) == :error
    assert {:status, :error, "error: " <> _} = span(failed, :status)
    assert status_code(passed) == :unset
  end

  test "an attempt whose process was killed still gets its span, covering its time" do
    start_durable!(%{default: 1})

    {:ok, id} = Durable.start(KilledOnce, %{})
    await_status(id, :completed)

    [killed, passed] = exported(2) |> Enum.sort_by(&attribute(&1, "durable.result"))
    no_more_spans()
    [killed_row, passed_row] = rows(id)

    assert attribute(killed, "durable.result") == "error"
    assert {:status, :error, "task_crash: " <> _} = span(killed, :status)
    assert hex_span(killed) == row_span(killed_row)
    assert hex_span(passed) == row_span(passed_row)
    assert hex_trace(killed) == bare(id)

    elapsed = span(killed, :end_time) - span(killed, :start_time)
    assert System.convert_time_unit(elapsed, :native, :millisecond) >= 20
  end

  test "an attempt lost with its node gets its span from the sweep" do
    start_durable!(%{default: 1}, stale_lock_timeout: 1)

    {:ok, id} = Durable.start(Held, %{})
    assert_eventually(fn -> Probe.hits(:body) == 1 end)
    Process.exit(Durable.DataCase.get_worker_pid(Durable, "default", id), :kill)
    Process.sleep(1_100)
    {:ok, 1} = StaleJobRecovery.recover_now(Durable)

    [lost] = exported(1)
    assert {:status, :error, "worker_lost: " <> _} = span(lost, :status)
    assert hex_trace(lost) == bare(id)

    assert_eventually(fn -> Probe.hits(:body) == 2 end)
    :ok = Probe.set(:release)
    await_status(id, :completed)
    [passed] = exported(1)
    assert hex_span(passed) != hex_span(lost)
    assert hex_trace(passed) == hex_trace(lost)
  end

  test "a cancelled attempt isn't an error" do
    start_durable!(%{default: 1})

    {:ok, id} = Durable.start(Held, %{})
    assert_eventually(fn -> Probe.hits(:body) == 1 end)
    :ok = Durable.cancel(id)

    [cancelled] = exported(1)
    assert attribute(cancelled, "durable.result") == "cancelled"
    assert status_code(cancelled) == :unset
    :ok = Probe.set(:release)
  end

  test "a parallel branch is in its top run's trace" do
    start_durable!(%{default: 2})

    {:ok, id} = Durable.start(Branches, %{})
    await_status(id, :completed)

    [branch] = exported(1)
    assert hex_trace(branch) == bare(id)
  end

  test "a compensation is in the run's trace" do
    start_durable!(%{default: 1})

    {:ok, id} = Durable.start(Compensated, %{})
    await_status(id, :compensated)

    spans = exported(3)
    assert Enum.all?(spans, &(hex_trace(&1) == bare(id)))

    assert %{} =
             compensation =
             Enum.find(spans, &(span(&1, :name) == "otel_compensated.unbook"))
             |> then(&%{span: &1})

    assert attribute(compensation.span, "durable.compensation") == "unbook"
    assert attribute(compensation.span, "durable.step") == "book"
  end

  test "leaves the caller's span and Logger metadata as it found them" do
    meta = %{
      telemetry_span_context: "ctx",
      root_workflow_id: "0aca49ae-059e-4259-9bf8-f9406574cd4d",
      step_execution_id: "1c651d44-463b-4559-a9f0-e7f0e05ae30f",
      workflow_id: "0aca49ae-059e-4259-9bf8-f9406574cd4d",
      workflow: "w",
      step: :s,
      attempt: 1
    }

    Durable.OpenTelemetry.handle_event([:durable, :step, :start], %{}, meta, nil)
    assert Keyword.has_key?(Logger.metadata(), :otel_span_id)

    Durable.OpenTelemetry.handle_event(
      [:durable, :step, :stop],
      %{duration: 1},
      Map.put(meta, :result, :ok),
      nil
    )

    assert :otel_tracer.current_span_ctx() == :undefined
    refute Keyword.has_key?(Logger.metadata(), :otel_span_id)
  end

  test "setup refuses without the id generator, and says why" do
    :telemetry.detach("durable-opentelemetry")
    generator = Application.get_env(:opentelemetry, :id_generator)
    Application.delete_env(:opentelemetry, :id_generator)
    on_exit(fn -> Application.put_env(:opentelemetry, :id_generator, generator) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Durable.OpenTelemetry.setup() == {:error, :id_generator_not_configured}
      end)

    assert log =~ "id_generator"
  end
end
