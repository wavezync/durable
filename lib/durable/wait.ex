defmodule Durable.Wait do
  @moduledoc """
  Wait primitives for durable workflows.

  Provides functions for:
  - Sleeping for a duration or until a specific time
  - Waiting for external events
  - Waiting for human input (human-in-the-loop)

  ## Usage

      defmodule MyApp.ApprovalWorkflow do
        use Durable
        use Durable.Context
        use Durable.Wait

        workflow "approval" do
          step :request_approval do
            result = wait_for_input("manager_approval",
              timeout: days(3),
              timeout_value: :auto_reject
            )
            put_context(:approval, result)
          end
        end
      end

  """

  alias Durable.Repo
  alias Durable.Storage.Schemas.{WorkflowExecution, PendingInput}

  import Ecto.Query

  @doc """
  Injects wait functions into the calling module.
  """
  defmacro __using__(_opts) do
    quote do
      import Durable.Wait,
        only: [
          sleep_for: 1,
          sleep_until: 1,
          wait_for_event: 1,
          wait_for_event: 2,
          wait_for_input: 1,
          wait_for_input: 2
        ]
    end
  end

  @doc """
  Sleeps the workflow for the specified duration.

  The workflow will be suspended and resumed after the duration.

  ## Options

  - `:seconds` - Sleep for N seconds
  - `:minutes` - Sleep for N minutes
  - `:hours` - Sleep for N hours
  - `:days` - Sleep for N days

  ## Examples

      sleep_for(seconds: 30)
      sleep_for(minutes: 5)
      sleep_for(hours: 24)

  """
  @spec sleep_for(keyword()) :: no_return()
  def sleep_for(opts) do
    throw({:sleep, opts})
  end

  @doc """
  Sleeps the workflow until the specified datetime.

  ## Examples

      sleep_until(~U[2025-12-25 00:00:00Z])

  """
  @spec sleep_until(DateTime.t()) :: no_return()
  def sleep_until(datetime) do
    throw({:sleep, until: datetime})
  end

  @doc """
  Waits for an external event.

  The workflow will be suspended until the event is received.

  ## Options

  - `:timeout` - Timeout in milliseconds (optional)
  - `:timeout_value` - Value to return on timeout (optional)
  - `:filter` - Function to filter events (optional)

  ## Examples

      wait_for_event("payment_confirmed")
      wait_for_event("payment_confirmed", timeout: minutes(5))

  """
  @spec wait_for_event(String.t(), keyword()) :: no_return()
  def wait_for_event(event_name, opts \\ []) do
    throw({:wait_for_event, Keyword.put(opts, :event_name, event_name)})
  end

  @doc """
  Waits for human input.

  The workflow will be suspended until input is provided.

  ## Options

  - `:type` - Input type: `:form`, `:single_choice`, `:multi_choice`, `:approval`, `:free_text`
  - `:prompt` - Prompt to show to the user
  - `:fields` - Field definitions for form input
  - `:choices` - Choice options for single/multi choice
  - `:timeout` - Timeout in milliseconds
  - `:timeout_value` - Value to return on timeout

  ## Examples

      # Simple approval
      wait_for_input("manager_approval")

      # With timeout
      wait_for_input("approval", timeout: days(3), timeout_value: :rejected)

      # Form input
      wait_for_input("equipment_request",
        type: :form,
        fields: [
          %{name: :laptop, type: :select, options: ["MacBook", "ThinkPad"]}
        ]
      )

  """
  @spec wait_for_input(String.t(), keyword()) :: no_return()
  def wait_for_input(input_name, opts \\ []) do
    throw({:wait_for_input, Keyword.put(opts, :input_name, input_name)})
  end

  @doc """
  Provides input for a waiting workflow.

  Called from external code (API, UI, etc.) to continue a workflow.

  ## Examples

      Durable.provide_input(workflow_id, "approval", %{approved: true})

  """
  @spec provide_input(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def provide_input(workflow_id, input_name, data) do
    with {:ok, pending} <- find_pending_input(workflow_id, input_name),
         {:ok, _} <- complete_pending_input(pending, data),
         {:ok, _} <- Durable.Executor.resume_workflow(workflow_id, %{input_name => data}) do
      :ok
    end
  end

  @doc """
  Sends an event to a waiting workflow.

  ## Examples

      Durable.send_event(workflow_id, "payment_confirmed", %{amount: 99.99})

  """
  @spec send_event(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def send_event(workflow_id, event_name, payload) do
    with {:ok, execution} <- get_waiting_execution(workflow_id),
         true <- execution.status == :waiting || {:error, :not_waiting} do
      # Store event in context and resume
      event_data = %{event_name => payload}
      Durable.Executor.resume_workflow(workflow_id, event_data)
      :ok
    end
  end

  @doc """
  Lists pending inputs for workflows.

  ## Filters

  - `:workflow` - Filter by workflow module
  - `:status` - Filter by status (default: :pending)
  - `:timeout_before` - Filter inputs timing out before this datetime

  """
  @spec list_pending_inputs(keyword()) :: [map()]
  def list_pending_inputs(filters \\ []) do
    status = Keyword.get(filters, :status, :pending)
    limit = Keyword.get(filters, :limit, 50)

    query =
      from(p in PendingInput,
        where: p.status == ^status,
        order_by: [asc: p.timeout_at, asc: p.inserted_at],
        limit: ^limit,
        preload: [:workflow]
      )

    query =
      case Keyword.get(filters, :timeout_before) do
        nil -> query
        datetime -> from(p in query, where: p.timeout_at <= ^datetime)
      end

    Repo.all(query)
    |> Enum.map(&pending_input_to_map/1)
  end

  # Private functions

  defp find_pending_input(workflow_id, input_name) do
    query =
      from(p in PendingInput,
        where:
          p.workflow_id == ^workflow_id and
            p.input_name == ^input_name and
            p.status == :pending
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      pending -> {:ok, pending}
    end
  end

  defp complete_pending_input(pending, response) do
    pending
    |> PendingInput.complete_changeset(response)
    |> Repo.update()
  end

  defp get_waiting_execution(workflow_id) do
    case Repo.get(WorkflowExecution, workflow_id) do
      nil -> {:error, :not_found}
      execution -> {:ok, execution}
    end
  end

  defp pending_input_to_map(pending) do
    %{
      id: pending.id,
      workflow_id: pending.workflow_id,
      input_name: pending.input_name,
      step_name: pending.step_name,
      input_type: pending.input_type,
      prompt: pending.prompt,
      fields: pending.fields,
      status: pending.status,
      timeout_at: pending.timeout_at,
      inserted_at: pending.inserted_at
    }
  end
end
