defmodule Durable.Orchestration do
  @moduledoc """
  Workflow composition: call child workflows from parent steps.

  Provides two primitives for composing workflows:

  - `call_workflow/3` — Start a child workflow and wait for its result (synchronous)
  - `start_workflow/3` — Start a child workflow without waiting (fire-and-forget)

  ## Usage

      defmodule MyApp.OrderWorkflow do
        use Durable
        use Durable.Context
        use Durable.Orchestration

        workflow "process_order" do
          step :charge_payment, fn data ->
            case call_workflow(MyApp.PaymentWorkflow, %{"amount" => data.total},
                   timeout: hours(1)) do
              {:ok, result} ->
                {:ok, assign(data, :payment_id, result["payment_id"])}
              {:error, reason} ->
                {:error, reason}
            end
          end

          step :send_email, fn data ->
            {:ok, email_wf_id} = start_workflow(MyApp.EmailWorkflow,
              %{"to" => data.email}, ref: :confirmation)
            {:ok, assign(data, :email_workflow_id, email_wf_id)}
          end
        end
      end

  """

  alias Durable.Config
  alias Durable.Context
  alias Durable.Executor
  alias Durable.Repo
  alias Durable.Storage.Schemas.WorkflowExecution

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

    context = Process.get(:durable_context, %{})

    cond do
      # Resume case: result already in context
      Map.has_key?(context, result_key) ->
        parse_child_result(Map.get(context, result_key))

      # Resume case: child exists but no result yet
      Map.has_key?(context, child_key) ->
        child_id = Map.get(context, child_key)
        handle_existing_child(child_id, opts)

      # First execution: create child and throw to wait
      true ->
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

    context = Process.get(:durable_context, %{})

    if Map.has_key?(context, fire_key) do
      # Idempotent: already created
      {:ok, Map.get(context, fire_key)}
    else
      # Create child and continue (no throw)
      {:ok, child_id} = create_child_execution(module, input, parent_id, opts)
      Context.put_context(fire_key, child_id)
      {:ok, child_id}
    end
  end

  # ============================================================================
  # Internal helpers
  # ============================================================================

  defp create_and_wait(module, input, parent_id, child_key, opts) do
    {:ok, child_id} = create_child_execution(module, input, parent_id, opts)
    Context.put_context(child_key, child_id)

    throw(
      {:call_workflow,
       child_id: child_id,
       timeout: Keyword.get(opts, :timeout),
       timeout_value: Keyword.get(opts, :timeout_value, :child_timeout)}
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

      %{status: status} = child when status in [:failed, :cancelled, :compensation_failed] ->
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

  defp create_child_execution(module, input, parent_id, opts) do
    durable_name = Keyword.get(opts, :durable, Durable)
    config = Config.get(durable_name)

    {:ok, workflow_def} = get_child_workflow_def(module, opts)

    attrs = %{
      workflow_module: Atom.to_string(module),
      workflow_name: workflow_def.name,
      status: :pending,
      queue: Keyword.get(opts, :queue, "default") |> to_string(),
      priority: Keyword.get(opts, :priority, 0),
      input: input,
      context: %{},
      parent_workflow_id: parent_id
    }

    {:ok, execution} =
      %WorkflowExecution{}
      |> WorkflowExecution.changeset(attrs)
      |> Repo.insert(config)

    # For inline execution (testing), execute the child immediately
    if Keyword.get(opts, :inline, false) do
      Executor.execute_workflow(execution.id, config)
    end

    {:ok, execution.id}
  end

  defp get_child_workflow_def(module, opts) do
    case Keyword.get(opts, :workflow) do
      nil -> module.__default_workflow__()
      name -> module.__workflow_definition__(name)
    end
  end

  @doc false
  def child_context_key(ref), do: :"__child:#{ref}"

  @doc false
  def child_result_key(ref), do: :"__child_done:#{ref}"

  @doc false
  def child_event_name(child_id), do: "__child_done:#{child_id}"

  @doc false
  def fire_forget_key(ref), do: :"__fire_forget:#{ref}"

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
