defmodule Durable.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring access to the
  application's data layer.

  You may define functions here to be used as helpers in your tests.

  ## Supervised mode

  The default setup starts Durable with `queue_enabled: false`. Tests that
  need the supervised runtime (queue pollers, stale-job recovery, timeout
  worker, scheduler) should opt out via `@moduletag :supervised` and call
  `start_supervised_durable!/1` themselves.
  """

  use ExUnit.CaseTemplate

  import Ecto.Query

  alias Durable.Config
  alias Durable.Executor

  alias Durable.Storage.Schemas.{
    PendingEvent,
    PendingInput,
    StepExecution,
    WaitGroup,
    WorkflowExecution
  }

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Durable.TestRepo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query

      # Only auto-import helpers that were originally shared OR that don't
      # collide with local `defp` definitions in existing test files. Tests
      # that want the promoted helpers (create_and_execute_workflow,
      # get_step_executions, get_pending_event, get_pending_input,
      # get_wait_group, get_child_executions, execute_children,
      # get_worker_pid) should `import Durable.DataCase, only: [...]`
      # explicitly or call them via the fully-qualified module name.
      import Durable.DataCase,
        only: [
          assert_eventually: 1,
          assert_eventually: 2,
          assert_eventually: 3,
          with_backoff: 1,
          with_backoff: 2,
          setup_sandbox: 1,
          start_supervised_durable!: 0,
          start_supervised_durable!: 1,
          pid_to_bin: 0,
          pid_to_bin: 1,
          bin_to_pid: 1
        ]
    end
  end

  setup tags do
    Durable.DataCase.setup_sandbox(tags)

    unless tags[:supervised] do
      start_supervised!({Durable, repo: Durable.TestRepo, queue_enabled: false, pubsub: :start})
    end

    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Durable.TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that polls until a condition is met or timeout.

  ## Examples

      assert_eventually(fn ->
        {:ok, exec} = Durable.get_execution(id)
        exec.status == :completed
      end)
  """
  def assert_eventually(fun, timeout \\ 5000, interval \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_assert_eventually(fun, deadline, interval)
  end

  defp do_assert_eventually(fun, deadline, interval) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(interval)
        do_assert_eventually(fun, deadline, interval)
      else
        ExUnit.Assertions.flunk("Condition not met within timeout")
      end
    end
  end

  @doc """
  Re-runs an assertion block until it passes or the deadline elapses.

  Unlike `assert_eventually/3`, this preserves the original `ExUnit.AssertionError`
  so the failure message points at the real mismatch. Use for DB/telemetry
  assertions where the readable failure matters.

  ## Options

  - `:total` - Total attempts before giving up (default: 100)
  - `:sleep` - Sleep between attempts in ms (default: 10)
  """
  def with_backoff(opts \\ [], fun) do
    total = Keyword.get(opts, :total, 100)
    sleep = Keyword.get(opts, :sleep, 10)

    do_with_backoff(fun, 0, total, sleep)
  end

  defp do_with_backoff(fun, count, total, sleep) do
    fun.()
  rescue
    exception in [ExUnit.AssertionError] ->
      if count < total do
        Process.sleep(sleep)
        do_with_backoff(fun, count + 1, total, sleep)
      else
        reraise(exception, __STACKTRACE__)
      end
  end

  @doc """
  Starts Durable under the test supervision tree with queue processing enabled
  by default. Returns the instance name.

  Intended for tests with `@moduletag :supervised`. Defaults:
  - `:name` - `Durable` (tests are `async: false` under shared sandbox, so
    only one instance runs at a time — reusing the default name keeps
    `Durable.start/3` / `Executor.start_workflow/3` etc. callable without
    passing `durable: name` everywhere)
  - `:repo` - `Durable.TestRepo`
  - `:queue_enabled` - `true`
  - `:pubsub` - `:start`
  - `:queues` - `%{default: [concurrency: 1, poll_interval: 50]}`
  - `:stale_lock_timeout` - `300` (seconds)
  - `:heartbeat_interval` - `100` (ms)

  Pass any of these to override. Other `Durable` options (`:scheduler_interval`,
  etc.) pass through untouched.
  """
  def start_supervised_durable!(opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:name, Durable)
      |> Keyword.put_new(:repo, Durable.TestRepo)
      |> Keyword.put_new(:queue_enabled, true)
      |> Keyword.put_new(:pubsub, :start)
      |> Keyword.put_new(:queues, %{default: [concurrency: 1, poll_interval: 50]})
      |> Keyword.put_new(:stale_lock_timeout, 300)
      |> Keyword.put_new(:heartbeat_interval, 100)

    name = Keyword.fetch!(opts, :name)

    # Mix-task tests (Mix.Tasks.Durable.List etc.) set
    # `:durable, :disable_queue_processing, true` via
    # `Durable.Mix.Helpers.ensure_started_readonly/0` and never reset it.
    # That flag survives in app env and silently forces queue_enabled to
    # false on every subsequent supervisor start. Reset it here so
    # supervised tests get the queue they asked for. Restore on exit so
    # we don't accidentally enable queues for later mix-task tests.
    prior = Application.get_env(:durable, :disable_queue_processing)
    Application.put_env(:durable, :disable_queue_processing, false)
    ExUnit.Callbacks.on_exit(fn -> restore_disable_flag(prior) end)

    # Ensure a clean start. A previous test may have left the named supervisor
    # alive (start_supervised cleanup terminates the test child but if the
    # previous test had its own setup blocks, the named registration can
    # outlive them). Without this, the next start_supervised! call returns
    # `{:error, {:already_started, pid}}` and ExUnit silently uses the existing
    # (potentially queue-disabled) instance, ignoring the new opts.
    Durable.Supervisor.stop(name)

    start_supervised!({Durable, opts})
    name
  end

  defp restore_disable_flag(nil), do: Application.delete_env(:durable, :disable_queue_processing)

  defp restore_disable_flag(value),
    do: Application.put_env(:durable, :disable_queue_processing, value)

  # ============================================================================
  # PID <-> binary transport (for use with sink workflows that close over the
  # test pid at workflow-input time)
  # ============================================================================

  @doc "Encodes a pid as an opaque base64 binary safe to put in workflow input."
  def pid_to_bin(pid \\ self()) do
    pid
    |> :erlang.term_to_binary()
    |> Base.encode64()
  end

  @doc "Inverse of `pid_to_bin/1`."
  def bin_to_pid(bin) do
    bin
    |> Base.decode64!()
    |> :erlang.binary_to_term()
  end

  # ============================================================================
  # Workflow execution helpers
  # ============================================================================

  @doc """
  Creates a workflow execution row for `module` with `input` and then drives it
  synchronously via `Durable.Executor.execute_workflow/2`. Returns the reloaded
  `WorkflowExecution` struct.

  Works in both queue-disabled (unit) and queue-enabled (supervised) test modes.
  """
  def create_and_execute_workflow(module, input, opts \\ []) do
    config = Config.get(Durable)
    repo = config.repo
    {:ok, workflow_def} = module.__default_workflow__()

    attrs = %{
      workflow_module: Atom.to_string(module),
      workflow_name: workflow_def.name,
      status: :pending,
      queue: Keyword.get(opts, :queue, "default"),
      priority: Keyword.get(opts, :priority, 0),
      input: input,
      context: %{}
    }

    {:ok, execution} =
      %WorkflowExecution{}
      |> WorkflowExecution.changeset(attrs)
      |> repo.insert()

    Executor.execute_workflow(execution.id, config)
    {:ok, repo.get!(WorkflowExecution, execution.id)}
  end

  @doc "Loads all `StepExecution` rows for a workflow, oldest first."
  def get_step_executions(workflow_id) do
    repo = Config.get(Durable).repo

    repo.all(
      from(s in StepExecution,
        where: s.workflow_id == ^workflow_id,
        order_by: [asc: s.inserted_at]
      )
    )
  end

  @doc "Fetches a single `PendingInput` for a workflow by input name."
  def get_pending_input(repo, workflow_id, input_name) do
    repo.one(
      from(p in PendingInput,
        where: p.workflow_id == ^workflow_id and p.input_name == ^input_name
      )
    )
  end

  @doc "Fetches a single `PendingEvent` for a workflow by event name."
  def get_pending_event(repo, workflow_id, event_name) do
    repo.one(
      from(p in PendingEvent,
        where: p.workflow_id == ^workflow_id and p.event_name == ^event_name
      )
    )
  end

  @doc "Fetches the active `WaitGroup` for a workflow."
  def get_wait_group(repo, workflow_id) do
    repo.one(from(w in WaitGroup, where: w.workflow_id == ^workflow_id))
  end

  @doc "Returns child `WorkflowExecution` rows for a parent workflow."
  def get_child_executions(repo, parent_id) do
    repo.all(from(w in WorkflowExecution, where: w.parent_workflow_id == ^parent_id))
  end

  @doc """
  Executes every pending child of `parent_id` synchronously via the inline
  executor. Useful for driving parallel fan-out deterministically.
  """
  def execute_children(repo, parent_id, config) do
    parent_id
    |> (&get_child_executions(repo, &1)).()
    |> Enum.each(fn child ->
      if child.status == :pending do
        Executor.execute_workflow(child.id, config)
      end
    end)
  end

  # ============================================================================
  # Supervised-runtime lookups
  # ============================================================================

  @doc """
  Returns the pid of the `Durable.Queue.Worker` GenServer currently executing
  `job_id`, or `nil` if no worker matches.

  Uses `:sys.get_state/2` on each live worker — safe within tests, avoid in
  hot loops. Only works when Durable is started with `queue_enabled: true`.
  """
  def get_worker_pid(durable_name \\ Durable, queue_name \\ "default", job_id) do
    worker_sup =
      Module.concat([durable_name, Queue, WorkerSupervisor, camelize(queue_name)])

    case Process.whereis(worker_sup) do
      nil ->
        nil

      sup_pid ->
        sup_pid
        |> DynamicSupervisor.which_children()
        |> Enum.find_value(fn {_, pid, _, _} when is_pid(pid) ->
          find_worker_for_job(pid, job_id)
        end)
    end
  end

  defp find_worker_for_job(pid, job_id) do
    state = :sys.get_state(pid, 100)

    if (is_map(state) and Map.get(state, :job)) && state.job.id == job_id do
      pid
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp camelize(string) do
    string
    |> String.split("_")
    |> Enum.map_join(&String.capitalize/1)
    |> String.to_atom()
  end
end
