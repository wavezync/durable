defmodule DurableDashboard.Fixtures do
  @moduledoc """
  Workflows and runs for page tests — real runs, executed inline, so the
  pages read what Durable actually stores.

    * `Payments` (`process_payment`) — completes; `%{"decline" => true}`
      fails at `authorize` with a raised error (status `:failed`)
    * `Orders` (`fulfill_order`) — `reserve` (compensated by `release`),
      `charge`, `ship`; `%{"decline" => true}` rolls back (`:compensated`)
    * `Approvals` (`expense_approval`) — waits for a manager's approval
    * `Webhooks` (`await_webhook`) — waits for a `webhook_received` event
    * `Moderation` (`moderate_content`) — a parallel block (two scans that
      run as child runs) then a branch; `run_family!/2` drives it to the end
  """

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.WorkflowExecution

  import Ecto.Query

  @doc false
  def knob(data, key), do: Map.get(data, key) || Map.get(data, String.to_atom(key))

  defmodule Payments do
    @moduledoc false
    use Durable

    workflow "process_payment" do
      step(:validate, fn data -> {:ok, data} end)

      step(:authorize, fn data ->
        if DurableDashboard.Fixtures.knob(data, "decline"),
          do: raise(ArgumentError, "card declined"),
          else: {:ok, Map.put(data, "auth_code", "AUTH-1")}
      end)
    end
  end

  defmodule Orders do
    @moduledoc false
    use Durable

    workflow "fulfill_order" do
      step(:reserve, [compensate: :release], fn data ->
        {:ok, Map.put(data, "reservation", "RES-1")}
      end)

      step(:charge, fn data ->
        if DurableDashboard.Fixtures.knob(data, "decline"),
          do: {:error, %{reason: "payment_failed"}},
          else: {:ok, data}
      end)

      step(:ship, fn data -> {:ok, Map.put(data, "tracking", "TRK-1")} end)

      compensate(:release, fn data -> {:ok, data} end)
    end
  end

  defmodule Approvals do
    @moduledoc false
    use Durable
    use Durable.Wait

    workflow "expense_approval" do
      step(:ask, fn data ->
        _ = wait_for_approval("manager_approval", prompt: "Approve $80 Meals expense from Bo?")
        {:ok, data}
      end)

      step(:pay, fn data -> {:ok, data} end)
    end
  end

  defmodule Webhooks do
    @moduledoc false
    use Durable
    use Durable.Wait

    workflow "await_webhook" do
      step(:await, fn data ->
        _ = wait_for_event("webhook_received", timeout: hours(1))
        {:ok, data}
      end)
    end
  end

  defmodule Moderation do
    @moduledoc false
    use Durable

    workflow "moderate_content" do
      step(:ingest, fn data -> {:ok, data} end)

      parallel do
        step(:spam_scan, fn data -> {:ok, Map.put(data, "spam", 0.1)} end)
        step(:nsfw_scan, fn data -> {:ok, Map.put(data, "nsfw", 0.2)} end)
      end

      branch on: fn _data -> :low end do
        :high -> step(:remove, fn data -> {:ok, data} end)
        :low -> step(:approve, fn data -> {:ok, data} end)
      end
    end
  end

  @doc "Starts `module`'s workflow with `input` and runs it inline; returns the run id."
  def run!(module, input \\ %{}) do
    {:ok, id} = Executor.start_workflow(module, input, inline: true)
    id
  end

  @doc "Runs a workflow with a parallel block to the end: the parent, its child runs, the parent again."
  def run_family!(module, input \\ %{}) do
    id = run!(module, input)
    config = Config.get(Durable)

    children =
      config.repo.all(
        from(w in WorkflowExecution, where: w.parent_workflow_id == ^id, select: w.id)
      )

    Enum.each(children, &Executor.execute_workflow(&1, config))
    Executor.execute_workflow(id, config)
    id
  end

  @doc "The run with `id`, fresh from the database."
  def get_run!(id), do: Config.get(Durable).repo.get!(WorkflowExecution, id)

  @doc "One run of every kind the pages show, as `%{kind => id}`."
  def seed! do
    %{
      completed: run!(Payments),
      failed: run!(Payments, %{"decline" => true}),
      compensated: run!(Orders, %{"decline" => true}),
      fulfilled: run!(Orders),
      waiting_input: run!(Approvals),
      waiting_event: run!(Webhooks),
      family: run_family!(Moderation)
    }
  end

  @doc "A schedule for `Payments`, on (or `enabled: false`)."
  def schedule!(name, opts \\ []) do
    {:ok, schedule} =
      Durable.schedule(Payments, Keyword.get(opts, :cron, "*/5 * * * *"),
        name: name,
        enabled: Keyword.get(opts, :enabled, true)
      )

    schedule
  end
end
