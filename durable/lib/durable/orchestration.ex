defmodule Durable.Orchestration do
  @moduledoc """
  Workflow composition: call child workflows from parent steps.

  Provides two primitives for composing workflows:

  - `call_workflow/3` — Start a child workflow and wait for its result (synchronous)
  - `start_workflow/3` — Start a child workflow without waiting (fire-and-forget)

  ## Usage

      defmodule MyApp.OrderWorkflow do
        use Durable
        use Durable.Helpers
        use Durable.Orchestration

        workflow "process_order" do
          step :charge_payment, fn data ->
            case call_workflow(MyApp.PaymentWorkflow, %{"amount" => data["total"]},
                   timeout: hours(1)) do
              {:ok, result} ->
                {:ok, assign(data, :payment_id, result["payment_id"])}
              {:error, reason} ->
                {:error, reason}
            end
          end

          step :send_email, fn data ->
            {:ok, email_wf_id} = start_workflow(MyApp.EmailWorkflow,
              %{"to" => data["email"]}, ref: :confirmation)
            {:ok, assign(data, :email_workflow_id, email_wf_id)}
          end
        end
      end

  """

  alias Durable.Config
  alias Durable.Context
  alias Durable.EngineState
  alias Durable.Executor
  alias Durable.PubSub, as: DurablePubSub
  alias Durable.Repo
  alias Durable.Storage.Schemas.{PendingEvent, WorkflowExecution}

  import Ecto.Query, only: [from: 2]

  @doc """
  Injects orchestration functions into the calling module.
  """
  defmacro __using__(_opts) do
    quote do
      import Durable.Orchestration,
        only: [call_workflow: 2, call_workflow: 3, start_workflow: 2, start_workflow: 3]
    end
  end

  @doc """
  Starts a child workflow and waits for its result.

  The parent workflow will be suspended until the child completes or fails.
  On resume, returns `{:ok, result}` or `{:error, reason}`.

  ## Options

  - `:ref` - Reference name for idempotency (default: module name)
  - `:timeout` - Timeout in milliseconds
  - `:timeout_value` - Value returned on timeout (default: `:child_timeout`)
  - `:queue` - Queue for the child workflow (default: "default")
  - `:durable` - Durable instance name (default: Durable)

  ## What the parent sees on success

  The `result` returned on success is the child workflow's **entire final
  context**, not just its explicit outputs. This includes every
  `put_context/2` key the child set, plus the final step's return value.

  If you need to expose only specific outputs, return a clean shape from the
  child's final step or pick only the keys you need in the parent:

      case call_workflow(MyApp.PaymentWorkflow, %{"amount" => 100}) do
        {:ok, %{"payment_id" => id}} -> {:ok, assign(data, :payment_id, id)}
        {:error, reason} -> {:error, reason}
      end

  ## Examples

      case call_workflow(MyApp.PaymentWorkflow, %{"amount" => 100}, timeout: hours(1)) do
        {:ok, result} -> {:ok, assign(data, :payment, result)}
        {:error, reason} -> {:error, reason}
      end

  """
  @spec call_workflow(module(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def call_workflow(module, input, opts \\ []) do
    parent_id = Context.workflow_id()
    ref = Keyword.get(opts, :ref, module_to_ref(module))
    child_key = child_context_key(ref)
    result_key = child_result_key(ref)

    # Which children this run has started, and what they ended with, is the
    # engine's state: nothing in the step's data can stand in for a child.
    engine_state = EngineState.current()

    case {Map.fetch(engine_state, result_key), Map.fetch(engine_state, child_key)} do
      {{:ok, %{"status" => "completed"} = result}, _child} ->
        parse_child_result(result)

      # A failure the parent was told about may be out of date: the child can
      # have been retried since, so its row has the last word.
      {_result, {:ok, child_id}} ->
        if timed_out?(engine_state, child_id, opts),
          do: {:ok, Keyword.get(opts, :timeout_value, :child_timeout)},
          else: handle_existing_child(child_id, opts)

      {{:ok, result}, :error} ->
        parse_child_result(result)

      {:error, :error} ->
        create_and_wait(module, input, parent_id, child_key, opts)
    end
  end

  @doc """
  Starts a child workflow without waiting for its result (fire-and-forget).

  Returns `{:ok, child_id}` immediately. The child runs independently.
  Idempotent: if resumed, returns the same child_id without creating a duplicate.

  ## Options

  - `:ref` - Reference name for idempotency (default: module name)
  - `:queue` - Queue for the child workflow (default: "default")
  - `:durable` - Durable instance name (default: Durable)

  ## Examples

      {:ok, child_id} = start_workflow(MyApp.EmailWorkflow,
        %{"to" => email}, ref: :welcome_email)

  """
  @spec start_workflow(module(), map(), keyword()) :: {:ok, String.t()}
  def start_workflow(module, input, opts \\ []) do
    parent_id = Context.workflow_id()
    ref = Keyword.get(opts, :ref, module_to_ref(module))
    fire_key = fire_forget_key(ref)

    case Map.fetch(EngineState.current(), fire_key) do
      # Idempotent: already created
      {:ok, child_id} ->
        {:ok, child_id}

      # Create child and continue (no throw)
      :error ->
        create_child_execution(module, input, {parent_id, fire_key, :fire}, [wake: true] ++ opts)
    end
  end

  # The step → child mapping in the parent's engine state, with this child
  # added, so the dashboard can attach a drill-in chevron to the calling step.
  # Mirrors the `__parallel_children` pattern used by parallel steps in
  # `lib/durable/executor.ex`.
  defp call_children(child_id, kind, ref) do
    step_name = Context.current_step()

    meta = %{
      "step_name" => step_name && Atom.to_string(step_name),
      "kind" => Atom.to_string(kind),
      "ref" => to_string(ref)
    }

    Map.put(EngineState.current()["__call_children"] || %{}, child_id, meta)
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp create_and_wait(module, input, parent_id, child_key, opts) do
    {:ok, child_id} = create_child_execution(module, input, {parent_id, child_key, :call}, opts)

    throw(
      {:call_workflow,
       child_id: child_id,
       timeout: Keyword.get(opts, :timeout),
       timeout_value: Keyword.get(opts, :timeout_value, :child_timeout)}
    )
  end

  # The worker that timed out the wait cancels the child, so what the child
  # did last says nothing about this call: the timeout has to be noticed first.
  # The wait's own row says so. `__timeout__` doesn't: it is whichever wait of
  # the step timed out, and an earlier one may have.
  defp timed_out?(engine_state, child_id, opts) do
    is_map_key(engine_state, child_event_name(child_id)) and
      wait_status(child_id, opts) == :timeout
  end

  defp wait_status(child_id, opts) do
    config = Config.get(Keyword.get(opts, :durable, Durable))
    event = child_event_name(child_id)

    Repo.one(
      config,
      from(p in PendingEvent,
        where: p.workflow_id == ^Context.workflow_id() and p.event_name == ^event,
        order_by: [desc: p.inserted_at],
        limit: 1,
        select: p.status
      )
    )
  end

  defp handle_existing_child(child_id, opts) do
    durable_name = Keyword.get(opts, :durable, Durable)
    config = Config.get(durable_name)

    case Repo.get(config, WorkflowExecution, child_id) do
      nil ->
        {:error, :child_not_found}

      %{status: :completed} = child ->
        parse_child_result(build_result_payload(:completed, child.context))

      %{status: status} = child
      when status in [:failed, :cancelled, :compensated, :compensation_failed] ->
        parse_child_result(build_result_payload(:failed, child.error))

      _child ->
        # Still running/waiting — re-throw to wait again
        throw(
          {:call_workflow,
           child_id: child_id,
           timeout: Keyword.get(opts, :timeout),
           timeout_value: Keyword.get(opts, :timeout_value, :child_timeout)}
        )
    end
  end

  # `key` is the name the parent knows the child by, in its engine state.
  defp create_child_execution(module, input, {parent_id, key, kind}, opts) do
    durable_name = Keyword.get(opts, :durable, Durable)
    config = Config.get(durable_name)

    {:ok, workflow_def} = get_child_workflow_def(module, opts)

    safe_input =
      case Executor.storable_input(input) do
        {:ok, map} ->
          map

        {:error, :invalid_input} ->
          raise ArgumentError, "child input must be a map: #{inspect(input)}"
      end

    attrs = %{
      workflow_module: Atom.to_string(module),
      workflow_name: workflow_def.name,
      status: :pending,
      queue: Keyword.get(opts, :queue, "default") |> to_string(),
      priority: Keyword.get(opts, :priority) || 0,
      input: safe_input,
      context: %{},
      parent_workflow_id: parent_id,
      root_workflow_id: Map.get(Durable.Telemetry.run_meta(), :root_workflow_id, parent_id),
      trigger: :parent,
      deadline_at: Executor.deadline(workflow_def, nil)
    }

    # The parent's row gets the child under `key` in the same transaction: a
    # parent lost between the two would start another child when its step
    # ran again, and the first would run with nobody to know it. Which step
    # called it goes with it: the step that runs again finds its child, and
    # doesn't record it a second time.
    ref = Keyword.get(opts, :ref, module_to_ref(module))

    {:ok, {execution, recorded}} =
      Repo.transaction(config, fn ->
        {:ok, child} =
          %WorkflowExecution{} |> WorkflowExecution.changeset(attrs) |> Repo.insert(config)

        recorded = %{key => child.id, "__call_children" => call_children(child.id, kind, ref)}
        record_child(config, parent_id, recorded)
        {child, recorded}
      end)

    for {name, value} <- recorded, do: EngineState.put_current(name, value)

    # A child its parent waits for is woken once the parent is listening.
    if Keyword.get(opts, :wake, false), do: DurablePubSub.wake(config, execution)

    # For inline execution (testing), execute the child immediately
    # It runs in this process, as a run of its own: this step's view of its
    # own run's state is put back after it.
    if Keyword.get(opts, :inline, false) do
      engine_state = EngineState.current()
      Executor.execute_workflow(execution.id, config)
      EngineState.put_current(engine_state)
    end

    {:ok, execution.id}
  end

  # Added to what the row has, not written over it: the step's own save writes
  # the whole state later, and has the child too. The step is the only writer
  # of `__call_children`, so its process has all of it.
  defp record_child(_config, nil, _child), do: :ok

  defp record_child(config, parent_id, child) do
    Repo.update_all(
      config,
      from(w in WorkflowExecution,
        where: w.id == ^parent_id,
        update: [set: [engine_state: fragment("? || ?", w.engine_state, type(^child, :map))]]
      ),
      []
    )
  end

  defp get_child_workflow_def(module, opts) do
    case Keyword.get(opts, :workflow) do
      nil -> module.__default_workflow__()
      name -> module.__workflow_definition__(name)
    end
  end

  @doc false
  def child_context_key(ref), do: "__child:#{ref}"

  @doc false
  def child_result_key(ref), do: "__child_done:#{ref}"

  @doc false
  def child_event_name(child_id), do: "__child_done:#{child_id}"

  @doc false
  def fire_forget_key(ref), do: "__fire_forget:#{ref}"

  @doc false
  def build_result_payload(status, data) do
    %{
      "status" => Atom.to_string(status),
      "result" => data
    }
  end

  @doc false
  def parse_child_result(%{"status" => "completed", "result" => result}) do
    {:ok, result}
  end

  def parse_child_result(%{"status" => status, "result" => result})
      when status in ["failed", "cancelled", "compensation_failed"] do
    {:error, result}
  end

  def parse_child_result(other) do
    {:error, {:unexpected_child_result, other}}
  end

  defp module_to_ref(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end
end
