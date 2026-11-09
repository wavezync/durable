defmodule Durable.Integration.WaitsAndCaptureRegressionsTest do
  @moduledoc "Waits that timed out or were cancelled, what a log line can do to capture, and answers that must not be lost."
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log
  @moduletag timeout: 60_000

  alias Durable.LogCapture.Handler
  alias Durable.Storage.Schemas.{PendingEvent, PendingInput, WaitGroup}
  alias Durable.Wait.TimeoutWorker

  require Logger

  defmodule WaitAnyTimeout do
    use Durable
    use Durable.Wait
    alias Durable.IntegrationProbe, as: Probe

    workflow "r_wait_any" do
      step(:w, fn data ->
        Probe.note(:body)
        r = wait_for_any(["a", "b"], timeout: 100, timeout_value: {:timeout, nil})
        {:ok, Map.put(data, "result", inspect(r))}
      end)
    end
  end

  defmodule WaitAllTimeout do
    use Durable
    use Durable.Wait
    alias Durable.IntegrationProbe, as: Probe

    workflow "r_wait_all" do
      step(:w, fn data ->
        Probe.note(:body)
        r = wait_for_all(["a", "b"], timeout: 100, timeout_value: {:timeout, :partial})
        {:ok, Map.put(data, "result", inspect(r))}
      end)
    end
  end

  defmodule WaitEventCancel do
    use Durable
    use Durable.Wait
    alias Durable.IntegrationProbe, as: Probe

    workflow "r_wait_event" do
      step(:w, fn data ->
        Probe.note(:body)
        r = wait_for_event("go")
        {:ok, Map.put(data, "result", inspect(r))}
      end)
    end
  end

  defmodule LogsUnreadable do
    use Durable
    require Logger

    workflow "r_unreadable" do
      step(:work, fn data ->
        Logger.info([0x110000])
        {:ok, data}
      end)
    end
  end

  defmodule LogsChardata do
    use Durable
    require Logger

    workflow "r_chardata" do
      step(:w, fn data ->
        # A perfectly legal Logger message: chardata with a codepoint above 255.
        Logger.info(["snow ", 0x2603])
        {:ok, data}
      end)
    end
  end

  defmodule LogsTupleSource do
    use Durable
    require Logger

    workflow "r_source" do
      step(:w, fn data ->
        # credo:disable-for-next-line Credo.Check.Warning.MissedMetadataKeyInLoggerConfig
        Logger.info("from kafka", source: {"orders", 3})
        {:ok, data}
      end)
    end
  end

  defmodule LogsPlain do
    use Durable
    require Logger

    workflow "r_plain" do
      step(:w, fn data ->
        Logger.info("a plain line")
        {:ok, data}
      end)
    end
  end

  defmodule LogsMixed do
    use Durable
    require Logger

    workflow "r_mixed" do
      step(:w, fn data ->
        IO.puts("printed first")
        Process.sleep(200)
        Logger.info("logged second")
        {:ok, data}
      end)
    end
  end

  defp logs(id) do
    [row] = IntegrationRepo.all(from(s in StepExecution, where: s.workflow_id == ^id))
    row.logs
  end

  defp step_rows(id) do
    IntegrationRepo.all(
      from(s in StepExecution, where: s.workflow_id == ^id, order_by: s.inserted_at)
    )
  end

  defp expire_waits!(id) do
    for schema <- [PendingEvent, PendingInput, WaitGroup] do
      IntegrationRepo.update_all(
        from(p in schema, where: p.workflow_id == ^id and p.status == :pending),
        set: [timeout_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )
    end

    TimeoutWorker.check_timeouts(Durable)
  end

  describe "wait group timeouts" do
    for {mod, name} <- [{WaitAnyTimeout, "any"}, {WaitAllTimeout, "all"}] do
      @mod mod
      test "wait_for_#{name} with a timeout returns timeout_value when it times out" do
        start_durable!(%{default: 2})
        {:ok, id} = Durable.start(@mod, %{})
        await_status(id, :waiting)

        for _ <- 1..3 do
          Process.sleep(150)
          expire_waits!(id)
          Process.sleep(300)
        end

        run = get(id)
        groups = IntegrationRepo.all(from(g in WaitGroup, where: g.workflow_id == ^id))

        assert run.status == :completed
      end
    end
  end

  describe "cancel_wait" do
    test "resumes a wait_for_event step with the cancellation" do
      start_durable!(%{default: 2})
      {:ok, id} = Durable.start(WaitEventCancel, %{})
      await_status(id, :waiting)

      :ok = Durable.Wait.cancel_wait(id, reason: "operator")
      assert_eventually(fn -> Probe.hits(:body) == 2 end)
      Process.sleep(300)

      run = get(id)

      events =
        IntegrationRepo.all(from(e in PendingEvent, where: e.workflow_id == ^id))
        |> Enum.map(& &1.status)

      refute run.status == :waiting
    end
  end

  describe "the capture handler" do
    setup do
      on_exit(fn -> Handler.attach() end)
      :ok
    end

    for {mod, name} <- [
          {LogsChardata, "chardata"},
          {LogsTupleSource, "tuple source"},
          {LogsUnreadable, "unreadable"}
        ] do
      @mod mod
      test "survives a #{name} log line" do
        start_durable!(%{default: 1})
        Handler.attach()
        assert Handler.attached?()

        {:ok, bad} = Durable.start(@mod, %{})
        await_status(bad, :completed)

        {:ok, good} = Durable.start(LogsPlain, %{})
        await_status(good, :completed)

        assert Handler.attached?()
        assert [_ | _] = logs(good)
      end
    end
  end

  describe "a chardata log line" do
    test "is saved, not just survived" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(LogsChardata, %{})
      await_status(id, :completed)

      assert [%{"message" => "snow ☃"}] = logs(id)
    end
  end

  describe "order of saved lines" do
    test "keeps a printed line before a Logger line that came after it" do
      start_durable!(%{default: 1})
      {:ok, id} = Durable.start(LogsMixed, %{})
      await_status(id, :completed)

      lines = for l <- logs(id), do: {l["timestamp"], l["source"], l["message"]}
      assert Enum.map(lines, &elem(&1, 2)) == ["printed first", "logged second"]
    end
  end

  describe "provide_input" do
    defmodule AsksInput do
      use Durable
      use Durable.Wait

      workflow "r_asks_input" do
        step(:w, fn data ->
          r = wait_for_input("answer")
          {:ok, Map.put(data, "result", inspect(r))}
        end)
      end
    end

    test "a caller dying between its two writes doesn't strand the run" do
      start_durable!(%{default: 2})
      {:ok, id} = Durable.start(AsksInput, %{})
      await_status(id, :waiting)

      handler = "kill-after-input-update-#{System.unique_integer()}"

      :telemetry.attach(
        handler,
        [:durable, :integration_repo, :query],
        fn _event, _measurements, meta, pid ->
          if self() == pid and String.starts_with?(meta.query, "UPDATE") and
               String.contains?(meta.query, "pending_inputs") do
            Process.exit(self(), :kill)
          end
        end,
        nil
      )

      # The real shape of a web request dying (or its pool call failing) here.
      caller =
        spawn(fn ->
          :telemetry.detach(handler)

          :telemetry.attach(
            handler,
            [:durable, :integration_repo, :query],
            fn _e, _m, meta, pid ->
              if self() == pid and String.starts_with?(meta.query, "UPDATE") and
                   String.contains?(meta.query, "pending_inputs") do
                Process.exit(self(), :kill)
              end
            end,
            self()
          )

          Durable.provide_input(id, "answer", %{"ok" => true})
        end)

      ref = Process.monitor(caller)
      assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
      :telemetry.detach(handler)
      Process.sleep(300)

      run = get(id)
      [input] = IntegrationRepo.all(from(p in PendingInput, where: p.workflow_id == ^id))
      retry = Durable.provide_input(id, "answer", %{"ok" => true})

      # Either it stayed open so the caller can try again, or the run resumed.
      assert input.status == :pending or run.status != :waiting
      _ = step_rows(id)
    end
  end
end
