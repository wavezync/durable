defmodule Durable.Definition do
  @moduledoc """
  Structs representing workflow and step definitions.

  These structs are generated at compile time from the DSL macros
  and used by the executor at runtime.
  """

  defmodule Step do
    @moduledoc """
    Represents a single step in a workflow.

    ## Pipeline Model

    Steps use a pure pipeline model where data flows from step to step:
    - Each step receives one argument: the data from the previous step
    - First step receives the workflow input
    - Each step returns `{:ok, data}` or `{:error, reason}`

    The `body_fn` field contains the step function that processes data.
    """

    @type step_type :: :step | :decision | :branch | :parallel | :loop | :switch

    @type retry_opts :: %{
            optional(:max_attempts) => pos_integer(),
            optional(:backoff) => :exponential | :linear | :constant,
            optional(:base) => pos_integer(),
            optional(:max_backoff) => pos_integer()
          }

    @type t :: %__MODULE__{
            name: atom(),
            type: step_type(),
            module: module(),
            body_fn: (map() -> {:ok, map()} | {:error, term()}) | nil,
            opts: %{
              optional(:retry) => retry_opts(),
              optional(:timeout) => pos_integer(),
              optional(:compensate) => atom(),
              optional(:queue) => atom()
            }
          }

    @enforce_keys [:name, :type, :module]
    defstruct [
      :name,
      :type,
      :module,
      :body_fn,
      opts: %{}
    ]

    @doc """
    Executes the step with the given data.

    For pipeline model steps, calls `body_fn.(data)`.
    """
    def execute(%__MODULE__{body_fn: body_fn}, data) when is_function(body_fn, 1) do
      body_fn.(data)
    end
  end

  defmodule Compensation do
    @moduledoc """
    Represents a compensation handler for a step.

    Compensations are executed in reverse order when a workflow fails
    and needs to undo previously completed steps (Saga pattern).

    ## Pipeline Model

    Compensation functions receive the current data and return `{:ok, data}`:

        compensate :cancel_flight, fn data ->
          FlightAPI.cancel(data.flight_booking_id)
          {:ok, data}
        end
    """

    @type t :: %__MODULE__{
            name: atom(),
            module: module(),
            body_fn: (map() -> {:ok, map()} | {:error, term()}) | nil,
            opts: %{
              optional(:retry) => Step.retry_opts(),
              optional(:timeout) => pos_integer()
            }
          }

    @enforce_keys [:name, :module]
    defstruct [
      :name,
      :module,
      :body_fn,
      opts: %{}
    ]

    @doc """
    Executes the compensation with the given data.
    """
    def execute(%__MODULE__{body_fn: body_fn}, data) when is_function(body_fn, 1) do
      body_fn.(data)
    end
  end

  defmodule Workflow do
    @moduledoc """
    Represents a complete workflow definition.
    """

    @type t :: %__MODULE__{
            name: String.t(),
            module: module(),
            steps: [Step.t()],
            compensations: %{atom() => Compensation.t()},
            opts: %{
              optional(:timeout) => pos_integer(),
              optional(:max_retries) => pos_integer(),
              optional(:queue) => atom()
            }
          }

    @enforce_keys [:name, :module, :steps]
    defstruct [
      :name,
      :module,
      steps: [],
      compensations: %{},
      opts: %{}
    ]
  end
end
