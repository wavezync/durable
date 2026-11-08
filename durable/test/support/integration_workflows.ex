defmodule Durable.IntegrationWorkflows do
  @moduledoc false
  # Compiled, not defined in the test files, so that other nodes can load them.

  alias Durable.IntegrationProbe, as: Probe

  defmodule Pipeline do
    @moduledoc false
    use Durable
    use Durable.Helpers

    workflow "it_pipeline", queue: :documents do
      step(:download, [queue: :downloads], fn data ->
        Probe.here(:download)
        {:ok, assign(data, :file, "#{data["url"]}.pdf")}
      end)

      step(:ocr, [queue: :ocr], fn data ->
        Probe.here(:ocr)
        {:ok, assign(data, :text, "text of #{data.file}")}
      end)

      step(:summarize, [queue: :llm], fn data ->
        Probe.here(:summarize)
        {:ok, assign(data, :summary, "summary of #{data.text}")}
      end)

      step(:save, fn data ->
        Probe.here(:save)
        {:ok, assign(data, :saved, true)}
      end)
    end
  end

  defmodule Burst do
    @moduledoc false
    use Durable

    workflow "it_burst", queue: :documents do
      step(:a, [queue: :downloads], fn data ->
        Probe.work({:a, data["n"]}, :a, 15)
        {:ok, data}
      end)

      step(:b, [queue: :ocr], fn data ->
        Probe.work({:b, data["n"]}, :b, 15)
        {:ok, data}
      end)

      step(:c, [queue: :llm], fn data ->
        Probe.work({:c, data["n"]}, :c, 15)
        {:ok, data}
      end)

      step(:d, fn data ->
        Probe.work({:d, data["n"]}, :d, 1)
        {:ok, data}
      end)
    end
  end

  defmodule QuickOnOcr do
    @moduledoc false
    use Durable

    workflow "it_quick_on_ocr" do
      step(:ocr, [queue: :ocr], fn data ->
        Probe.here(:quick)
        {:ok, data}
      end)
    end
  end

  defmodule SlowOnOcr do
    @moduledoc false
    use Durable

    workflow "it_slow_on_ocr" do
      step(:ocr, [queue: :ocr], fn data ->
        Probe.work({:slow, data["n"]}, :ocr, 200)
        {:ok, data}
      end)
    end
  end

  defmodule FlakyOnOcr do
    @moduledoc false
    use Durable

    workflow "it_flaky_on_ocr" do
      step(
        :ocr,
        [queue: :ocr, retry: [max_attempts: 2, backoff: :constant, base: 1_500]],
        fn data ->
          if Probe.here(:flaky) == 1, do: {:error, :down}, else: {:ok, data}
        end
      )

      step(:save, fn data ->
        Probe.here(:save)
        {:ok, data}
      end)
    end
  end

  defmodule SnoozesOnOcr do
    @moduledoc false
    use Durable

    workflow "it_snoozes_on_ocr" do
      step(:ocr, [queue: :ocr], fn data ->
        if Probe.here(:snoozy) == 1, do: {:snooze, 1_500, "not yet"}, else: {:ok, data}
      end)

      step(:save, fn data ->
        Probe.here(:save)
        {:ok, data}
      end)
    end
  end

  defmodule SleepsOnOcr do
    @moduledoc false
    use Durable
    use Durable.Wait

    workflow "it_sleeps_on_ocr" do
      step(:ocr, [queue: :ocr], fn data ->
        Probe.here(:before_sleep)
        sleep(300)
        Probe.here(:after_sleep)
        {:ok, data}
      end)

      step(:save, fn data ->
        Probe.here(:save)
        {:ok, data}
      end)
    end
  end

  defmodule WaitsOnOcr do
    @moduledoc false
    use Durable
    use Durable.Helpers
    use Durable.Wait

    workflow "it_waits_on_ocr" do
      step(:ocr, [queue: :ocr], fn data ->
        Probe.here(:waiting)
        event = wait_for_event("go")
        {:ok, assign(data, :event, event)}
      end)

      step(:save, fn data ->
        Probe.here(:save)
        {:ok, data}
      end)
    end
  end

  defmodule AsksOnOcr do
    @moduledoc false
    use Durable
    use Durable.Helpers
    use Durable.Wait

    workflow "it_asks_on_ocr" do
      step(:ocr, [queue: :ocr], fn data ->
        Probe.here(:asking)
        answer = wait_for_input("approve")
        {:ok, assign(data, :answer, answer)}
      end)

      step(:save, fn data ->
        Probe.here(:save)
        {:ok, data}
      end)
    end
  end

  defmodule Saga do
    @moduledoc false
    use Durable

    workflow "it_saga" do
      step(:charge, [queue: :ocr, compensate: :refund], fn data ->
        Probe.here(:charge)
        {:ok, data}
      end)

      step(:ship, [queue: :llm], fn _data ->
        Probe.here(:ship)
        {:error, :down}
      end)

      compensate(:refund, fn data ->
        Probe.here(:refund)
        {:ok, data}
      end)
    end
  end

  defmodule FailsUntilAllowed do
    @moduledoc false
    use Durable

    workflow "it_fails_until_allowed", queue: :documents do
      step(:ocr, [queue: :ocr], fn data ->
        Probe.here(:ocr)
        if Probe.set?(:allow), do: {:ok, data}, else: {:error, :down}
      end)

      step(:save, fn data ->
        Probe.here(:save)
        {:ok, data}
      end)
    end
  end

  defmodule EndsOnLlm do
    @moduledoc false
    use Durable

    workflow "it_ends_on_llm", queue: :documents do
      step(:summarize, [queue: :llm], fn data ->
        Probe.here(:summarize)
        {:ok, data}
      end)
    end
  end

  defmodule StuckSaga do
    @moduledoc false
    use Durable

    workflow "it_stuck_saga", timeout: 300 do
      step(:reserve, [compensate: :release], fn data ->
        Probe.here(:reserve)
        {:ok, data}
      end)

      step(:charge, [queue: :nobody], fn data ->
        Probe.here(:charge)
        {:ok, data}
      end)

      compensate(:release, fn data ->
        Probe.here(:release)
        {:ok, data}
      end)
    end
  end

  defmodule TimesOutOnOcr do
    @moduledoc false
    use Durable

    workflow "it_times_out_on_ocr", timeout: 300 do
      step(:ocr, [queue: :ocr], fn data ->
        Probe.here(:timed_ocr)
        {:ok, data}
      end)
    end
  end

  defmodule OutOfTime do
    @moduledoc false
    use Durable

    workflow "it_out_of_time", timeout: 300 do
      step(:slow, fn data ->
        Probe.here(:slow)
        Process.sleep(100)
        {:ok, data}
      end)

      step(:ocr, [queue: :ocr], fn data ->
        # Long enough to outlast the deadline, even with a busy claim.
        Probe.here(:long_ocr)
        Process.sleep(2_000)
        {:ok, data}
      end)

      step(:never, [queue: :llm], fn data ->
        Probe.here(:never)
        {:ok, data}
      end)
    end
  end

  defmodule StepTimeoutOnOcr do
    @moduledoc false
    use Durable

    workflow "it_step_timeout_on_ocr" do
      step(
        :ocr,
        [queue: :ocr, timeout: 100, retry: [max_attempts: 2, backoff: :constant, base: 10]],
        fn data ->
          if Probe.here(:timed) == 1, do: Process.sleep(2_000)
          {:ok, data}
        end
      )

      step(:save, fn data ->
        Probe.here(:save)
        {:ok, data}
      end)
    end
  end

  defmodule Parallel do
    @moduledoc false
    use Durable
    use Durable.Helpers

    workflow "it_parallel", queue: :documents do
      step(:prepare, [queue: :ocr], fn data ->
        Probe.here(:prepare)
        {:ok, assign(data, :prepared, true)}
      end)

      parallel do
        step(:on_llm, [queue: :llm], fn data ->
          Probe.here(:on_llm)
          {:ok, assign(data, :on_llm, true)}
        end)

        step(:on_downloads, [queue: :downloads], fn data ->
          Probe.here(:on_downloads)
          {:ok, assign(data, :on_downloads, true)}
        end)

        step(:plain, fn data ->
          Probe.here(:plain)
          {:ok, assign(data, :plain, true)}
        end)
      end

      step(:finish, fn data ->
        Probe.here(:finish)
        {:ok, data}
      end)
    end
  end

  defmodule BranchRetry do
    @moduledoc false
    use Durable
    use Durable.Helpers

    workflow "it_branch_retry" do
      step(:start, fn data ->
        Probe.here(:start)
        {:ok, assign(data, :path, "a")}
      end)

      branch on: fn data -> data[:path] || data["path"] end do
        "a" ->
          step(
            :a1,
            [queue: :ocr, retry: [max_attempts: 2, backoff: :constant, base: 100]],
            fn data ->
              if Probe.here(:a1) == 1, do: {:error, :down}, else: {:ok, data}
            end
          )

          step(:a2, fn data ->
            Probe.here(:a2)
            {:ok, data}
          end)

        "b" ->
          step(:b1, fn data ->
            Probe.here(:b1)
            {:ok, data}
          end)
      end

      step(:done, [queue: :llm], fn data ->
        Probe.here(:done)
        {:ok, data}
      end)
    end
  end

  defmodule Decides do
    @moduledoc false
    use Durable

    workflow "it_decides" do
      decision(:route, [queue: :ocr], fn data ->
        Probe.here(:route)
        {:goto, :finish, data}
      end)

      step(:skipped, [queue: :llm], fn data ->
        Probe.here(:skipped)
        {:ok, data}
      end)

      step(:finish, fn data ->
        Probe.here(:finish)
        {:ok, data}
      end)
    end
  end

  defmodule Child do
    @moduledoc false
    use Durable

    workflow "it_child" do
      step(:child_work, [queue: :llm], fn data ->
        Probe.here(:child_work)
        {:ok, data}
      end)
    end
  end

  defmodule Parent do
    @moduledoc false
    use Durable
    use Durable.Helpers
    use Durable.Orchestration

    workflow "it_parent", queue: :documents do
      step(:delegate, [queue: :ocr], fn data ->
        Probe.here(:delegate)

        case call_workflow(Durable.IntegrationWorkflows.Child, %{"x" => 1}, ref: :child) do
          {:ok, _result} -> {:ok, assign(data, :delegated, true)}
          {:error, reason} -> {:error, reason}
        end
      end)

      step(:finish, fn data ->
        Probe.here(:finish)
        {:ok, data}
      end)
    end
  end

  defmodule RunAgain do
    @moduledoc false
    use Durable

    workflow "it_run_again", on_duplicate: :run_again do
      step(:work, [queue: :ocr], fn data ->
        Probe.here({:work, data["v"]})
        Probe.wait_for({:go, data["v"]})
        {:ok, data}
      end)

      step(:save, fn data ->
        Probe.here({:save, data["v"]})
        {:ok, data}
      end)
    end
  end

  defmodule Debounced do
    @moduledoc false
    use Durable

    workflow "it_debounced", debounce: [period: 400] do
      step(:work, [queue: :ocr], fn data ->
        Probe.here({:debounced, data["v"]})
        {:ok, data}
      end)
    end
  end

  defmodule HeldOnOcr do
    @moduledoc false
    use Durable

    workflow "it_held_on_ocr" do
      step(:ocr, [queue: :ocr], fn data ->
        Probe.here(:held)
        Probe.wait_for(:release)
        {:ok, data}
      end)

      step(:save, fn data ->
        Probe.here(:save)
        {:ok, data}
      end)
    end
  end
end
