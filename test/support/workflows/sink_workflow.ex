defmodule Durable.TestWorkflows.SinkWorkflow do
  @moduledoc """
  A test workflow whose behavior is chosen at runtime from its input `action`.

  Modeled on oban's `test/support/worker.ex` pattern. Eliminates the need to
  define a new workflow module for every resilience scenario.

  ## Input

      %{
        "action"     => "OK" | "ERROR" | "RAISE" | "EXIT" | "TASK_CRASH" |
                        "SLEEP" | "WAIT_EVENT" | "WAIT_INPUT",
        "ref"        => arbitrary ref echoed back to the test pid,
        "bin_pid"    => Durable.DataCase.pid_to_bin(self()),

        # Action-specific:
        "sleep_ms"      => integer (SLEEP)          default: 50
        "event_name"    => string  (WAIT_EVENT)     default: "evt"
        "timeout_ms"    => integer (WAIT_EVENT)     optional
        "input_name"    => string  (WAIT_INPUT)     default: "input"
      }

  The step sends `{:started, ref}` to the test pid for actions that *start* work
  (SLEEP, WAIT_EVENT, WAIT_INPUT, and — once the test pid is attached — OK),
  and `{:done, ref}` on successful completion. Crash actions never send
  `:done`; the test observes the crash through the workflow's persisted state.

  ## Intentional caveats

  - `"TASK_CRASH"` calls `Process.exit(self(), :kill)`. In supervised mode
    `self()` is the Task the Worker spawned, so the Worker survives via
    `{:DOWN, ...}`. In inline mode `self()` is the test process — DO NOT use
    TASK_CRASH in non-supervised tests.
  - `"EXIT"` uses the catchable `exit/1` form so the step runner's catch-all
    translates it to `%{type: "exit", ...}`.
  """

  use Durable
  use Durable.Context
  use Durable.Wait

  workflow "sink" do
    step(:run, fn data ->
      # On the first invocation, `data` is the workflow input (string keys).
      # On resume after a `wait_for_event`/`wait_for_input` timeout, `data` is
      # the atomized merge of the workflow's persisted context with the
      # timeout payload — the original input keys are not in there. Stash
      # everything we need up front so the step body re-runs symmetrically.
      ref = data["ref"] || get_context(:ref)
      bin_pid = data["bin_pid"] || get_context(:bin_pid)
      action = data["action"] || get_context(:action)
      event_name = data["event_name"] || get_context(:event_name) || "evt"
      input_name = data["input_name"] || get_context(:input_name) || "input"
      sleep_ms = data["sleep_ms"] || get_context(:sleep_ms) || 50
      timeout_ms = data["timeout_ms"] || get_context(:timeout_ms)
      timeout_value = data["timeout_value"] || get_context(:timeout_value)

      put_context(:ref, ref)
      put_context(:bin_pid, bin_pid)
      put_context(:action, action)
      put_context(:event_name, event_name)
      put_context(:input_name, input_name)
      put_context(:sleep_ms, sleep_ms)
      if timeout_ms, do: put_context(:timeout_ms, timeout_ms)
      if timeout_value, do: put_context(:timeout_value, timeout_value)

      pid = Durable.DataCase.bin_to_pid(bin_pid)

      case action do
        "OK" ->
          send(pid, {:done, ref})
          {:ok, %{"ran" => "OK", "ref" => ref}}

        "ERROR" ->
          {:error, %{type: "sink_error", message: "ERROR action"}}

        "RAISE" ->
          raise RuntimeError, "sink raise: ref=#{inspect(ref)}"

        "EXIT" ->
          exit(:sink_exit)

        "TASK_CRASH" ->
          Process.exit(self(), :kill)

        "SLEEP" ->
          send(pid, {:started, ref})
          Process.sleep(sleep_ms)
          send(pid, {:done, ref})
          {:ok, %{"ran" => "SLEEP", "slept_ms" => sleep_ms}}

        "WAIT_EVENT" ->
          send(pid, {:started, ref})
          wait_opts = build_wait_opts(timeout_ms, timeout_value)
          payload = wait_for_event(event_name, wait_opts)
          send(pid, {:done, ref})
          {:ok, %{"ran" => "WAIT_EVENT", "payload" => payload}}

        "WAIT_INPUT" ->
          send(pid, {:started, ref})
          response = wait_for_input(input_name, type: :approval, prompt: "OK?")
          send(pid, {:done, ref})
          {:ok, %{"ran" => "WAIT_INPUT", "response" => response}}
      end
    end)
  end

  defp build_wait_opts(timeout_ms, timeout_value) do
    opts = []
    opts = if timeout_ms, do: Keyword.put(opts, :timeout, timeout_ms), else: opts
    opts = if timeout_value, do: Keyword.put(opts, :timeout_value, timeout_value), else: opts
    opts
  end
end
